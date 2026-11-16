import AppKit
import XCTest
@testable import VelinshotCore

final class ImageAndAnalysisTests: XCTestCase {
    func testPNGFileAndDataRoundTripPreservePixelsAndAlpha() throws {
        let image = makeImage(width: 40, height: 30) { x, y in
            x < 10 ? (0, 0, 0, 0) : (UInt8(x * 5), UInt8(y * 7), 33, 255)
        }
        let encoded = try ImageExporter.data(image: image, format: .png)
        let decoded = try ImageLoader.load(data: encoded)
        XCTAssertEqual(decoded.width, 40)
        XCTAssertEqual(decoded.height, 30)
        XCTAssertEqual(pixel(decoded, 0, 0).a, 0)
        XCTAssertEqual(pixel(decoded, 20, 5), pixel(image, 20, 5))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("asymmetric.png")
        try encoded.write(to: url)
        let fromFile = try ImageLoader.load(url: url)
        XCTAssertEqual(pixel(fromFile, 20, 25), pixel(image, 20, 25))
    }

    func testJPEGFlattensAlphaToWhiteAndKeepsOrientation() throws {
        let image = makeImage(width: 80, height: 60) { x, y in
            if x < 25 { return (0, 0, 0, 0) }
            return y < 30 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        let decoded = try ImageLoader.load(data: ImageExporter.data(image: image, format: .jpeg, quality: 1))
        let transparent = pixel(decoded, 5, 5)
        XCTAssertGreaterThan(transparent.r, 245)
        XCTAssertGreaterThan(transparent.g, 245)
        XCTAssertGreaterThan(transparent.b, 245)
        XCTAssertEqual(transparent.a, 255)
        XCTAssertGreaterThan(pixel(decoded, 60, 10).r, 220)
        XCTAssertGreaterThan(pixel(decoded, 60, 50).b, 220)
    }

    func testJPEGCompressionQualityChangesActualOutputSize() throws {
        let image = makeImage(width: 300, height: 200) { x, y in
            let seed = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
            return (UInt8(truncatingIfNeeded: seed), UInt8(truncatingIfNeeded: seed >> 8), UInt8(truncatingIfNeeded: seed >> 16), 255)
        }
        let low = try ImageExporter.data(image: image, format: .jpeg, quality: 0.1)
        let high = try ImageExporter.data(image: image, format: .jpeg, quality: 0.95)
        XCTAssertLessThan(low.count, high.count)
        XCTAssertEqual(try ImageLoader.load(data: low).width, 300)
        XCTAssertEqual(try ImageLoader.load(data: high).height, 200)
    }

    func testCorruptAndNonImageInputFailWithActionableError() throws {
        XCTAssertThrowsError(try ImageLoader.load(data: Data("not an image".utf8))) {
            XCTAssertTrue($0.localizedDescription.contains("image"))
        }
        XCTAssertThrowsError(try ImageLoader.load(data: Data()))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try ImageLoader.load(url: directory))
        XCTAssertThrowsError(try ImageLoader.load(url: directory.appendingPathComponent("missing.png")))
    }

    func testPixelLimitsRejectOverflowWithoutAllocation() {
        XCTAssertThrowsError(try ImageLimits.validate(width: Int.max, height: Int.max))
        XCTAssertThrowsError(try ImageLimits.validate(width: 10_000, height: 5_000))
        XCTAssertThrowsError(try ImageLimits.validate(width: 16_385, height: 1))
        XCTAssertThrowsError(try ImageLimits.validate(width: 0, height: 1))
        XCTAssertNoThrow(try ImageLimits.validate(width: 8_000, height: 5_000))
    }

    func testContentBoundsKeepThinAsymmetricContentAndSafetyMargin() {
        let source = makeImage(width: 100, height: 80) { x, y in
            if (x >= 30 && x < 50 && y >= 10 && y < 30) || (x == 10 && y == 50) { return (0, 0, 0, 255) }
            return (255, 255, 255, 255)
        }
        XCTAssertEqual(AutoBeautify.contentBounds(source: source), CGRect(x: 8, y: 8, width: 44, height: 45))
    }

    func testContentBoundsTrimTransparentBorderWithoutLosingContent() {
        let source = makeImage(width: 100, height: 80) { x, y in
            x >= 30 && x < 50 && y >= 10 && y < 30 ? (255, 0, 0, 255) : (0, 0, 0, 0)
        }
        XCTAssertEqual(AutoBeautify.contentBounds(source: source), CGRect(x: 28, y: 8, width: 24, height: 24))
    }

    func testAutomaticBalanceLeavesUniformOrNonuniformEdgesAlone() {
        let uniform = makeImage(width: 40, height: 30) { _, _ in (255, 255, 255, 255) }
        XCTAssertNil(AutoBeautify.contentBounds(source: uniform))
        let cornersDiffer = makeImage(width: 40, height: 30) { x, _ in x < 20 ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        XCTAssertNil(AutoBeautify.contentBounds(source: cornersDiffer))
    }

    func testSuggestedColorsFollowSourceHueAndAreOpaque() {
        let red = makeImage(width: 40, height: 30) { _, _ in (255, 0, 0, 255) }
        let (first, second) = AutoBeautify.suggestColors(source: red)
        XCTAssertGreaterThan(first.red, first.green)
        XCTAssertGreaterThan(first.red, first.blue)
        XCTAssertEqual(first.alpha, 1)
        XCTAssertEqual(second.alpha, 1)
    }

    func testVisionExtractsTextWithTopLeftCoordinates() throws {
        let source = makeImage(width: 640, height: 180) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.annotations = [Annotation(kind: .text, points: [CGPoint(x: 25, y: 20)], color: RGBA(hex: "000000"),
                                        text: "VELINSHOT 2048", fontSize: 48)]
        let image = try CanvasRenderer.render(source: source, state: state)
        let recognized = try TextRecognizer.recognize(image: image)
        let text = recognized.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.uppercased().contains("VELINSHOT"), text)
        XCTAssertTrue(text.contains("2048"), text)
        let rect = try XCTUnwrap(recognized.first?.rect)
        XCTAssertLessThan(rect.minY, 90)
        XCTAssertGreaterThan(rect.width, 200)
    }

    func testVisionBlankImageHasNoInventedText() throws {
        let source = makeImage(width: 240, height: 100) { _, _ in (255, 255, 255, 255) }
        XCTAssertTrue(try TextRecognizer.recognize(image: source).isEmpty)
    }

    func testRGBAAndEditStateCodableRoundTrip() throws {
        let color = RGBA(hex: "FF800040")
        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 128.0 / 255)
        XCTAssertEqual(color.alpha, 64.0 / 255)
        var state = EditState()
        state.crop = CGRect(x: 12, y: 21, width: 100, height: 80)
        state.annotations = [Annotation(kind: .arrow, points: [.zero, CGPoint(x: 20, y: 40)], color: color)]
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state)), state)
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("velinshot-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
