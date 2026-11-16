import CoreGraphics
import Foundation
import ImageIO

public struct ImageMetadata: Equatable, Sendable {
    public let pixelSize: CGSize
    public let formatIdentifier: String
    public let encodedByteCount: Int
}

/// A display proxy with an original-pixel coordinate space. Its bitmap is
/// intentionally internal so app export APIs cannot accidentally consume it.
public struct ImagePreview {
    public let sourceSize: CGSize
    let bitmap: CGImage
    public var pixelSize: CGSize { CGSize(width: bitmap.width, height: bitmap.height) }
}

/// A frozen input, independent of later changes to the original file. ImageIO
/// sources are created per operation rather than shared between worker queues.
public struct EncodedImageSource {
    public let metadata: ImageMetadata
    private let data: Data
    private let fallbackImage: CGImage?

    fileprivate init(data: Data, metadata: ImageMetadata, fallbackImage: CGImage?) {
        self.data = data; self.metadata = metadata; self.fallbackImage = fallbackImage
    }

    public func fullResolution() throws -> CGImage {
        if let fallbackImage { return fallbackImage }
        return try ImageLoader.load(data: data)
    }

    public func preview(maxDimension: Int = 1400) throws -> ImagePreview {
        try ImageLoader.validatePreviewDimension(maxDimension)
        if let fallbackImage { return try ImageLoader.preview(image: fallbackImage, maxDimension: maxDimension) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw VelinshotError.invalidImage("The preview could not be decoded.") }
        return ImagePreview(sourceSize: metadata.pixelSize, bitmap: image)
    }
}

extension ImageLoader {
    public static func open(url: URL) throws -> EncodedImageSource {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true else { throw VelinshotError.invalidImage("Choose a regular image file.") }
        let expected = properties.fileSize ?? 0
        guard expected <= maximumEncodedBytes else { throw VelinshotError.imageTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try BoundedSnapshotReader.read(expectedSize: expected, limit: maximumEncodedBytes) {
            try handle.read(upToCount: $0)
        }
        return try open(data: data)
    }

    public static func open(data: Data) throws -> EncodedImageSource {
        guard data.count <= maximumEncodedBytes else { throw VelinshotError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw VelinshotError.invalidImage("The image has no readable dimensions.")
        }
        // Reject oversized metadata before creating either a proxy or original.
        try ImageLimits.validate(width: width, height: height)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let fallback: CGImage?
        let size: CGSize
        if !(1...8).contains(orientation) || hasUncommonPixelAspect(properties) {
            let full = try load(data: data)
            fallback = full; size = CGSize(width: full.width, height: full.height)
        } else {
            fallback = nil
            size = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        let metadata = ImageMetadata(pixelSize: size,
            formatIdentifier: (CGImageSourceGetType(source) as String?) ?? "public.image", encodedByteCount: data.count)
        return EncodedImageSource(data: data, metadata: metadata, fallbackImage: fallback)
    }

    public static func preview(image: CGImage, maxDimension: Int = 1400) throws -> ImagePreview {
        try validatePreviewDimension(maxDimension)
        try ImageLimits.validate(width: image.width, height: image.height)
        let sourceSize = CGSize(width: image.width, height: image.height)
        let scale = min(1, CGFloat(maxDimension) / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VelinshotError.renderingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let proxy = context.makeImage() else { throw VelinshotError.renderingFailed }
        return ImagePreview(sourceSize: sourceSize, bitmap: proxy)
    }

    fileprivate static func validatePreviewDimension(_ maximum: Int) throws {
        guard (1...4096).contains(maximum) else {
            throw VelinshotError.invalidImage("Preview size must be between 1 and 4096 pixels.")
        }
    }

    private static func hasUncommonPixelAspect(_ properties: [CFString: Any]) -> Bool {
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let ratio = png[kCGImagePropertyPNGPixelsAspectRatio] as? NSNumber, abs(ratio.doubleValue - 1) > 1e-8 { return true }
            if let x = png[kCGImagePropertyPNGXPixelsPerMeter] as? NSNumber,
               let y = png[kCGImagePropertyPNGYPixelsPerMeter] as? NSNumber, x != y { return true }
        }
        if let exr = properties[kCGImagePropertyOpenEXRDictionary] as? [CFString: Any],
           let ratio = exr[kCGImagePropertyOpenEXRAspectRatio] as? NSNumber, abs(ratio.doubleValue - 1) > 1e-8 { return true }
        return false
    }
}

/// Internal injection point for finite short-read/growth/limit regressions.
/// Normal regular files return one owned bulk Data value without appending a
/// second complete encoded-byte copy. Metadata is always read from that value.
enum BoundedSnapshotReader {
    static func read(expectedSize: Int, limit: Int, readChunk: (Int) throws -> Data?) throws -> Data {
        guard limit >= 0, limit < Int.max else { throw VelinshotError.invalidImage("The encoded byte limit is invalid.") }
        guard expectedSize <= limit else { throw VelinshotError.imageTooLarge }
        let firstCount = min(limit + 1, max(1, max(0, expectedSize) + 1))
        guard var data = try autoreleasepool(invoking: { try readChunk(firstCount) }), !data.isEmpty else { return Data() }
        guard data.count <= limit else { throw VelinshotError.imageTooLarge }
        while true {
            let remaining = limit - data.count
            let reachedEOF = try autoreleasepool { () throws -> Bool in
                // A short positive read is not EOF. One extra byte detects
                // growth at the hard cap before anything is appended.
                guard let chunk = try readChunk(min(1_048_576, remaining + 1)), !chunk.isEmpty else { return true }
                guard chunk.count <= remaining else { throw VelinshotError.imageTooLarge }
                data.append(chunk)
                return false
            }
            if reachedEOF { return data }
        }
    }
}
