import AppKit
import XCTest
@testable import VelinshotCore

final class RendererTests: XCTestCase {
    func testNaturalLayoutAndRetinaExportLeavePointGeometryStable() throws {
        let state = EditState(style: CanvasStyle(padding: 10, outputScale: 2))
        let result = try CanvasRenderer.layout(sourceSize: CGSize(width: 100, height: 60), state: state)
        XCTAssertEqual(result.canvasSize, CGSize(width: 120, height: 80))
        XCTAssertEqual(result.imageRect, CGRect(x: 10, y: 10, width: 100, height: 60))
        XCTAssertEqual(result.exportSize, CGSize(width: 240, height: 160))
    }

    func testRatioExpandsCanvasWithoutStretchingScreenshot() throws {
        let state = EditState(style: CanvasStyle(padding: 10, ratioWidth: 1, ratioHeight: 1))
        let result = try CanvasRenderer.layout(sourceSize: CGSize(width: 100, height: 60), state: state)
        XCTAssertEqual(result.canvasSize, CGSize(width: 120, height: 120))
        XCTAssertEqual(result.imageRect, CGRect(x: 10, y: 30, width: 100, height: 60))
    }

    func testRenderPreservesAsymmetricSourceOrientation() throws {
        let source = makeImage(width: 80, height: 60) { x, y in
            if y < 20 { return x < 40 ? (255, 0, 0, 255) : (0, 255, 0, 255) }
            return x < 40 ? (0, 0, 255, 255) : (255, 255, 0, 255)
        }
        let output = try CanvasRenderer.render(source: source, state: plainState())
        XCTAssertEqual(pixel(output, 5, 5), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(output, 75, 5), Pixel(0, 255, 0, 255))
        XCTAssertEqual(pixel(output, 5, 55), Pixel(0, 0, 255, 255))
        XCTAssertEqual(pixel(output, 75, 55), Pixel(255, 255, 0, 255))
    }

    func testCropUsesTopLeftOriginalCoordinates() throws {
        let source = makeImage(width: 100, height: 80) { x, y in (UInt8(x * 2), UInt8(y * 3), 0, 255) }
        var state = plainState()
        state.crop = CGRect(x: 30, y: 10, width: 40, height: 20)
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(output.width, 40)
        XCTAssertEqual(output.height, 20)
        XCTAssertEqual(pixel(output, 0, 0), Pixel(60, 30, 0, 255))
        XCTAssertEqual(pixel(output, 39, 19), Pixel(138, 87, 0, 255))
    }

    func testAnnotationMappingSurvivesCropInsetAndScale() throws {
        let source = makeImage(width: 100, height: 80) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 5
        state.style.outputScale = 2
        state.crop = CGRect(x: 30, y: 10, width: 40, height: 20)
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 35, y: 15), CGPoint(x: 45, y: 20)], color: RGBA(hex: "FF0000"))]
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(output.width, 100)
        XCTAssertEqual(output.height, 60)
        XCTAssertEqual(pixel(output, 23, 23), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(output, 43, 23), Pixel(255, 255, 255, 255))
    }

    func testPreviewKeepsCompositionAndAnnotationsWhileLimitingRaster() throws {
        let source = makeImage(width: 800, height: 400) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 100
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100)], color: RGBA(hex: "FF0000"))]
        let preview = try CanvasRenderer.render(source: source, state: state, previewMaxDimension: 200)
        XCTAssertEqual(preview.width, 200)
        XCTAssertEqual(preview.height, 120)
        XCTAssertEqual(pixel(preview, 25, 25), Pixel(255, 0, 0, 255))
        XCTAssertEqual(pixel(preview, 100, 60), Pixel(255, 255, 255, 255))
    }

    func testTransparentBackgroundAndRoundedCornersRetainAlpha() throws {
        let source = makeImage(width: 100, height: 80) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 10
        state.style.cornerRadius = 20
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(pixel(output, 0, 0).a, 0)
        XCTAssertLessThan(pixel(output, 10, 10).a, 10)
        XCTAssertEqual(pixel(output, 60, 50).a, 255)
    }

    func testShadowDoesNotFillTransparentScreenshotInterior() throws {
        let source = makeImage(width: 100, height: 80) { x, y in
            x > 40 && x < 60 && y > 30 && y < 50 ? (0, 0, 0, 0) : (255, 255, 255, 255)
        }
        var state = plainState()
        state.style.padding = 20
        state.style.shadow = 12
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(pixel(output, 70, 60).a, 0)
        XCTAssertGreaterThan(pixel(output, 70, 104).a, 0)
    }

    func testRedactionIsOpaqueEvenWhenUserColorIsTransparent() throws {
        let source = makeImage(width: 40, height: 40) { _, _ in (255, 0, 255, 255) }
        var state = plainState()
        state.annotations = [Annotation(kind: .redact, points: [CGPoint(x: 5, y: 5), CGPoint(x: 30, y: 30)],
                                        color: RGBA(red: 0, green: 0, blue: 0, alpha: 0))]
        let output = try CanvasRenderer.render(source: source, state: state)
        XCTAssertEqual(pixel(output, 10, 10), Pixel(0, 0, 0, 255))
    }

    func testEveryVectorToolChangesPixels() throws {
        let source = makeImage(width: 160, height: 120) { _, _ in (255, 255, 255, 255) }
        for kind in [AnnotationKind.pen, .line, .arrow, .rectangle, .ellipse, .text, .highlighter, .number] {
            var state = plainState()
            state.annotations = [Annotation(kind: kind, points: [CGPoint(x: 30, y: 35), CGPoint(x: 110, y: 85)],
                                            color: RGBA(hex: "FF0000"), lineWidth: 8, text: "TEST", fontSize: 24)]
            let output = try CanvasRenderer.render(source: source, state: state)
            let sample = try XCTUnwrap(PixelSample(source: output))
            var changed = 0
            for y in 0..<sample.height {
                for x in 0..<sample.width {
                    let p = sample.pixel(x: x, y: y)
                    if p.0 < 250 || p.1 < 250 || p.2 < 250 { changed += 1 }
                }
            }
            XCTAssertGreaterThan(changed, 20, "\(kind) must draw real pixels")
        }
    }

    func testBlurObscuresPatternAndKeepsOutsideUntouched() throws {
        let source = makeImage(width: 100, height: 80) { x, _ in
            x % 4 < 2 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        var state = plainState()
        state.annotations = [Annotation(kind: .blur, points: [CGPoint(x: 20, y: 10), CGPoint(x: 80, y: 70)], lineWidth: 8)]
        let output = try CanvasRenderer.render(source: source, state: state)
        let inside = pixel(output, 50, 40)
        XCTAssertGreaterThan(inside.r, 40)
        XCTAssertLessThan(inside.r, 215)
        XCTAssertEqual(inside.a, 255)
        XCTAssertEqual(pixel(output, 5, 5), pixel(source, 5, 5))
    }

    func testInvalidCropsAndNonFiniteStylesFailWithoutAllocating() throws {
        var state = plainState()
        for crop in [CGRect(x: 200, y: 0, width: 10, height: 10), CGRect.zero,
                     CGRect(x: Double.nan, y: 0, width: 10, height: 10)] {
            state.crop = crop
            XCTAssertThrowsError(try CanvasRenderer.layout(sourceSize: CGSize(width: 100, height: 80), state: state))
        }
        state.crop = nil
        state.style.padding = .infinity
        XCTAssertThrowsError(try CanvasRenderer.layout(sourceSize: CGSize(width: 100, height: 80), state: state))
        state.style.padding = 10
        state.style.ratioWidth = 1
        state.style.ratioHeight = 0
        XCTAssertThrowsError(try CanvasRenderer.layout(sourceSize: CGSize(width: 100, height: 80), state: state))
    }

    func testOutputPixelBudgetRejectsLargeScale() throws {
        let state = EditState(style: CanvasStyle(padding: 0, outputScale: 4))
        XCTAssertThrowsError(try CanvasRenderer.layout(sourceSize: CGSize(width: 3000, height: 2000), state: state)) {
            XCTAssertEqual($0 as? VelinshotError, .imageTooLarge)
        }
    }

    func testSolidGradientAndImageBackgroundsAreRealPixels() throws {
        let source = makeImage(width: 40, height: 20) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.style.padding = 20
        state.style.background = .solid
        state.style.color1 = RGBA(hex: "FF0000")
        XCTAssertEqual(pixel(try CanvasRenderer.render(source: source, state: state), 5, 5), Pixel(255, 0, 0, 255))
        state.style.background = .gradient
        state.style.color2 = RGBA(hex: "0000FF")
        state.style.gradientAngle = 0
        let gradient = try CanvasRenderer.render(source: source, state: state)
        XCTAssertGreaterThan(pixel(gradient, 5, 5).r, pixel(gradient, 75, 5).r)
        state.style.background = .image
        let background = makeImage(width: 10, height: 10) { _, _ in (0, 255, 0, 255) }
        XCTAssertEqual(pixel(try CanvasRenderer.render(source: source, state: state, backgroundImage: background), 5, 5), Pixel(0, 255, 0, 255))
    }

    func testLargeRetinaScreenshotPreviewStaysWithinRequestedRasterSize() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4096, height: 2160, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2160))
        let source = try XCTUnwrap(context.makeImage())
        var state = EditState()
        state.annotations = [Annotation(kind: .blur, points: [CGPoint(x: 200, y: 200), CGPoint(x: 3500, y: 1800)])]
        let preview = try CanvasRenderer.render(source: source, state: state, previewMaxDimension: 1200)
        XCTAssertEqual(preview.width, 1200)
        XCTAssertLessThanOrEqual(preview.height, 1200)
        XCTAssertGreaterThan(pixel(preview, 600, preview.height / 2).r, 245)
    }

    func testInvalidAnnotationCoordinatesAreRejected() throws {
        let source = makeImage(width: 40, height: 30) { _, _ in (255, 255, 255, 255) }
        var state = plainState()
        state.annotations = [Annotation(kind: .line, points: [CGPoint(x: Double.nan, y: 10), .zero])]
        XCTAssertThrowsError(try CanvasRenderer.render(source: source, state: state))
        state.annotations = [Annotation(kind: .line, points: [CGPoint(x: 1e100, y: 10), .zero])]
        XCTAssertThrowsError(try CanvasRenderer.render(source: source, state: state))
    }

    func testPartialOffImageCropIsClippedToSource() throws {
        var state = plainState()
        state.crop = CGRect(x: -10, y: -5, width: 30, height: 20)
        let layout = try CanvasRenderer.layout(sourceSize: CGSize(width: 100, height: 80), state: state)
        XCTAssertEqual(layout.cropRect, CGRect(x: 0, y: 0, width: 20, height: 15))
        XCTAssertEqual(layout.exportSize, CGSize(width: 20, height: 15))
    }
}

func plainState() -> EditState {
    EditState(style: CanvasStyle(padding: 0, cornerRadius: 0, shadow: 0, background: .transparent))
}

struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) { self.r = r; self.g = g; self.b = b; self.a = a }
}

func makeImage(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color = fill(x, y)
            let offset = (y * width + x) * 4
            bytes[offset] = color.0; bytes[offset + 1] = color.1
            bytes[offset + 2] = color.2; bytes[offset + 3] = color.3
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> Pixel {
    let sample = PixelSample(source: image)!
    let p = sample.pixel(x: x, y: y)
    return Pixel(p.0, p.1, p.2, p.3)
}
