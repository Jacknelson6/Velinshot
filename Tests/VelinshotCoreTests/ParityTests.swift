import AppKit
import Foundation
import XCTest
@testable import VelinshotCore

final class ParityTests: XCTestCase {
    func testSeparatePaddingInsetAndPanelColorHaveIndependentGeometryAndPixels() throws {
        let source = makeImage(width: 80, height: 40) { _, _ in (0, 0, 255, 255) }
        var state = plainState()
        state.style.padding = 10
        state.style.inset = 5
        state.style.insetColor = RGBA(hex: "00FF00")
        state.style.background = .solid
        state.style.color1 = RGBA(hex: "FF0000")
        let layout = try CanvasRenderer.layout(sourceSize: CGSize(width: 80, height: 40), state: state)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 110, height: 70))
        XCTAssertEqual(layout.panelRect, CGRect(x: 10, y: 10, width: 90, height: 50))
        XCTAssertEqual(layout.imageRect, CGRect(x: 15, y: 15, width: 80, height: 40))
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(pixel(output, 5, 5), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(output, 12, 12), Pixel(0, 255, 0, 255))
        XCTAssertEqual(pixel(output, 20, 20), Pixel(0, 0, 255, 255))
    }

    func testRadiusAppliesToInsetPanelAndSourceUsesInnerRadius() throws {
        let source = makeImage(width: 80, height: 40) { _, _ in (0, 255, 0, 255) }
        var state = plainState()
        state.style.padding = 10
        state.style.inset = 10
        state.style.cornerRadius = 20
        state.style.insetColor = RGBA(hex: "FFFFFF")
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(pixel(output, 10, 10).a, 0)
        XCTAssertEqual(pixel(output, 20, 20), Pixel(255, 255, 255, 255))
        XCTAssertEqual(pixel(output, 27, 27), Pixel(0, 255, 0, 255))
    }

    func testInsetWithCropKeepsAnnotationCoordinatesInOriginalSourcePixels() throws {
        let source = makeImage(width: 100, height: 80) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 5
        state.style.inset = 10
        state.crop = CGRect(x: 30, y: 10, width: 40, height: 20)
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 35, y: 15), CGPoint(x: 45, y: 20)], color: RGBA(hex: "FF0000"))]
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(output.width, 70)
        XCTAssertEqual(output.height, 50)
        XCTAssertEqual(pixel(output, 22, 22), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(output, 31, 22), Pixel(255, 255, 255, 255))
    }

    func testZeroInsetMatchesIndependentPixelAndGeometryGolden() throws {
        let source = makeImage(width: 11, height: 7) { x, y in (UInt8(x * 20), UInt8(y * 30), 80, 255) }
        var state = plainState()
        state.style.padding = 3
        state.style.background = .solid
        state.style.color1 = RGBA(hex: "112233")
        state.style.insetColor = RGBA(hex: "FF0000")
        let layout = try CanvasRenderer.layout(sourceSize: CGSize(width: 11, height: 7), state: state)
        XCTAssertEqual(layout.panelRect, layout.imageRect)
        XCTAssertEqual(layout.imageRect, CGRect(x: 3, y: 3, width: 11, height: 7))
        let output = try CanvasRenderer.render(source: source, state: state)
        let sample = try XCTUnwrap(PixelSample(source: output))
        for y in 0..<13 {
            for x in 0..<17 {
                let p = sample.pixel(x: x, y: y)
                let expected = x >= 3 && x < 14 && y >= 3 && y < 10
                    ? Pixel(UInt8((x - 3) * 20), UInt8((y - 3) * 30), 80, 255) : Pixel(17, 34, 51, 255)
                XCTAssertEqual(Pixel(p.0, p.1, p.2, p.3), expected)
            }
        }
    }

    func testFixed400x300And1920x1080FitBothSmallAndLargeSourcesExactly() throws {
        for sourceSize in [CGSize(width: 64, height: 48), CGSize(width: 2048, height: 1536)] {
            let source = makeImage(width: Int(sourceSize.width), height: Int(sourceSize.height)) { x, _ in
                x < Int(sourceSize.width) / 2 ? (255, 0, 0, 255) : (0, 255, 0, 255)
            }
            for target in [CGSize(width: 400, height: 300), CGSize(width: 1920, height: 1080)] {
                var state = plainState()
                state.style.background = .solid
                state.style.color1 = RGBA(hex: "0000FF")
                state.style.fixedWidth = Int(target.width)
                state.style.fixedHeight = Int(target.height)
                let layout = try CanvasRenderer.layout(sourceSize: sourceSize, state: state)
                let scale = target.width / layout.canvasSize.width
                XCTAssertLessThan(abs(scale - target.height / layout.canvasSize.height), 1e-10)
                XCTAssertEqual(layout.imageRect.size, sourceSize)
                let output = try CanvasRenderer.render(source: source, state: state)
                XCTAssertEqual(output.width, Int(target.width))
                XCTAssertEqual(output.height, Int(target.height))
                XCTAssertEqual(pixel(output, output.width / 2 - 20, output.height / 2), Pixel(255, 0, 0, 255))
                XCTAssertEqual(pixel(output, output.width / 2 + 20, output.height / 2), Pixel(0, 255, 0, 255))
                if target.width == 1920 {
                    XCTAssertEqual(pixel(output, 10, output.height / 2), Pixel(0, 0, 255, 255))
                }
            }
        }
    }

    func testFixedSizeScalesInsetAndSourceAnnotationsUniformly() throws {
        let source = makeImage(width: 80, height: 40) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 10
        state.style.inset = 10
        state.style.insetColor = RGBA(hex: "00FF00")
        state.style.background = .solid
        state.style.color1 = RGBA(hex: "0000FF")
        state.style.fixedWidth = 400
        state.style.fixedHeight = 300
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 15)], color: RGBA(hex: "FF0000"))]
        let layout = try CanvasRenderer.layout(sourceSize: CGSize(width: 80, height: 40), state: state)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 120, height: 90))
        XCTAssertEqual(layout.panelRect, CGRect(x: 10, y: 15, width: 100, height: 60))
        XCTAssertEqual(layout.imageRect, CGRect(x: 20, y: 25, width: 80, height: 40))
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(pixel(output, 10, 10), Pixel(0, 0, 255, 255))
        XCTAssertEqual(pixel(output, 50, 100), Pixel(0, 255, 0, 255))
        XCTAssertEqual(pixel(output, 110, 110), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(output, 180, 110), Pixel(255, 255, 255, 255))
    }

    func testFixedSizeOverridesRatioAndOutputScaleWithoutChangingPixels() throws {
        let source = makeImage(width: 80, height: 60) { x, y in (UInt8(x * 3), UInt8(y * 4), 60, 255) }
        var baseline = plainState()
        baseline.style.fixedWidth = 400
        baseline.style.fixedHeight = 300
        var overridden = baseline
        overridden.style.ratioWidth = 1
        overridden.style.ratioHeight = 9
        overridden.style.outputScale = 4
        let first = try CanvasRenderer.render(source: source, state: baseline)
        let second = try CanvasRenderer.render(source: source, state: overridden)
        XCTAssertEqual(first.width, 400)
        XCTAssertEqual(first.height, 300)
        XCTAssertEqual(PixelSample(source: first)?.bytes, PixelSample(source: second)?.bytes)
    }

    func testFixedSizeValidatesBothDimensionsAndResourceCaps() throws {
        let sourceSize = CGSize(width: 100, height: 80)
        for target in [(400, Optional<Int>.none), (0, Optional(300)), (-1, Optional(300)),
                       (16_385, Optional(100)), (10_000, Optional(5_000)), (Int.max, Optional(Int.max))] {
            var state = plainState()
            state.style.fixedWidth = target.0
            state.style.fixedHeight = target.1
            XCTAssertThrowsError(try CanvasRenderer.layout(sourceSize: sourceSize, state: state))
        }
    }

    func testFixedOutputCanContainALargeNaturalFrameWithoutAllocatingIt() throws {
        let source = makeImage(width: 100, height: 100) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 2048
        state.style.inset = 2048
        state.style.fixedWidth = 400
        state.style.fixedHeight = 300
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(output.width, 400)
        XCTAssertEqual(output.height, 300)
    }

    func testRatioKeepsFractionalCanvasToPreserveExactGeometry() throws {
        var state = plainState()
        state.style.ratioWidth = 16
        state.style.ratioHeight = 9
        let layout = try CanvasRenderer.layout(sourceSize: CGSize(width: 101, height: 101), state: state)
        XCTAssertEqual(layout.canvasSize.height, 101)
        XCTAssertLessThan(abs(layout.canvasSize.width / layout.canvasSize.height - 16.0 / 9), 1e-12)
        XCTAssertEqual(layout.imageRect.size, CGSize(width: 101, height: 101))
    }

    func testZeroPaddingClipsShadowAtCanvasWithoutAddingOrDarkeningPixels() throws {
        let source = makeImage(width: 50, height: 40) { _, _ in (255, 255, 255, 255) }
        let plain = try CanvasRenderer.render(source: source, state: plainState())
        var shadow = plainState()
        shadow.style.shadow = 32
        let output = try CanvasRenderer.render(source: source, state: shadow)
        XCTAssertEqual(output.width, 50)
        XCTAssertEqual(output.height, 40)
        XCTAssertEqual(PixelSample(source: output)?.bytes, PixelSample(source: plain)?.bytes)
    }

    func testFixedOutputScalesShadowWithTheWholeComposition() throws {
        let source = makeImage(width: 100, height: 60) { _, _ in (255, 255, 255, 255) }
        var base = plainState()
        base.style.padding = 40
        base.style.shadow = 20
        base.style.fixedWidth = 180
        base.style.fixedHeight = 140
        let first = try CanvasRenderer.render(source: source, state: base)
        let probes = [CGPoint(x: 90, y: 20), CGPoint(x: 90, y: 25), CGPoint(x: 90, y: 30), CGPoint(x: 90, y: 35),
                      CGPoint(x: 25, y: 70), CGPoint(x: 30, y: 70), CGPoint(x: 35, y: 70),
                      CGPoint(x: 145, y: 70), CGPoint(x: 150, y: 70), CGPoint(x: 155, y: 70),
                      CGPoint(x: 90, y: 105), CGPoint(x: 90, y: 110), CGPoint(x: 90, y: 115)]
        let baseline = probes.map { Int(pixel(first, Int($0.x), Int($0.y)).a) }
        XCTAssertGreaterThan(baseline.max() ?? 0, 8, "The regression must inspect visible shadow pixels.")
        for factor in [2, 4] {
            var scaled = base
            scaled.style.fixedWidth = 180 * factor
            scaled.style.fixedHeight = 140 * factor
            let output = try CanvasRenderer.render(source: source, state: scaled)
            let observed = probes.map { Int(pixel(output, Int($0.x) * factor, Int($0.y) * factor).a) }
            print("Shadow alpha probes at \(factor)x: baseline=\(baseline), observed=\(observed)")
            for index in probes.indices {
                XCTAssertLessThan(abs(baseline[index] - observed[index]), 6,
                                  "Shadow alpha at \(factor)x source \(probes[index]): \(baseline[index]) vs \(observed[index])")
            }
        }
    }

    func testWatermarkIsOffByDefaultAndWhitespaceDoesNotDraw() throws {
        let source = makeImage(width: 320, height: 180) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        XCTAssertEqual(state.style.watermarkText, "")
        XCTAssertNil(inkBounds(try CanvasRenderer.render(source: source, state: state)))
        state.style.watermarkText = "  \n  "
        XCTAssertNil(inkBounds(try CanvasRenderer.render(source: source, state: state)))
    }

    func testWatermarkAllCornersRespectTwelvePixelMargins() throws {
        let source = makeImage(width: 320, height: 180) { _, _ in (255, 255, 255, 255) }
        for position in WatermarkPosition.allCases {
            var state = plainState()
            state.style.watermarkText = "Mark"
            state.style.watermarkColor = RGBA(hex: "000000")
            state.style.watermarkPosition = position
            let output = try CanvasRenderer.render(source: source, state: state)
            let bounds = try XCTUnwrap(inkBounds(output))
            XCTAssertGreaterThan(bounds.minX, 11)
            XCTAssertGreaterThan(bounds.minY, 11)
            XCTAssertLessThanOrEqual(bounds.maxX, 308)
            XCTAssertLessThanOrEqual(bounds.maxY, 168)
            let left = position == .topLeft || position == .bottomLeft
            let top = position == .topLeft || position == .topRight
            XCTAssertEqual(bounds.midX < 160, left)
            XCTAssertEqual(bounds.midY < 90, top)
        }
    }

    func testLongWatermarkFitsAndRemainsVisibleOnFixedOutput() throws {
        let source = makeImage(width: 64, height: 48) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.fixedWidth = 400
        state.style.fixedHeight = 300
        state.style.watermarkText = String(repeating: "A very long watermark ", count: 200)
        state.style.watermarkFontSize = 80
        state.style.watermarkColor = RGBA(hex: "000000")
        let output = try CanvasRenderer.render(source: source, state: state)
        let bounds = try XCTUnwrap(inkBounds(output))
        XCTAssertGreaterThan(bounds.width, 30)
        XCTAssertGreaterThan(bounds.height, 2)
        XCTAssertGreaterThan(bounds.minX, 11)
        XCTAssertLessThanOrEqual(bounds.maxX, 388)
        XCTAssertLessThanOrEqual(bounds.maxY, 288)
    }

    func testWatermarkSizeInFixedOutputIsIndependentOfSourceResolution() throws {
        var bounds: [CGRect] = []
        for size in [CGSize(width: 64, height: 48), CGSize(width: 1280, height: 960)] {
            let source = makeImage(width: Int(size.width), height: Int(size.height)) { _, _ in (255, 255, 255, 255) }
            var state = plainState()
            state.style.fixedWidth = 400
            state.style.fixedHeight = 300
            state.style.watermarkText = "Export"
            state.style.watermarkFontSize = 24
            state.style.watermarkColor = RGBA(hex: "000000")
            let output = try CanvasRenderer.render(source: source, state: state)
            bounds.append(try XCTUnwrap(inkBounds(output)))
        }
        XCTAssertEqual(bounds[0], bounds[1])
    }

    func testWatermarkPreviewMatchesExportPlacementAtReducedScale() throws {
        let source = makeImage(width: 800, height: 600) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.watermarkText = "Preview"
        state.style.watermarkFontSize = 36
        state.style.watermarkColor = RGBA(hex: "000000")
        let fullOutput = try CanvasRenderer.render(source: source, state: state)
        let previewOutput = try CanvasRenderer.render(source: source, state: state, previewMaxDimension: 400)
        let full = try XCTUnwrap(inkBounds(fullOutput))
        let preview = try XCTUnwrap(inkBounds(previewOutput))
        XCTAssertLessThan(abs(preview.minX - full.minX / 2), 2)
        XCTAssertLessThan(abs(preview.minY - full.minY / 2), 2)
        XCTAssertLessThan(abs(preview.maxX - full.maxX / 2), 2)
        XCTAssertLessThan(abs(preview.maxY - full.maxY / 2), 2)
    }

    func testOldStyleJSONDecodesWithEveryAdditiveDefault() throws {
        let json = """
        {"padding":12,"cornerRadius":8,"shadow":4,"background":"solid",
         "color1":{"red":1,"green":0,"blue":0,"alpha":1},
         "color2":{"red":0,"green":0,"blue":1,"alpha":1},
         "gradientAngle":15,"ratioWidth":0,"ratioHeight":0,"outputScale":1,"borderWidth":0}
        """
        let style = try JSONDecoder().decode(CanvasStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.padding, 12)
        XCTAssertEqual(style.inset, 0)
        XCTAssertEqual(style.insetColor, RGBA(hex: "FFFFFF"))
        XCTAssertNil(style.fixedWidth)
        XCTAssertNil(style.fixedHeight)
        XCTAssertNil(style.backgroundAssetID)
        XCTAssertTrue(style.autoBalance)
        XCTAssertFalse(style.autoColor)
        XCTAssertEqual(style.watermarkText, "")
        XCTAssertEqual(style.watermarkFontSize, 20)
        XCTAssertEqual(style.watermarkColor.alpha, 0.7)
        XCTAssertEqual(style.watermarkPosition, .bottomRight)
        XCTAssertEqual(try JSONDecoder().decode(CanvasStyle.self, from: Data("{}".utf8)), CanvasStyle())
    }

    func testAllAdditiveFieldsRoundTripThroughPresetAndHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var style = CanvasStyle()
        style.inset = 18
        style.insetColor = RGBA(hex: "FFAA00")
        style.fixedWidth = 400
        style.fixedHeight = 300
        style.autoBalance = false
        style.autoColor = true
        style.watermarkText = "My mark"
        style.watermarkFontSize = 32
        style.watermarkColor = RGBA(hex: "124578")
        style.watermarkPosition = .topLeft
        let preset = StylePreset(name: "Custom", style: style)
        let presets = PresetStore(fileURL: directory.appendingPathComponent("presets.json"))
        try presets.save([preset])
        XCTAssertEqual(try presets.load(), [preset])
        let source = makeImage(width: 40, height: 30) { _, _ in (255, 255, 255, 255) }
        let history = HistoryStore(directory: directory.appendingPathComponent("history"))
        let state = EditState(style: style)
        let entry = try history.save(image: source, state: state)
        XCTAssertEqual(try history.load(entry).1, state)
    }

    func testAutomaticFlagsPersistWithoutAnalyzingOrMutatingInsideRenderer() throws {
        let source = makeImage(width: 100, height: 80) { x, y in
            x > 30 && x < 70 && y > 20 && y < 60 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        var automatic = plainState()
        automatic.style.autoBalance = true
        automatic.style.autoColor = true
        var manual = automatic
        manual.style.autoBalance = false
        manual.style.autoColor = false
        let first = try CanvasRenderer.render(source: source, state: automatic)
        let second = try CanvasRenderer.render(source: source, state: manual)
        XCTAssertEqual(first.width, 100)
        XCTAssertEqual(first.height, 80)
        XCTAssertEqual(PixelSample(source: first)?.bytes, PixelSample(source: second)?.bytes)
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(automatic)), automatic)
    }

    func testAutomaticColorsSampleEdgeBandRatherThanDominantCenter() {
        let source = makeImage(width: 100, height: 100) { x, y in
            x < 15 || x >= 85 || y < 15 || y >= 85 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        let colors = AutoBeautify.suggestColors(source: source)
        XCTAssertGreaterThan(colors.0.red, colors.0.blue)
    }

    func testUnknownWatermarkPositionFallsBackAndTinyCanvasReportsFitError() throws {
        let style = try JSONDecoder().decode(CanvasStyle.self, from: Data("{\"watermarkPosition\":\"future-corner\"}".utf8))
        XCTAssertEqual(style.watermarkPosition, .bottomRight)
        var state = plainState()
        state.style.watermarkText = "Too small"
        let source = makeImage(width: 20, height: 20) { _, _ in (255, 255, 255, 255) }
        XCTAssertThrowsError(try CanvasRenderer.render(source: source, state: state))
    }
}

private func inkBounds(_ image: CGImage) -> CGRect? {
    guard let sample = PixelSample(source: image) else { return nil }
    var minX = sample.width, minY = sample.height, maxX = -1, maxY = -1
    for y in 0..<sample.height {
        for x in 0..<sample.width {
            let p = sample.pixel(x: x, y: y)
            if p.3 > 200 && (p.0 < 230 || p.1 < 230 || p.2 < 230) {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
