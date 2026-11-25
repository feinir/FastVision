import CoreImage
import CoreText

enum PhotoAnnotationLinePattern: Int, CaseIterable {
    case solid, dashed, dashDot

    func lengths(for width: CGFloat) -> [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [width * 3, width * 2.5]
        case .dashDot: return [width * 3, width * 2.1, width * 0.15, width * 2.1]
        }
    }
}

enum PhotoBrushTip: Int, CaseIterable {
    case round, square, flat
}

struct PhotoAnnotationStrokeStyle: Equatable {
    let width: CGFloat
    let pattern: PhotoAnnotationLinePattern
    let color: CGColor
    let outlined: Bool
}

struct PhotoAnnotationTextStyle: Equatable {
    let fontName: String?
    let size: CGFloat
    let color: CGColor
    let outlined: Bool
}

struct PhotoAnnotationStroke {
    enum Shape: Equatable {
        case rectangle, circle, line(arrow: Bool), brush(PhotoBrushTip)
    }

    let start: CGPoint
    var end: CGPoint
    var shape: Shape
    var style: PhotoAnnotationStrokeStyle
    var samples: [CGPoint] = []

    mutating func extend(to point: CGPoint) {
        if case .brush = shape, end != point { samples.append(point) }
        end = point
    }

    fileprivate struct Geometry {
        let shaft: CGPath
        let head: CGPath?
        let width: CGFloat

        var bounds: CGRect {
            let margin = width + 2
            let shaftBounds = shaft.boundingBoxOfPath.insetBy(dx: -margin, dy: -margin)
            return head.map { shaftBounds.union($0.boundingBoxOfPath.insetBy(dx: -margin, dy: -margin)) } ?? shaftBounds
        }
    }

    func spans(_ size: CGSize, minimum: CGFloat) -> Bool {
        let x = abs(end.x - start.x) * size.width
        let y = abs(end.y - start.y) * size.height
        switch shape {
        case .brush: return true
        case .line: return hypot(x, y) >= minimum
        case .rectangle, .circle: return min(x, y) >= minimum
        }
    }

    func drawPreview(in context: CGContext, frame: CGRect, imageSize: CGSize) {
        guard spans(frame.size, minimum: 0.5), imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(frame.width / imageSize.width, frame.height / imageSize.height)
        let geometry = geometry(in: frame, width: max(0.25, style.width * scale), flipped: true)
        context.saveGState()
        context.clip(to: frame)
        draw(geometry, in: context)
        context.restoreGState()
    }

    fileprivate func geometry(in frame: CGRect, width: CGFloat, flipped: Bool) -> Geometry {
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + normalized.x * frame.width,
                    y: frame.minY + (flipped ? normalized.y : 1 - normalized.y) * frame.height)
        }

        let start = point(start), end = point(end)
        let shaft = CGMutablePath()
        let dx = end.x - start.x, dy = end.y - start.y
        switch shape {
        case .rectangle:
            shaft.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(dx), height: abs(dy)))
        case .circle:
            let diameter = min(abs(dx), abs(dy))
            shaft.addEllipse(in: CGRect(x: dx < 0 ? start.x - diameter : start.x,
                                        y: dy < 0 ? start.y - diameter : start.y,
                                        width: diameter, height: diameter))
        case .line:
            shaft.move(to: start)
            shaft.addLine(to: end)
        case .brush:
            shaft.move(to: start)
            var previous = start
            for sample in samples.map(point) {
                shaft.addQuadCurve(to: CGPoint(x: (previous.x + sample.x) / 2, y: (previous.y + sample.y) / 2),
                                   control: previous)
                previous = sample
            }
            shaft.addLine(to: samples.isEmpty && start == end ? CGPoint(x: start.x + 0.01, y: start.y) : end)
        }

        let length = hypot(dx, dy)
        guard case .line(arrow: true) = shape, length > 0 else {
            return Geometry(shaft: shaft, head: nil, width: width)
        }
        let size = min(length * 0.5, width * 5)
        let alongX = dx / length, alongY = dy / length
        let base = CGPoint(x: end.x - alongX * size, y: end.y - alongY * size)
        let wingX = -alongY * size * 0.45, wingY = alongX * size * 0.45
        let head = CGMutablePath()
        head.move(to: CGPoint(x: base.x + wingX, y: base.y + wingY))
        head.addLine(to: end)
        head.addLine(to: CGPoint(x: base.x - wingX, y: base.y - wingY))
        return Geometry(shaft: shaft, head: head, width: width)
    }

    fileprivate func draw(_ geometry: Geometry, in context: CGContext) {
        let width = geometry.width
        var shaft = geometry.shaft
        context.saveGState()
        defer { context.restoreGState() }
        switch shape {
        case .brush(.square):
            context.setLineCap(.square)
        case .brush(.flat):
            let nib = CGAffineTransform(rotationAngle: .pi / 4).scaledBy(x: 1, y: 0.36)
            var inverse = nib.inverted()
            if let compressed = shaft.copy(using: &inverse) {
                shaft = compressed
                context.concatenate(nib)
            }
            context.setLineCap(.square)
        default:
            context.setLineCap(.round)
        }
        context.setLineJoin(.round)
        let ink = (style.color, width)
        let passes = style.outlined ? [(PhotoAnnotation.outline(for: style.color), width * 1.65), ink] : [ink]
        for (color, lineWidth) in passes {
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.setLineDash(phase: 0, lengths: style.pattern.lengths(for: width))
            context.addPath(shaft)
            context.strokePath()
            if let head = geometry.head {
                context.setLineDash(phase: 0, lengths: [])
                context.addPath(head)
                context.strokePath()
            }
        }
    }
}

enum PhotoAnnotation {
    case stroke(PhotoAnnotationStroke)
    case text(String, anchor: CGPoint, style: PhotoAnnotationTextStyle)

    static let defaultInk = CGColor(red: 0.90, green: 0.14, blue: 0.09, alpha: 1)

    static func outline(for color: CGColor) -> CGColor {
        guard let components = color.components, components.count >= 3 else { return CGColor(gray: 1, alpha: 1) }
        let brightness = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        return CGColor(gray: brightness > 0.65 ? 0.14 : 1, alpha: 1)
    }

    func overlay(in extent: CGRect) throws -> CIImage {
        switch self {
        case let .stroke(stroke):
            let geometry = stroke.geometry(in: extent, width: stroke.style.width, flipped: false)
            return try overlay(in: extent, bounds: geometry.bounds) { context in
                stroke.draw(geometry, in: context)
            }
        case let .text(text, anchor, style):
            let fontSize = style.size
            let font = style.fontName.map { CTFontCreateWithName($0 as CFString, fontSize, nil) }
                ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color,
            ]
            if style.outlined {
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = Self.outline(for: style.color)
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -2.5
            }
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let padding = fontSize * 0.18 + 1
            let size = CGSize(width: width + 2 * padding, height: ascent + descent + 2 * padding)
            let scale = min(1, extent.width / size.width, extent.height / size.height)
            let x = min(extent.maxX - size.width * scale, extent.minX + anchor.x * extent.width)
            let y = max(extent.minY, extent.maxY - anchor.y * extent.height - size.height * scale)
            let bounds = CGRect(x: x, y: y, width: size.width * scale, height: size.height * scale)
            return try overlay(in: extent, bounds: bounds) { context in
                context.translateBy(x: bounds.minX, y: bounds.minY)
                context.scaleBy(x: scale, y: scale)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: padding, y: padding + descent)
                CTLineDraw(line, context)
            }
        }
    }

    private func overlay(in extent: CGRect, bounds: CGRect, draw: (CGContext) -> Void) throws -> CIImage {
        let bounds = bounds.integral.intersection(extent.integral)
        guard !bounds.isEmpty, !bounds.isInfinite else { throw PhotoCropProcessor.Failure.cannotRender }

        // Keep sparse marks at full resolution and bound the layer size for long diagonal strokes.
        let scale = min(1, sqrt(8_388_608 / (bounds.width * bounds.height)))
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PhotoCropProcessor.Failure.cannotRender }
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(context)

        guard let overlay = context.makeImage() else { throw PhotoCropProcessor.Failure.cannotRender }
        return CIImage(cgImage: overlay)
            .transformed(by: CGAffineTransform(a: bounds.width / CGFloat(width), b: 0,
                                               c: 0, d: bounds.height / CGFloat(height),
                                               tx: bounds.minX, ty: bounds.minY))
    }
}

/// A vector annotation with a cached raster preview and its document-space position.
struct PhotoAnnotationLayer {
    private struct GeometryEdit {
        let inputExtent: CGRect
        let offset: CGPoint
        let operation: (CIImage) throws -> CIImage

        func applying(to pixels: CIImage) throws -> CIImage {
            let positioned = pixels.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            let clear = CIImage(color: .clear).cropped(to: inputExtent)
            return try operation(positioned.composited(over: clear).cropped(to: inputExtent))
        }
    }

    let id: UUID
    let annotation: PhotoAnnotation
    let pixels: CIImage
    let preview: CGImage
    var offset: CGPoint
    private let sourceExtent: CGRect
    private let geometry: [GeometryEdit]
    private let mask: InkMask

    init(id: UUID = UUID(), annotation: PhotoAnnotation, extent: CGRect, context: CIContext) throws {
        try self.init(id: id, annotation: annotation, extent: extent, geometry: [], offset: .zero,
                      pixels: annotation.overlay(in: extent), context: context)
    }

    private init(id: UUID, annotation: PhotoAnnotation, extent: CGRect, geometry: [GeometryEdit],
                 offset: CGPoint, pixels: CIImage, context: CIContext) throws {
        self.id = id
        self.annotation = annotation
        sourceExtent = extent
        self.geometry = geometry
        self.offset = offset
        self.pixels = pixels
        let preview = try PhotoCropProcessor.render(pixels, context: context, maximumSide: 1400)
        self.preview = preview
        mask = try InkMask(preview)
    }

    func restyled(as annotation: PhotoAnnotation, context: CIContext) throws -> Self {
        let original = try annotation.overlay(in: sourceExtent)
        let edited = try geometry.reduce(original) { try $1.applying(to: $0) }
        return try Self(id: id, annotation: annotation, extent: sourceExtent, geometry: geometry,
                        offset: offset, pixels: edited, context: context)
    }

    var bounds: CGRect { pixels.extent.offsetBy(dx: offset.x, dy: offset.y) }
    var selectionContour: CGPath { mask.contour }

    var inkBounds: CGRect? {
        mask.bounds.map { rect in
            CGRect(x: bounds.minX + rect.minX * bounds.width,
                   y: bounds.maxY - rect.maxY * bounds.height,
                   width: rect.width * bounds.width, height: rect.height * bounds.height)
        }
    }

    var positionedPixels: CIImage {
        pixels.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard let inkBounds, inkBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        let frame = bounds
        return mask.contains(x: (point.x - frame.minX) / frame.width,
                             y: (frame.maxY - point.y) / frame.height,
                             toleranceX: tolerance / frame.width, toleranceY: tolerance / frame.height)
    }

    func moved(by delta: CGPoint, in extent: CGRect) -> Self {
        guard let inkBounds else { return self }
        let x = min(extent.maxX - inkBounds.maxX, max(extent.minX - inkBounds.minX, delta.x))
        let y = min(extent.maxY - inkBounds.maxY, max(extent.minY - inkBounds.minY, delta.y))
        var moved = self
        moved.offset.x += x
        moved.offset.y += y
        return moved
    }

    func transformed(in extent: CGRect, context: CIContext, by edit: @escaping (CIImage) throws -> CIImage) throws -> Self {
        let step = GeometryEdit(inputExtent: extent, offset: offset, operation: edit)
        return try Self(id: id, annotation: annotation, extent: sourceExtent, geometry: geometry + [step],
                        offset: .zero, pixels: step.applying(to: pixels), context: context)
    }

    private final class InkMask {
        let width: Int
        let height: Int
        let alpha: [UInt8]
        let bounds: CGRect?
        lazy var contour: CGPath = traceContour()

        init(_ preview: CGImage) throws {
            let scale = min(1, 384 / CGFloat(max(preview.width, preview.height)))
            let width = max(1, Int(ceil(CGFloat(preview.width) * scale)))
            let height = max(1, Int(ceil(CGFloat(preview.height) * scale)))
            self.width = width
            self.height = height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                                | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(preview, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { throw PhotoCropProcessor.Failure.cannotRender }
            let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
            self.alpha = alpha
            var left = width, top = height, right = 0, bottom = 0
            for index in alpha.indices where alpha[index] > 1 {
                let x = index % width, y = index / width
                left = min(left, x)
                right = max(right, x + 1)
                top = min(top, y)
                bottom = max(bottom, y + 1)
            }
            bounds = right > left && bottom > top
                ? CGRect(x: CGFloat(left) / CGFloat(width), y: CGFloat(top) / CGFloat(height),
                         width: CGFloat(right - left) / CGFloat(width), height: CGFloat(bottom - top) / CGFloat(height))
                : nil
        }

        private struct Vertex: Hashable {
            let x: Int
            let y: Int
        }

        /// Trace the raster silhouette at half-pixel intervals, keeping disconnected marks and holes.
        private func traceContour() -> CGPath {
            let path = CGMutablePath()
            guard bounds != nil else { return path }
            var edges: [Vertex: [Vertex]] = [:]

            func add(_ a: Vertex, _ b: Vertex) {
                edges[a, default: []].append(b)
                edges[b, default: []].append(a)
            }

            func isInk(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && y >= 0 && x < width && y < height && alpha[y * width + x] > 24
            }

            for y in -1..<height {
                for x in -1..<width {
                    let corners = (isInk(x, y) ? 1 : 0) | (isInk(x + 1, y) ? 2 : 0)
                        | (isInk(x + 1, y + 1) ? 4 : 0) | (isInk(x, y + 1) ? 8 : 0)
                    if corners == 0 || corners == 15 { continue }
                    let top = Vertex(x: 2 * x + 2, y: 2 * y + 1)
                    let right = Vertex(x: 2 * x + 3, y: 2 * y + 2)
                    let bottom = Vertex(x: 2 * x + 2, y: 2 * y + 3)
                    let left = Vertex(x: 2 * x + 1, y: 2 * y + 2)
                    switch corners {
                    case 1, 14: add(left, top)
                    case 2, 13: add(top, right)
                    case 3, 12: add(left, right)
                    case 4, 11: add(right, bottom)
                    case 5:
                        add(left, top)
                        add(right, bottom)
                    case 6, 9: add(top, bottom)
                    case 7, 8: add(left, bottom)
                    case 10:
                        add(top, right)
                        add(bottom, left)
                    default: break
                    }
                }
            }

            func point(_ vertex: Vertex) -> CGPoint {
                CGPoint(x: CGFloat(vertex.x) / (2 * CGFloat(width)), y: CGFloat(vertex.y) / (2 * CGFloat(height)))
            }

            func remove(_ vertex: Vertex, neighbor: Vertex) {
                edges[vertex]?.removeAll { $0 == neighbor }
                if edges[vertex]?.isEmpty == true { edges.removeValue(forKey: vertex) }
            }

            while let start = edges.keys.first {
                path.move(to: point(start))
                var current = start
                while let next = edges[current]?.last {
                    remove(current, neighbor: next)
                    remove(next, neighbor: current)
                    if next == start {
                        path.closeSubpath()
                        break
                    }
                    path.addLine(to: point(next))
                    current = next
                }
            }
            return path
        }

        func contains(x: CGFloat, y: CGFloat, toleranceX: CGFloat, toleranceY: CGFloat) -> Bool {
            let left = max(0, Int(floor((x - toleranceX) * CGFloat(width))))
            let right = min(width - 1, Int(ceil((x + toleranceX) * CGFloat(width))))
            let top = max(0, Int(floor((y - toleranceY) * CGFloat(height))))
            let bottom = min(height - 1, Int(ceil((y + toleranceY) * CGFloat(height))))
            guard left <= right, top <= bottom else { return false }
            for row in top...bottom {
                let base = row * width
                if alpha[(base + left)...(base + right)].contains(where: { $0 > 12 }) { return true }
            }
            return false
        }
    }
}
