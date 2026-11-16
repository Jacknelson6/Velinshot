import AppKit
import XCTest
@testable import VelinshotCore

final class InsetPaletteTests: XCTestCase {
    func testUniformWhiteDarkAndColoredSourcesKeepTheirPalette() {
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (16, 24, 32), (24, 160, 168)]
        for color in colors {
            let source = makeImage(width: 24, height: 16) { _, _ in (color.0, color.1, color.2, 255) }
            assertInsetColor(AutoBeautify.suggestInsetColor(source: source),
                             Double(color.0) / 255, Double(color.1) / 255, Double(color.2) / 255)
        }
    }

    func testDominantEdgeBeatsUnrelatedCenterAndMinorityEdgeAccent() {
        let source = makeImage(width: 32, height: 32) { x, y in
            let edge = x < 4 || x >= 28 || y < 4 || y >= 28
            if edge { return x < 2 && y < 2 ? (255, 40, 0, 255) : (24, 160, 168, 255) }
            return (255, 0, 255, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 24.0 / 255, 160.0 / 255, 168.0 / 255)
    }

    func testAlpha25IsIgnoredAndAlpha26IsIncludedExactly() {
        let ignored = makeImage(width: 8, height: 8) { _, _ in (25, 0, 0, 25) }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: ignored), 1, 1, 1)
        let boundary = makeImage(width: 16, height: 16) { x, y in
            if x == 0 && y == 0 { return (0, 26, 0, 26) }
            return x < 2 || x >= 14 || y < 2 || y >= 14 ? (25, 0, 0, 25) : (0, 0, 255, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: boundary), 0, 1, 0)
        let included = makeImage(width: 8, height: 8) { _, _ in (0, 26, 0, 26) }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: included), 0, 1, 0)
    }

    func testTransparentEdgesUseVisibleInteriorPalette() {
        let source = makeImage(width: 16, height: 16) { x, y in
            x >= 4 && x < 12 && y >= 4 && y < 12 ? (160, 32, 200, 255) : (0, 0, 0, 0)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 160.0 / 255, 32.0 / 255, 200.0 / 255)
    }

    func testEntirelyTransparentSourceFallsBackToOpaqueWhite() {
        let source = makeImage(width: 20, height: 12) { _, _ in (0, 0, 0, 0) }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 1, 1, 1)
    }

    func testCropSelectsTheVisibleTopLeftSourceRegion() {
        let source = makeImage(width: 24, height: 32) { _, y in
            y < 16 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 0, 0, 1)
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source,
            crop: CGRect(x: 0, y: 0, width: 24, height: 8)), 1, 0, 0)
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source,
            crop: CGRect(x: 0, y: 24, width: 24, height: 8)), 0, 0, 1)
    }

    func testFractionalCropRoundsOutwardAndClipsToSource() {
        let source = makeImage(width: 12, height: 12) { x, y in
            if x == 0 && y == 0 { return (0, 0, 255, 255) }
            return x == 2 && y == 3 ? (255, 0, 0, 255) : (0, 255, 0, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source,
            crop: CGRect(x: 2.2, y: 3.2, width: 0.2, height: 0.2)), 1, 0, 0)
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source,
            crop: CGRect(x: -2, y: -3, width: 3, height: 4)), 0, 0, 1)
    }

    func testCropSmallerThanEightPixelsStillUsesOnePixelEdgeBand() {
        let source = makeImage(width: 20, height: 20) { x, y in
            guard x >= 4 && x < 11 && y >= 5 && y < 10 else { return (0, 0, 255, 255) }
            return x == 4 || x == 10 || y == 5 || y == 9 ? (0, 26, 0, 26) : (255, 0, 0, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source,
            crop: CGRect(x: 4, y: 5, width: 7, height: 5)), 0, 1, 0)
    }

    func testInvalidEmptyAndOutsideCropsReturnWhite() {
        let source = makeImage(width: 12, height: 12) { _, _ in (255, 0, 0, 255) }
        let crops: [CGRect] = [.zero, .null, .infinite,
            CGRect(x: 20, y: 0, width: 2, height: 2),
            CGRect(x: Double.nan, y: 0, width: 2, height: 2),
            CGRect(x: 0, y: 0, width: Double.infinity, height: 2),
            CGRect(x: 0, y: 0, width: -2, height: 2)]
        for crop in crops {
            assertInsetColor(AutoBeautify.suggestInsetColor(source: source, crop: crop), 1, 1, 1)
        }
    }

    func testExactTiesUseLowerPackedKeyIndependentOfScanOrder() {
        for mirror in [false, true] {
            let source = makeImage(width: 8, height: 8) { x, _ in
                (x < 4) != mirror ? (255, 0, 0, 255) : (0, 0, 255, 255)
            }
            let expected = AutoBeautify.suggestInsetColor(source: source)
            assertInsetColor(expected, 0, 0, 1)
            for _ in 0..<12 { XCTAssertEqual(AutoBeautify.suggestInsetColor(source: source), expected) }
        }
    }

    func testSummedAlphaWinsInsteadOfPixelFrequency() {
        let source = makeImage(width: 8, height: 1) { x, _ in
            x == 0 ? (0, 0, 255, 255) : (26, 0, 0, 26)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 0, 0, 1)
    }

    func testEqualSummedAlphaUsesLowerBinEvenWithUnequalCounts() {
        let source = makeImage(width: 3, height: 1) { x, _ in
            x == 0 ? (52, 0, 0, 52) : (0, 0, 26, 26)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 0, 0, 1)
    }

    func testWinningBinMeanUsesUnpremultipliedColorsWeightedByAlpha() {
        let source = makeImage(width: 2, height: 1) { x, _ in
            x == 0 ? (32, 16, 8, 64) : (65, 33, 17, 128)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 97.0 / 192, 49.0 / 192, 25.0 / 192)
    }

    func testUnpremultipliedChannelsRoundToEightBitsBeforeQuantization() {
        let source = makeImage(width: 3, height: 1) { x, _ in
            if x == 0 { return (16, 0, 0, 32) } // 127.5 rounds into the 128...135 bin.
            return x == 1 ? (128, 0, 0, 255) : (127, 0, 0, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 144.0 / 287, 0, 0)
    }

    func testOuterEighthBandUsesIntegerDivision() {
        let source = makeImage(width: 15, height: 15) { x, y in
            x == 0 || x == 14 || y == 0 || y == 14 ? (26, 0, 0, 26) : (0, 0, 255, 255)
        }
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 1, 0, 0)
    }

    func testDisplayP3SourceConvertsThroughSRGBAndReturnsFiniteOpaqueColor() throws {
        let bytes = Array(repeating: [UInt8](arrayLiteral: 255, 100, 20, 255), count: 6).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let sample = try XCTUnwrap(PixelSample(source: source, maximumDimension: 64))
        let converted = sample.pixel(x: 0, y: 0)
        XCTAssertTrue(converted.1 != 100 || converted.2 != 20, "Fixture must exercise profile conversion")
        let result = AutoBeautify.suggestInsetColor(source: source)
        assertInsetColor(result, Double(converted.0) / 255, Double(converted.1) / 255, Double(converted.2) / 255)
        XCTAssertTrue([result.red, result.green, result.blue, result.alpha].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        })
    }

    func testLargeUniformSourceKeepsColorWithBoundedRoundedSampling() throws {
        let source = makeImage(width: 257, height: 71) { _, _ in (31, 93, 177, 255) }
        let sample = try XCTUnwrap(PixelSample(source: source, maximumDimension: 64))
        XCTAssertEqual(sample.width, 64)
        XCTAssertEqual(sample.height, 18)
        assertInsetColor(AutoBeautify.suggestInsetColor(source: source), 31.0 / 255, 93.0 / 255, 177.0 / 255)
    }
}

private func assertInsetColor(_ color: RGBA, _ red: Double, _ green: Double, _ blue: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(abs(color.red - red), 1e-12, file: file, line: line)
    XCTAssertLessThan(abs(color.green - green), 1e-12, file: file, line: line)
    XCTAssertLessThan(abs(color.blue - blue), 1e-12, file: file, line: line)
    XCTAssertEqual(color.alpha, 1, file: file, line: line)
}
