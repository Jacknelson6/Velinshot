import AppKit
import XCTest
@testable import VelinshotCore

final class EdgeCoverageTests: XCTestCase {
    func testOpaqueSolidBackgroundCoversFractionalRatioAndHalfScaleEdges() throws {
        let source = makeImage(width: 101, height: 81) { _, _ in (0, 255, 0, 255) }
        var ratio = plainState()
        ratio.style.padding = 4
        ratio.style.background = .solid
        ratio.style.color1 = RGBA(hex: "C10F7B")
        ratio.style.ratioWidth = 4
        ratio.style.ratioHeight = 3
        var half = ratio
        half.style.ratioWidth = 0
        half.style.ratioHeight = 0
        half.style.outputScale = 0.5
        for state in [ratio, half] {
            let output = try CanvasRenderer.render(source: source, state: state)
            let edge = try outerPixels(output)
            XCTAssertEqual(edge.map(\.a).min(), 255, "An opaque solid mat must cover every device edge pixel.")
            let decoded = try ImageLoader.load(data: ImageExporter.data(image: output, format: .png))
            XCTAssertEqual(try outerPixels(decoded).map(\.a).min(), 255)
        }
    }

    func testOpaqueImageBackgroundCoversFractionalRatioAndHalfScaleEdges() throws {
        let source = makeImage(width: 101, height: 81) { _, _ in (0, 255, 0, 255) }
        let background = makeImage(width: 4, height: 3) { _, _ in (193, 15, 123, 255) }
        var ratio = plainState()
        ratio.style.padding = 4
        ratio.style.background = .image
        ratio.style.ratioWidth = 4
        ratio.style.ratioHeight = 3
        var half = ratio
        half.style.ratioWidth = 0
        half.style.ratioHeight = 0
        half.style.outputScale = 0.5
        for state in [ratio, half] {
            let output = try CanvasRenderer.render(source: source, state: state, backgroundImage: background)
            XCTAssertEqual(try outerPixels(output).map(\.a).min(), 255,
                           "An opaque image mat must cover every device edge pixel.")
        }
    }

    func testSelectedAlphaAndTransparentBackgroundRemainIntentionalAtEdges() throws {
        let source = makeImage(width: 101, height: 81) { _, _ in (0, 255, 0, 255) }
        var state = plainState()
        state.style.padding = 3
        state.style.outputScale = 0.5
        state.style.background = .solid
        state.style.color1 = RGBA(red: 1, green: 0, blue: 0, alpha: 0.5)
        let translucent = try outerPixels(CanvasRenderer.render(source: source, state: state))
        XCTAssertGreaterThan(translucent.map(\.a).min() ?? 0, 126)
        XCTAssertLessThanOrEqual(translucent.map(\.a).max() ?? 255, 128)
        state.style.background = .transparent
        let transparent = try outerPixels(CanvasRenderer.render(source: source, state: state))
        XCTAssertEqual(transparent.map(\.a).max(), 0)
    }

    func testHalfScalePNGAndJPEGHaveNoAccidentalLightEdge() throws {
        let source = makeImage(width: 101, height: 81) { _, _ in (0, 255, 0, 255) }
        var state = plainState()
        state.style.padding = 33
        state.style.outputScale = 0.5
        state.style.background = .solid
        state.style.color1 = RGBA(hex: "C10F7B")
        let output = try CanvasRenderer.render(source: source, state: state)
        let png = try ImageLoader.load(data: ImageExporter.data(image: output, format: .png))
        XCTAssertEqual(pixel(png, png.width - 1, png.height - 1), Pixel(193, 15, 123, 255))
        let jpeg = try ImageLoader.load(data: ImageExporter.data(image: output, format: .jpeg, quality: 1))
        let edge = pixel(jpeg, jpeg.width - 1, jpeg.height - 1)
        XCTAssertLessThan(abs(Int(edge.r) - 193), 8)
        XCTAssertLessThan(abs(Int(edge.g) - 15), 8)
        XCTAssertLessThan(abs(Int(edge.b) - 123), 8)
    }

    func testTranslucentImageBackgroundKeepsItsOwnAlphaAtFractionalEdges() throws {
        let source = makeImage(width: 101, height: 81) { _, _ in (0, 255, 0, 255) }
        let background = makeImage(width: 4, height: 3) { _, _ in (128, 0, 0, 128) }
        var state = plainState()
        state.style.padding = 4
        state.style.outputScale = 0.5
        state.style.background = .image
        let output = try CanvasRenderer.render(source: source, state: state, backgroundImage: background)
        let edge = try outerPixels(output)
        XCTAssertGreaterThan(edge.map(\.a).min() ?? 0, 126)
        XCTAssertLessThanOrEqual(edge.map(\.a).max() ?? 255, 128)
    }
}

private func outerPixels(_ image: CGImage) throws -> [Pixel] {
    let sample = try XCTUnwrap(PixelSample(source: image))
    var result: [Pixel] = []
    for x in 0..<sample.width {
        for y in [0, sample.height - 1] {
            let p = sample.pixel(x: x, y: y)
            result.append(Pixel(p.0, p.1, p.2, p.3))
        }
    }
    for y in 0..<sample.height {
        for x in [0, sample.width - 1] {
            let p = sample.pixel(x: x, y: y)
            result.append(Pixel(p.0, p.1, p.2, p.3))
        }
    }
    return result
}
