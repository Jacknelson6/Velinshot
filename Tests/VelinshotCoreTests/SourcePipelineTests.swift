import AppKit
import Foundation
import ImageIO
import XCTest
@testable import VelinshotCore

final class SourcePipelineTests: XCTestCase {
    func testEncodedSnapshotSurvivesFileReplacementAndDeletion() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        let red = makeImage(width: 90, height: 60) { _, _ in (255, 0, 0, 255) }
        let blue = makeImage(width: 20, height: 10) { _, _ in (0, 0, 255, 255) }
        try ImageExporter.data(image: red, format: .png).write(to: url)
        let frozen = try ImageLoader.open(url: url)
        try ImageExporter.data(image: blue, format: .png).write(to: url, options: .atomic)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(frozen.metadata.pixelSize, CGSize(width: 90, height: 60))
        XCTAssertEqual(pixel(try frozen.fullResolution(), 30, 30), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(try frozen.preview(maxDimension: 30).bitmap, 10, 10), Pixel(255, 0, 0, 255))
    }

    func testSnapshotMetadataAndOriginalDecodeAreStableAcrossAllEXIFOrientations() throws {
        let source = quadrantSource()
        let colors = [Pixel(255, 0, 0, 255), Pixel(0, 255, 0, 255), Pixel(0, 0, 255, 255), Pixel(255, 255, 0, 255)]
        let expected = [[0,1,2,3],[1,0,3,2],[3,2,1,0],[2,3,0,1],[0,2,1,3],[2,0,3,1],[3,1,2,0],[1,3,0,2]]
        for orientation in 1...8 {
            let data = try encodedTIFF(source, properties: [kCGImagePropertyOrientation: orientation])
            let snapshot = try ImageLoader.open(data: data)
            let full = try snapshot.fullResolution()
            let legacy = try ImageLoader.load(data: data)
            let size = orientation >= 5 ? CGSize(width: 60, height: 80) : CGSize(width: 80, height: 60)
            XCTAssertEqual(snapshot.metadata.pixelSize, size)
            XCTAssertEqual(CGSize(width: full.width, height: full.height), size)
            XCTAssertEqual(PixelSample(source: full)?.bytes, PixelSample(source: legacy)?.bytes)
            let proxy = try snapshot.preview(maxDimension: 16)
            XCTAssertEqual(proxy.sourceSize, size)
            let actual = cornerPixels(proxy.bitmap)
            XCTAssertEqual(actual, expected[orientation-1].map { colors[$0] }, "EXIF \(orientation)")
        }
    }

    func testPreviewRetainsAlphaAndICCColorMatchesNativeRendering() throws {
        let alpha = makeImage(width: 80, height: 60) { x, _ in x < 40 ? (128, 32, 0, 128) : (0, 0, 0, 0) }
        let alphaProxy = try ImageLoader.preview(image: alpha, maxDimension: 40)
        XCTAssertEqual(pixel(alphaProxy.bitmap, 5, 5).a, 128)
        XCTAssertEqual(pixel(alphaProxy.bitmap, 35, 5).a, 0)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.15, 0.4, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let image = try XCTUnwrap(context.makeImage())
        let data = try ImageExporter.data(image: image, format: .png)
        let snapshot = try ImageLoader.open(data: data)
        let full = try snapshot.fullResolution()
        let proxy = try ImageLoader.preview(image: full, maxDimension: 80)
        let cached = try CanvasRenderer.renderPreview(source: proxy, state: plainState(), maximumDimension: 80)
        let reference = try CanvasRenderer.render(source: full, state: plainState(), previewMaxDimension: 80)
        let first = pixel(cached, 30, 20), second = pixel(reference, 30, 20)
        XCTAssertLessThan(abs(Int(first.r) - Int(second.r)), 3)
        XCTAssertLessThan(abs(Int(first.g) - Int(second.g)), 3)
        XCTAssertLessThan(abs(Int(first.b) - Int(second.b)), 3)
    }

    func testFullExportKeepsPixelsBeyondProxyResolution() throws {
        let original = makeImage(width: 2001, height: 1501) { x, y in
            x == 1900 && y == 1400 ? (255, 0, 0, 255) : (255, 255, 255, 255)
        }
        let snapshot = try ImageLoader.open(data: ImageExporter.data(image: original, format: .png))
        let proxy = try snapshot.preview()
        XCTAssertLessThanOrEqual(max(proxy.pixelSize.width, proxy.pixelSize.height), 1400)
        let full = try snapshot.fullResolution()
        let exported = try CanvasRenderer.render(source: full, state: plainState())
        XCTAssertEqual(exported.width, 2001)
        XCTAssertEqual(exported.height, 1501)
        XCTAssertEqual(pixel(exported, 1900, 1400), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(exported, 1899, 1400), Pixel(255, 255, 255, 255))
        XCTAssertEqual(PixelSample(source: exported)?.bytes, PixelSample(source: original)?.bytes)
    }

    func testOddSourcePreviewUsesOriginalCoordinatesForCropAndAnnotation() throws {
        let original = makeImage(width: 4001, height: 3003) { _, _ in (255, 255, 255, 255) }
        let proxy = try ImageLoader.preview(image: original)
        XCTAssertEqual(proxy.sourceSize, CGSize(width: 4001, height: 3003))
        XCTAssertEqual(proxy.pixelSize, CGSize(width: 1400, height: 1051))
        XCTAssertGreaterThan(abs(proxy.pixelSize.width / 4001 - proxy.pixelSize.height / 3003), 0)
        var state = plainState()
        state.style.padding = 11; state.style.inset = 5; state.style.cornerRadius = 7; state.style.shadow = 10
        state.crop = CGRect(x: 137, y: 211, width: 1001, height: 777)
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 180, y: 300), CGPoint(x: 280, y: 400)], color: RGBA(hex: "FF0000"))]
        let cached = try CanvasRenderer.renderPreview(source: proxy, state: state, maximumDimension: 800)
        let reference = try CanvasRenderer.render(source: original, state: state, previewMaxDimension: 800)
        let layout = try CanvasRenderer.layout(sourceSize: CGSize(width: 4001, height: 3003), state: state)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 1033, height: 809))
        XCTAssertEqual(layout.imageRect, CGRect(x: 16, y: 16, width: 1001, height: 777))
        let scale: CGFloat = 800.0 / 1033
        let sourceEdge = CGRect(x: 16 * scale, y: 16 * scale, width: 1001 * scale, height: 777 * scale)
        let stats = try previewDifference(cached, reference, allowedSourceEdge: sourceEdge)
        print("Odd proxy raster diagnostic: \(stats)")
        XCTAssertEqual(stats.nonEdgePixels, 0, "Every pixel outside the 1px source-edge band remains exact: \(stats)")
        XCTAssertLessThanOrEqual(stats.maxDelta, 40, "Only the fractional source clip edge has this raster tolerance.")
        XCTAssertLessThanOrEqual(stats.changedPixels, Int(ceil(2 * (sourceEdge.width + sourceEdge.height))) + 16)
        let marker = try XCTUnwrap(redBounds(cached))
        XCTAssertEqual(marker, redBounds(reference))
        let expectedMarker = CGRect(x: 59 * scale, y: 105 * scale, width: 100 * scale, height: 100 * scale)
        XCTAssertLessThan(abs(marker.minX - expectedMarker.minX), 1)
        XCTAssertLessThan(abs(marker.minY - expectedMarker.minY), 1)
        XCTAssertLessThan(abs(marker.maxX - expectedMarker.maxX), 1)
        XCTAssertLessThan(abs(marker.maxY - expectedMarker.maxY), 1)
        XCTAssertEqual(pixel(cached, Int(109 * scale), Int(155 * scale)), Pixel(255, 0, 0, 255))
    }

    func testNarrowSourceAndCropKeepIndependentAxisMapping() throws {
        let original = makeImage(width: 1, height: 4000) { _, _ in (255, 255, 255, 255) }
        let proxy = try ImageLoader.preview(image: original)
        XCTAssertEqual(proxy.pixelSize, CGSize(width: 1, height: 1400))
        XCTAssertEqual(proxy.sourceSize, CGSize(width: 1, height: 4000))
        var state = plainState()
        state.crop = CGRect(x: 0, y: 31, width: 1, height: 1501)
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 0, y: 501), CGPoint(x: 1, y: 701)], color: RGBA(hex: "00FF00"))]
        let cached = try CanvasRenderer.renderPreview(source: proxy, state: state, maximumDimension: 1000)
        let reference = try CanvasRenderer.render(source: original, state: state, previewMaxDimension: 1000)
        XCTAssertEqual(cached.width, 1)
        XCTAssertEqual(cached.height, 1000)
        XCTAssertEqual(PixelSample(source: cached)?.bytes, PixelSample(source: reference)?.bytes)
    }

    func testCachedPreviewKeepsAllAnnotationToolsAndBlurInOriginalSpace() throws {
        let original = makeImage(width: 600, height: 400) { x, _ in x % 4 < 2 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let proxy = try ImageLoader.preview(image: original, maxDimension: 300)
        for kind in AnnotationKind.allCases {
            var state = plainState()
            state.crop = CGRect(x: 31, y: 17, width: 500, height: 300)
            state.annotations = [Annotation(kind: kind, points: [CGPoint(x: 100, y: 80), CGPoint(x: 260, y: 200)],
                                            color: RGBA(hex: "FF0000"), lineWidth: 12, text: "Note", fontSize: 40)]
            let output = try CanvasRenderer.renderPreview(source: proxy, state: state, maximumDimension: 300)
            XCTAssertEqual(output.width, 300)
            XCTAssertEqual(output.height, 180)
            if kind == .blur {
                let inside = pixel(output, 80, 70)
                XCTAssertGreaterThan(inside.r, 40); XCTAssertLessThan(inside.r, 215)
                XCTAssertEqual(inside.a, 255)
            } else if kind == .redact {
                XCTAssertEqual(pixel(output, 80, 70), Pixel(255, 0, 0, 255))
            }
        }
    }

    func testCachedBackgroundProxyPreservesLogicalAspectAndAlpha() throws {
        let original = makeImage(width: 300, height: 200) { _, _ in (255, 255, 255, 255) }
        let background = makeImage(width: 401, height: 303) { x, _ in x < 200 ? (128, 0, 0, 128) : (0, 0, 128, 128) }
        let sourceProxy = try ImageLoader.preview(image: original, maxDimension: 200)
        let backgroundProxy = try ImageLoader.preview(image: background, maxDimension: 200)
        var state = plainState(); state.style.padding = 50; state.style.background = .image
        let cached = try CanvasRenderer.renderPreview(source: sourceProxy, state: state, backgroundPreview: backgroundProxy, maximumDimension: 200)
        let reference = try CanvasRenderer.render(source: original, state: state, backgroundImage: background, previewMaxDimension: 200)
        XCTAssertEqual(pixel(cached, 5, 5), pixel(reference, 5, 5))
        XCTAssertEqual(pixel(cached, cached.width-5, 5), pixel(reference, reference.width-5, 5))
    }

    func testPreviewDoesNotUpscaleTinyImagesAndRejectsInvalidLimits() throws {
        let source = makeImage(width: 8, height: 5) { _, _ in (255, 0, 0, 255) }
        let proxy = try ImageLoader.preview(image: source)
        XCTAssertEqual(proxy.pixelSize, CGSize(width: 8, height: 5))
        XCTAssertThrowsError(try ImageLoader.preview(image: source, maxDimension: 0))
        XCTAssertThrowsError(try ImageLoader.preview(image: source, maxDimension: 4097))
    }

    func test64MPMetadataIsRejectedBeforeNativeDecode() throws {
        let bits = Data(repeating: 0, count: 8_000_000)
        let image = try XCTUnwrap(CGImage(width: 8000, height: 8000, bitsPerComponent: 1, bitsPerPixel: 1,
            bytesPerRow: 1000, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: bits as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = encoded as Data
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 8000)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 8000)
        XCTAssertThrowsError(try ImageLoader.open(data: data)) { XCTAssertEqual($0 as? VelinshotError, .imageTooLarge) }
    }

    func testBoundedFileOpenRejectsOversizedSparseInputBeforeReading() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.png")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(ImageLoader.maximumEncodedBytes + 1)); try handle.close()
        XCTAssertThrowsError(try ImageLoader.open(url: url)) { XCTAssertEqual($0 as? VelinshotError, .imageTooLarge) }
    }

    func testPixelAspectMetadataUsesNativeDecodeDimensions() throws {
        let source = quadrantSource()
        let png = try ImageExporter.data(image: source, format: .png)
        var dimensions = Data(); appendUInt32(&dimensions, 3780); appendUInt32(&dimensions, 1890); dimensions.append(1)
        var chunk = Data(); appendUInt32(&chunk, UInt32(dimensions.count)); chunk.append(Data("pHYs".utf8)); chunk.append(dimensions)
        appendUInt32(&chunk, crc32(Data(chunk[4...])))
        var data = Data(png.prefix(33)); data.append(chunk); data.append(png.dropFirst(33))
        let native = try ImageLoader.load(data: data)
        let snapshot = try ImageLoader.open(data: data)
        XCTAssertEqual(snapshot.metadata.pixelSize, CGSize(width: native.width, height: native.height))
        XCTAssertEqual(try snapshot.preview(maxDimension: 32).sourceSize, snapshot.metadata.pixelSize)
        XCTAssertEqual(PixelSample(source: try snapshot.fullResolution())?.bytes, PixelSample(source: native)?.bytes)
    }
}

private func quadrantSource() -> CGImage {
    makeImage(width: 80, height: 60) { x, y in
        if y < 30 { return x < 40 ? (255,0,0,255) : (0,255,0,255) }
        return x < 40 ? (0,0,255,255) : (255,255,0,255)
    }
}
private func cornerPixels(_ image: CGImage) -> [Pixel] {
    [pixel(image,1,1), pixel(image,image.width-2,1), pixel(image,1,image.height-2), pixel(image,image.width-2,image.height-2)]
}
private func encodedTIFF(_ image: CGImage, properties: [CFString: Any]) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw VelinshotError.encodingFailed }
    return data as Data
}
private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    data.append(contentsOf: [UInt8(truncatingIfNeeded:value >> 24),UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)])
}
private func replaceUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
    var bytes = Data(); appendUInt32(&bytes, value); data.replaceSubrange(offset..<offset+4, with: bytes)
}
private func crc32(_ data: Data) -> UInt32 {
    var result: UInt32 = 0xFFFFFFFF
    for value in data { result ^= UInt32(value); for _ in 0..<8 { result = (result >> 1) ^ ((result & 1) == 1 ? 0xEDB88320 : 0) } }
    return result ^ 0xFFFFFFFF
}

private struct PreviewDifference: CustomStringConvertible {
    let changedPixels: Int
    let maxDelta: Int
    let nonEdgePixels: Int
    let samples: [String]
    var description: String { "changed=\(changedPixels), maxDelta=\(maxDelta), nonEdge=\(nonEdgePixels), samples=\(samples)" }
}
private func previewDifference(_ lhs: CGImage, _ rhs: CGImage, allowedSourceEdge: CGRect) throws -> PreviewDifference {
    XCTAssertEqual(lhs.width, rhs.width); XCTAssertEqual(lhs.height, rhs.height)
    let a = try XCTUnwrap(PixelSample(source: lhs)), b = try XCTUnwrap(PixelSample(source: rhs))
    var changed = 0, maximum = 0, nonEdge = 0, samples: [String] = []
    for y in 0..<a.height {
        for x in 0..<a.width {
            let first = a.pixel(x: x, y: y), second = b.pixel(x: x, y: y)
            let delta = max(abs(Int(first.0)-Int(second.0)),abs(Int(first.1)-Int(second.1)),abs(Int(first.2)-Int(second.2)),abs(Int(first.3)-Int(second.3)))
            if delta > 0 {
                changed += 1; maximum = max(maximum,delta)
                let center = CGPoint(x: CGFloat(x)+0.5, y: CGFloat(y)+0.5)
                if !allowedSourceEdge.insetBy(dx: -1, dy: -1).contains(center) || allowedSourceEdge.insetBy(dx: 1, dy: 1).contains(center) {
                    nonEdge += 1
                }
                if samples.count < 8 { samples.append("(\(x),\(y)) \(first) vs \(second)") }
            }
        }
    }
    return PreviewDifference(changedPixels:changed,maxDelta:maximum,nonEdgePixels:nonEdge,samples:samples)
}

private func redBounds(_ image: CGImage) -> CGRect? {
    guard let sample = PixelSample(source: image) else { return nil }
    var left = sample.width, top = sample.height, right = -1, bottom = -1
    for y in 0..<sample.height { for x in 0..<sample.width {
        let p = sample.pixel(x: x, y: y)
        if p.0 > 200 && p.1 < 20 && p.2 < 20 && p.3 > 200 {
            left = min(left,x); top = min(top,y); right = max(right,x); bottom = max(bottom,y)
        }
    } }
    return right >= left ? CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1) : nil
}
