import CoreGraphics
import Darwin
import Foundation
import ImageIO

enum SimilarPhotoScanner {
    struct Photo: Hashable {
        let url: URL
        let byteCount: Int64
        private let device: dev_t
        private let inode: ino_t
        private let modificationTime: Int
        private let modificationNanos: Int
        private let changeTime: Int
        private let changeNanos: Int

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            self.url = url
            byteCount = info.st_size
            device = info.st_dev
            inode = info.st_ino
            modificationTime = info.st_mtimespec.tv_sec
            modificationNanos = info.st_mtimespec.tv_nsec
            changeTime = info.st_ctimespec.tv_sec
            changeNanos = info.st_ctimespec.tv_nsec
        }

        var isCurrent: Bool { Photo(url) == self }
    }

    struct Result {
        let groups: [[Photo]]
        let unreadableCount: Int
    }

    struct TrashResult {
        var trashed: Set<Photo> = []
        var failures: [String] = []
    }

    static func moveToTrash(_ photos: [Photo]) -> TrashResult {
        var result = TrashResult()
        for photo in photos {
            guard photo.isCurrent else {
                result.failures.append(String(format: NSLocalizedString(
                    "similar-review-changed-file", value: "%@ changed. Scan again before moving it.", comment: ""
                ), photo.url.path))
                continue
            }

            do {
                try FileManager.default.trashItem(at: photo.url, resultingItemURL: nil)
                result.trashed.insert(photo)
            } catch {
                result.failures.append("\(photo.url.path): \(error.localizedDescription)")
            }
        }
        return result
    }

    private struct Fingerprint {
        private static let side = 9
        private static let maximumHashDistance = 10
        let horizontal: UInt64
        let vertical: UInt64
        let aspectRatio: Double
        let pixels: [UInt8]

        init?(_ image: CGImage) {
            let side = Self.side
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                              bitsPerComponent: 8, bytesPerRow: side * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                let bounds = CGRect(x: 0, y: 0, width: side, height: side)
                context.setFillColor(gray: 0.5, alpha: 1)
                context.fill(bounds)
                context.interpolationQuality = .high
                context.draw(image, in: bounds)
                return true
            }
            guard rendered else { return nil }

            let luminance: [Int] = stride(from: 0, to: pixels.count, by: 4).map { offset in
                54 * Int(pixels[offset]) + 183 * Int(pixels[offset + 1]) + 19 * Int(pixels[offset + 2])
            }
            var horizontal: UInt64 = 0
            var vertical: UInt64 = 0
            for row in 0..<8 {
                for column in 0..<8 {
                    let index = row * side + column
                    horizontal = (horizontal << 1) | (luminance[index] > luminance[index + 1] ? 1 : 0)
                    vertical = (vertical << 1) | (luminance[index] > luminance[index + side] ? 1 : 0)
                }
            }
            self.horizontal = horizontal
            self.vertical = vertical
            self.aspectRatio = Double(image.width) / Double(image.height)
            self.pixels = pixels
        }

        // With twelve disjoint bands, fingerprints within ten bit changes share at least one band.
        var buckets: [Int] {
            [horizontal, vertical].enumerated().flatMap { index, hash in
                (0..<6).map { band in
                    let mask: UInt64 = band == 5 ? 0x3FFF : 0x03FF
                    return ((index * 6 + band) << 14) | Int((hash >> (10 * band)) & mask)
                }
            }
        }

        func distance(to other: Fingerprint) -> Int? {
            guard abs(log(aspectRatio / other.aspectRatio)) <= 0.10 else { return nil }
            let hashDistance = (horizontal ^ other.horizontal).nonzeroBitCount
                + (vertical ^ other.vertical).nonzeroBitCount
            guard hashDistance <= Self.maximumHashDistance else { return nil }

            var colorDifference = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                for channel in index..<(index + 3) {
                    colorDifference += abs(Int(pixels[channel]) - Int(other.pixels[channel]))
                }
            }
            // Shape alone would also match flat images and gradients of very different colors.
            guard colorDifference <= Self.side * Self.side * 3 * 23 else { return nil }
            return hashDistance * 500 + colorDifference
        }
    }

    static func thumbnail(at url: URL, maximumSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize
        ] as CFDictionary)
    }

    static func scan(_ urls: [URL], progress: Progress) -> Result? {
        var representatives: [Fingerprint] = []
        var groupFiles: [[Photo]] = []
        var buckets: [Int: [Int]] = [:]
        var unreadableCount = 0

        for url in urls {
            guard !progress.isCancelled else { return nil }
            defer { progress.completedUnitCount += 1 }
            guard let photo = Photo(url), let fingerprint = autoreleasepool(invoking: {
                thumbnail(at: url, maximumSize: 96).flatMap(Fingerprint.init)
            }), photo.isCurrent else {
                unreadableCount += 1
                continue
            }

            var candidates = Set<Int>()
            let keys = fingerprint.buckets
            for key in keys {
                if let indices = buckets[key] { candidates.formUnion(indices) }
            }
            var best: (index: Int, distance: Int)?
            for index in candidates {
                guard !progress.isCancelled else { return nil }
                guard let distance = fingerprint.distance(to: representatives[index]) else { continue }
                if let previous = best, (previous.distance, previous.index) <= (distance, index) { continue }
                best = (index, distance)
            }
            if let best {
                groupFiles[best.index].append(photo)
            } else {
                let index = representatives.count
                representatives.append(fingerprint)
                groupFiles.append([photo])
                for key in keys { buckets[key, default: []].append(index) }
            }
        }
        guard !progress.isCancelled else { return nil }
        return Result(groups: groupFiles.filter { $0.count > 1 }, unreadableCount: unreadableCount)
    }
}
