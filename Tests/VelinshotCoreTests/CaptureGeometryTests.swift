import XCTest
import CoreGraphics
@testable import VelinshotCore

final class CaptureGeometryTests: XCTestCase {
    private let primary = CaptureGeometry.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    private let left = CaptureGeometry.Display(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1)

    func testSelectionAcrossLeftSeamKeepsGlobalCoordinatesInEitherDirection() {
        let start = CGPoint(x: -120, y: 100), end = CGPoint(x: 240, y: 500)
        let expected = CGRect(x: -120, y: 100, width: 360, height: 400)
        XCTAssertEqual(CaptureGeometry.selection(from: start, to: end), expected)
        XCTAssertEqual(CaptureGeometry.selection(from: end, to: start), expected)
    }
    func testMixedScaleLeftSeamUsesOneOutputScaleAndCorrectCaptureOrigins() throws {
        let plan = try CaptureGeometry.plan(rect: CGRect(x: -120, y: 100, width: 360, height: 400), displays: [primary, left])
        XCTAssertEqual(plan.scale, 2)
        XCTAssertEqual(plan.width, 720)
        XCTAssertEqual(plan.height, 800)
        let leftPart = try XCTUnwrap(plan.parts.first { $0.displayID == 2 })
        let rightPart = try XCTUnwrap(plan.parts.first { $0.displayID == 1 })
        XCTAssertEqual(leftPart.sourceRect, CGRect(x: 1800, y: 580, width: 120, height: 400))
        XCTAssertEqual(rightPart.sourceRect, CGRect(x: 0, y: 400, width: 240, height: 400))
        XCTAssertEqual(leftPart.destinationRect, CGRect(x: 0, y: 0, width: 240, height: 800))
        XCTAssertEqual(rightPart.destinationRect, CGRect(x: 240, y: 0, width: 480, height: 800))
    }
    func testAboveDisplayAndPrimaryShareVerticalOutputSeam() throws {
        let above = CaptureGeometry.Display(id: 3, frame: CGRect(x: 0, y: 900, width: 1440, height: 900), scale: 1)
        let plan = try CaptureGeometry.plan(rect: CGRect(x: 100, y: 800, width: 300, height: 250), displays: [primary, above])
        let lower = try XCTUnwrap(plan.parts.first { $0.displayID == 1 })
        let upper = try XCTUnwrap(plan.parts.first { $0.displayID == 3 })
        XCTAssertEqual(lower.destinationRect, CGRect(x: 0, y: 0, width: 600, height: 200))
        XCTAssertEqual(upper.destinationRect, CGRect(x: 0, y: 200, width: 600, height: 300))
        XCTAssertEqual(upper.sourceRect, CGRect(x: 100, y: 750, width: 300, height: 150))
    }
    func testSingleNonRetinaDisplayDoesNotInheritAnotherScreensScale() throws {
        let plan = try CaptureGeometry.plan(rect: left.frame, displays: [primary, left])
        XCTAssertEqual(plan.width, 1920)
        XCTAssertEqual(plan.height, 1080)
        XCTAssertEqual(plan.scale, 1)
        XCTAssertEqual(plan.parts.count, 1)
    }
    func testFractionalSeamHasExactlyAdjacentPixelEdges() throws {
        let first = CaptureGeometry.Display(id: 1, frame: CGRect(x: -500.25, y: 0, width: 500.25, height: 800), scale: 1)
        let second = CaptureGeometry.Display(id: 2, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        let plan = try CaptureGeometry.plan(rect: CGRect(x: -10.25, y: 10, width: 30.5, height: 40), displays: [first, second])
        XCTAssertEqual(plan.parts[0].destinationRect.maxX, plan.parts[1].destinationRect.minX)
        XCTAssertEqual(plan.parts[1].destinationRect.maxX, CGFloat(plan.width))
    }
    func testWindowCoordinateTransformUsesPrimaryAnchorForNegativeAndAboveDisplays() {
        let quartz = CGRect(x: -500, y: -300, width: 350, height: 250)
        XCTAssertEqual(CaptureGeometry.cocoaRect(quartz, primaryMaxY: 900), CGRect(x: -500, y: 950, width: 350, height: 250))
        XCTAssertEqual(CaptureGeometry.quartzPoint(CGPoint(x: -400, y: 1000), primaryMaxY: 900), CGPoint(x: -400, y: -100))
    }
    func testNoDisplayAndInvalidRegionsFailInsteadOfProducingBlankImages() {
        XCTAssertThrowsError(try CaptureGeometry.plan(rect: CGRect(x: 2000, y: 0, width: 100, height: 100), displays: [primary]))
        XCTAssertThrowsError(try CaptureGeometry.plan(rect: .zero, displays: [primary]))
        XCTAssertThrowsError(try CaptureGeometry.plan(rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100), displays: [primary]))
    }
    func testPixelLimitIsCheckedBeforeIntegerConversionOrAllocation() {
        XCTAssertThrowsError(try CaptureGeometry.plan(rect: CGRect(x: 0, y: 0, width: 20000, height: 20000), displays: [primary]))
        let hugeScale = CaptureGeometry.Display(id: 1, frame: primary.frame, scale: CGFloat.greatestFiniteMagnitude)
        XCTAssertThrowsError(try CaptureGeometry.plan(rect: primary.frame, displays: [hugeScale]))
    }
}
