import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg
    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var typeIdentifier: String { self == .png ? UTType.png.identifier : UTType.jpeg.identifier }
}

public enum ImageExporter {
    public static func data(image: CGImage, format: ImageFormat, quality: Double = 0.9) throws -> Data {
        try ImageLimits.validate(width: image.width, height: image.height)
        guard quality.isFinite else { throw VelinshotError.encodingFailed }
        let output: CGImage
        if format == .jpeg {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw VelinshotError.renderingFailed
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw VelinshotError.renderingFailed }
            output = flattened
        } else {
            output = image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
            throw VelinshotError.encodingFailed
        }
        let options: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))]
            : [:]
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VelinshotError.encodingFailed }
        return data as Data
    }
}

public enum ImageLoader {
    public static let maximumEncodedBytes = 250_000_000

    public static func load(url: URL) throws -> CGImage {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true else { throw VelinshotError.invalidImage("Choose a regular image file.") }
        guard (properties.fileSize ?? 0) <= maximumEncodedBytes else { throw VelinshotError.imageTooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw VelinshotError.invalidImage("The file format is unsupported or the file is damaged.")
        }
        return try decode(source)
    }

    public static func load(data: Data) throws -> CGImage {
        guard data.count <= maximumEncodedBytes else { throw VelinshotError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw VelinshotError.invalidImage("The image data is damaged or unsupported.")
        }
        return try decode(source)
    }

    private static func decode(_ source: CGImageSource) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw VelinshotError.invalidImage("The image has no readable dimensions.")
        }
        try ImageLimits.validate(width: width, height: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw VelinshotError.invalidImage("The image could not be decoded.")
        }
        try ImageLimits.validate(width: image.width, height: image.height)
        return image
    }
}
