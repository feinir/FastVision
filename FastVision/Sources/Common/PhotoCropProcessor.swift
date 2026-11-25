import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoCropMode: Int {
    case rectangle, perspective
}

enum PhotoCropAspect: Int {
    case free, original
}

struct PhotoCropSelection {
    var corners: [CGPoint]
    private var edgeAdjustments: [Int: CGPoint] = [:]

    var hasEdgeAdjustments: Bool { !edgeAdjustments.isEmpty }
    var perspectiveMesh: PhotoCropMesh? { PhotoCropMesh(corners: corners, adjustments: edgeAdjustments) }

    init(rect: CGRect = CGRect(x: 0.09, y: 0.09, width: 0.82, height: 0.82), aspect: PhotoCropAspect = .free) {
        // Equal normalized sides correspond to the original pixel aspect ratio.
        let side = min(rect.width, rect.height)
        let rect = aspect == .original
            ? CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            : rect
        corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    static func rectangle(from start: CGPoint, to end: CGPoint, aspect: PhotoCropAspect) -> PhotoCropSelection {
        if aspect == .original {
            let direction = CGPoint(x: end.x >= start.x ? 1 : -1, y: end.y >= start.y ? 1 : -1)
            return square(from: start, toward: end, direction: direction)
        }
        return PhotoCropSelection(rect: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                               width: abs(end.x - start.x), height: abs(end.y - start.y)))
    }

    func resizingOriginalAspectCorner(_ index: Int, toward point: CGPoint) -> PhotoCropSelection {
        let anchor = corners[(index + 2) % 4]
        let direction = CGPoint(x: index == 0 || index == 3 ? -1 : 1, y: index < 2 ? -1 : 1)
        return Self.square(from: anchor, toward: point, direction: direction)
    }

    func resizingOriginalAspectEdge(_ index: Int, toward point: CGPoint) -> PhotoCropSelection {
        let rect = bounds
        let horizontal = index == 0 || index == 2
        let forward = index == 1 || index == 2
        let center = horizontal ? rect.midX : rect.midY
        let fixed = horizontal
            ? (forward ? rect.minY : rect.maxY)
            : (forward ? rect.minX : rect.maxX)
        let moving = horizontal ? point.y : point.x
        let reach = forward ? 1 - fixed : fixed
        let side = max(0, min(forward ? moving - fixed : fixed - moving, reach, 2 * min(center, 1 - center)))
        let leading = forward ? fixed : fixed - side
        let centered = center - side / 2
        return PhotoCropSelection(rect: CGRect(x: horizontal ? centered : leading,
                                               y: horizontal ? leading : centered, width: side, height: side))
    }

    private static func square(from anchor: CGPoint, toward point: CGPoint, direction: CGPoint) -> PhotoCropSelection {
        let deltaX = (point.x - anchor.x) * direction.x
        let deltaY = (point.y - anchor.y) * direction.y
        let limitX = direction.x > 0 ? 1 - anchor.x : anchor.x
        let limitY = direction.y > 0 ? 1 - anchor.y : anchor.y
        let side = max(0, min((deltaX + deltaY) / 2, limitX, limitY))
        let rect = CGRect(x: direction.x > 0 ? anchor.x : anchor.x - side,
                          y: direction.y > 0 ? anchor.y : anchor.y - side, width: side, height: side)
        return PhotoCropSelection(rect: rect)
    }

    mutating func adjustPerspectiveHandle(edge: Int, offset: Int, to point: CGPoint) {
        let index = PhotoCropMesh.boundaryIndex(edge: edge, offset: offset)
        let base = PhotoCropMesh(corners: corners, adjustments: [:])?.nodes[index].point
        let point = Self.clampToImage(point)
        edgeAdjustments[index] = base == point ? nil : point
    }

    mutating func translate(by delta: CGPoint) {
        let bounds = bounds
        let x = min(1 - bounds.maxX, max(-bounds.minX, delta.x))
        let y = min(1 - bounds.maxY, max(-bounds.minY, delta.y))
        func translated(_ point: CGPoint) -> CGPoint {
            Self.clampToImage(CGPoint(x: point.x + x, y: point.y + y))
        }
        corners = corners.map(translated)
        edgeAdjustments = edgeAdjustments.mapValues(translated)
    }

    static func clampToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    var bounds: CGRect {
        let points = corners + edgeAdjustments.values
        let xs = points.map(\.x), ys = points.map(\.y)
        let x = xs.min() ?? 0, y = ys.min() ?? 0
        return CGRect(x: x, y: y, width: (xs.max() ?? 0) - x, height: (ys.max() ?? 0) - y)
    }

    var isValid: Bool {
        guard corners.count == 4, corners.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        let convex = corners.indices.allSatisfy { i in
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            return cross > 0.0001
        }
        return convex && (!hasEdgeAdjustments || perspectiveMesh != nil)
    }
}

enum PhotoCropProcessor {
    enum Failure: LocalizedError {
        case unreadable, invalidSelection, cannotRender, cannotEncode, originalDestination, fileChanged

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return NSLocalizedString("photo-editor-unreadable", value: "This photo could not be opened for cropping.", comment: "")
            case .invalidSelection:
                return NSLocalizedString("photo-editor-invalid", value: "Adjust the frame so its sides do not cross.", comment: "")
            case .cannotRender:
                return NSLocalizedString("photo-editor-render-error", value: "Could not render the edited photo.", comment: "")
            case .cannotEncode:
                return NSLocalizedString("photo-editor-encode-error", value: "Could not write the image to this format.", comment: "")
            case .originalDestination:
                return NSLocalizedString("photo-editor-original-error", value: "Choose a different filename to keep the original photo.", comment: "")
            case .fileChanged:
                return NSLocalizedString("photo-editor-file-changed", value: "The file changed on disk. Save As to keep both versions.", comment: "")
            }
        }
    }

    struct LoadedPhoto {
        let image: CIImage
        let writableType: UTType?
        let snapshot: SafeFileReplacement.Item
    }

    static func load(_ url: URL) throws -> LoadedPhoto {
        let snapshot = try SafeFileReplacement.Item(url)
        guard snapshot.isRegularFile else { throw Failure.unreadable }
        let bytes = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw Failure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int32 ?? 1
        let image = atOrigin(CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation))
        let writableTypes = [UTType.jpeg, .png, .heic, .tiff]
        let writableType = writableTypes.first { type in
            CGImageSourceGetCount(source) == 1
                && type.identifier == CGImageSourceGetType(source) as String?
                && (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true
        }
        guard snapshot.matches(try SafeFileReplacement.Item(url)) else { throw Failure.fileChanged }
        return LoadedPhoto(image: image, writableType: writableType, snapshot: snapshot)
    }

    static func crop(_ image: CIImage, selection: PhotoCropSelection, mode: PhotoCropMode,
                     aspect: PhotoCropAspect = .free) throws -> CIImage {
        guard selection.isValid else { throw Failure.invalidSelection }
        let extent = image.extent

        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + point.x * extent.width,
                    y: extent.maxY - point.y * extent.height)
        }

        if mode == .rectangle {
            let rect = PhotoCropSelection(rect: selection.bounds, aspect: aspect).bounds
            let lowerLeft = pixel(CGPoint(x: rect.minX, y: rect.maxY))
            let size = CGSize(width: rect.width * extent.width, height: rect.height * extent.height)
            let region: CGRect
            if aspect == .original {
                let width = min(extent.width, max(1, size.width.rounded()))
                let height = min(extent.height, max(1, size.height.rounded()))
                let x = min(extent.maxX - width, max(extent.minX, lowerLeft.x.rounded()))
                let y = min(extent.maxY - height, max(extent.minY, lowerLeft.y.rounded()))
                region = CGRect(x: x, y: y, width: width, height: height)
            } else {
                region = CGRect(origin: lowerLeft, size: size).integral.intersection(extent)
            }
            guard region.width > 0, region.height > 0 else { throw Failure.invalidSelection }
            return atOrigin(image.cropped(to: region))
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = pixel(selection.corners[0])
        filter.topRight = pixel(selection.corners[1])
        filter.bottomRight = pixel(selection.corners[2])
        filter.bottomLeft = pixel(selection.corners[3])
        guard let result = filter.outputImage, !result.extent.isInfinite, !result.extent.isEmpty,
              result.extent.width.isFinite, result.extent.height.isFinite,
              result.extent.width >= 1, result.extent.height >= 1 else { throw Failure.cannotRender }
        let corrected: CIImage
        if selection.hasEdgeAdjustments {
            guard let output = selection.perspectiveMesh?.warp(image, outputSize: result.extent.size) else {
                throw Failure.cannotRender
            }
            corrected = output
        } else {
            corrected = atOrigin(result)
        }
        guard aspect == .original else { return corrected }
        let ratio = extent.width / extent.height
        let outputWidth = min(corrected.extent.width, corrected.extent.height * ratio)
        return corrected.transformed(by: CGAffineTransform(scaleX: outputWidth / corrected.extent.width,
                                                           y: outputWidth / ratio / corrected.extent.height))
    }

    static func rotate(_ image: CIImage, clockwise: Bool) -> CIImage {
        atOrigin(image.oriented(clockwise ? .right : .left))
    }

    static func render(_ image: CIImage, context: CIContext, maximumSide: CGFloat? = nil) throws -> CGImage {
        let maxSide = max(image.extent.width, image.extent.height)
        let scale = maximumSide.map { min(1, $0 / maxSide) } ?? 1
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = scaled.extent.integral
        guard !rect.isEmpty, !rect.isInfinite, let output = context.createCGImage(scaled, from: rect) else {
            throw Failure.cannotRender
        }
        return output
    }

    static func write(_ image: CGImage, to destination: URL, as type: UTType,
                      replacing snapshot: SafeFileReplacement.Item?) throws -> SafeFileReplacement.Item {
        let fm = FileManager.default
        if let snapshot {
            guard let current = try? SafeFileReplacement.Item(destination),
                  snapshot.isRegularFile, snapshot.matches(current) else { throw Failure.fileChanged }
        }

        let folder = destination.deletingLastPathComponent()
            .appendingPathComponent(".fastvision-crop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retainForRecovery = false
        defer { if !retainForRecovery { try? fm.removeItem(at: folder) } }
        let staged = folder.appendingPathComponent(destination.lastPathComponent)
        guard let output = CGImageDestinationCreateWithURL(staged as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.cannotEncode
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw Failure.cannotEncode }

        if let snapshot {
            do {
                try SafeFileReplacement.replace(from: staged, to: destination, moving: true, expecting: snapshot)
            } catch let failure as SafeFileReplacement.Failure {
                retainForRecovery = failure.recoveryItems.contains { $0.path.hasPrefix(folder.path + "/") }
                throw failure
            }
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        return try SafeFileReplacement.Item(destination)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
