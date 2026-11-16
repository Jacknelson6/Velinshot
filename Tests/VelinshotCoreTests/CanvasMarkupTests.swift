import AppKit
import XCTest
@testable import VelinshotCore

final class CanvasMarkupTests: XCTestCase {
    func testVirtualSourceTransformIncludesCropInsetAndFixedCanvas() throws {
        let style = CanvasStyle(padding:10,inset:5,fixedWidth:300,fixedHeight:200)
        let state = EditState(style:style,crop:CGRect(x:20,y:10,width:60,height:40))
        let layout = try CanvasRenderer.layout(sourceSize:CGSize(width:100,height:80),state:state)
        XCTAssertEqual(layout.canvasSize,CGSize(width:105,height:70))
        XCTAssertEqual(layout.sourceOriginInCanvas,CGPoint(x:2.5,y:5))
        XCTAssertEqual(layout.canvasBoundsInSource,CGRect(x:-2.5,y:-5,width:105,height:70))
        XCTAssertEqual(layout.compositionPoint(forSource:CGPoint(x:20,y:10)),CGPoint(x:22.5,y:15))
        XCTAssertEqual(layout.sourcePoint(forComposition:.zero),CGPoint(x:-2.5,y:-5))
        let point = CGPoint(x:35.3,y:29.1)
        let recovered = layout.sourcePoint(forComposition:layout.compositionPoint(forSource:point))
        XCTAssertLessThan(abs(recovered.x-point.x),0.000001)
        XCTAssertLessThan(abs(recovered.y-point.y),0.000001)
    }

    func testArrowWhollyOnMatExportsOutsidePhoto() throws {
        let source = makeImage(width:100,height:60) { _,_ in (255,255,255,255) }
        var state = matState()
        state.annotations = [Annotation(kind:.arrow,points:[CGPoint(x:-24,y:10),CGPoint(x:-6,y:40)],color:RGBA(hex:"FF0000"),lineWidth:4)]
        let image = try CanvasRenderer.render(source:source,state:state)
        XCTAssertGreaterThan(pixel(image,15,55).r,240)
        XCTAssertLessThan(pixel(image,15,55).b,15)
        XCTAssertEqual(pixel(image,80,60),Pixel(255,255,255,255))
    }

    func testArrowCrossesPhotoEdgeWithoutBeingCutOff() throws {
        let source = makeImage(width:100,height:60) { _,_ in (255,255,255,255) }
        var state = matState();state.style.borderWidth = 2
        state.annotations = [Annotation(kind:.arrow,points:[CGPoint(x:50,y:30),CGPoint(x:-20,y:30)],color:RGBA(hex:"FF0000"),lineWidth:4)]
        let image = try CanvasRenderer.render(source:source,state:state)
        for x in [20,29,30,31,50,70] {
            XCTAssertGreaterThan(pixel(image,x,60).r,240)
            XCTAssertLessThan(pixel(image,x,60).b,15)
        }
    }

    func testOutsideMarkupAgreesInFullAndCachedProxyExports() throws {
        let source = makeImage(width:100,height:80) { _,_ in (255,255,255,255) }
        var style = CanvasStyle(padding:20,cornerRadius:0,shadow:0,background:.solid,color1:RGBA(hex:"0000FF"),inset:10,insetColor:RGBA(hex:"00FF00"),fixedWidth:300,fixedHeight:240)
        style.autoBalance = false
        let state = EditState(style:style,annotations:[Annotation(kind:.arrow,points:[CGPoint(x:-6,y:30),CGPoint(x:16,y:30)],color:RGBA(hex:"FF0000"),lineWidth:6)],crop:CGRect(x:20,y:10,width:60,height:40))
        let full = try CanvasRenderer.render(source:source,state:state)
        let direct = try CanvasRenderer.render(source:source,state:state,previewMaxDimension:150)
        let proxy = try ImageLoader.preview(image:source,maxDimension:32)
        let cached = try CanvasRenderer.renderPreview(source:proxy,state:state,maximumDimension:150)
        XCTAssertEqual(full.width,300);XCTAssertEqual(full.height,240)
        XCTAssertGreaterThan(pixel(full,30,120).r,240)
        XCTAssertLessThan(pixel(full,30,120).b,15)
        XCTAssertGreaterThan(pixel(cached,15,60).r,240)
        XCTAssertLessThan(pixel(cached,15,60).b,15)
        XCTAssertEqual(pixel(cached,15,60),pixel(direct,15,60))
    }

    func testBlurStaysOnImageAndDoesNotEraseMatMarkup() throws {
        let source = makeImage(width:100,height:60) { _,_ in (255,255,255,255) }
        var state = matState()
        state.annotations = [
            Annotation(kind:.redact,points:[CGPoint(x:-15,y:0),CGPoint(x:-1,y:30)],color:RGBA(hex:"FF0000")),
            Annotation(kind:.blur,points:[CGPoint(x:-20,y:-10),CGPoint(x:20,y:30)],lineWidth:8)
        ]
        let image = try CanvasRenderer.render(source:source,state:state)
        XCTAssertEqual(pixel(image,20,45),Pixel(255,0,0,255))
        XCTAssertEqual(pixel(image,40,45),Pixel(255,255,255,255))
    }

    func testMatAnnotationsPreserveListOrder() throws {
        let source = makeImage(width:100,height:60) { _,_ in (255,255,255,255) }
        var state = matState()
        let points = [CGPoint(x:-20,y:0),CGPoint(x:-4,y:30)]
        state.annotations = [Annotation(kind:.redact,points:points,color:RGBA(hex:"FF0000")),Annotation(kind:.redact,points:points,color:RGBA(hex:"00FF00"))]
        XCTAssertEqual(pixel(try CanvasRenderer.render(source:source,state:state),18,45),Pixel(0,255,0,255))
        state.annotations.reverse()
        XCTAssertEqual(pixel(try CanvasRenderer.render(source:source,state:state),18,45),Pixel(255,0,0,255))
    }

    func testShrinkingCanvasHidesButRetainsOutsideMarks() throws {
        let source = makeImage(width:100,height:60) { _,_ in (255,255,255,255) }
        var state = matState()
        let mark = Annotation(kind:.arrow,points:[CGPoint(x:-24,y:10),CGPoint(x:-6,y:40)],color:RGBA(hex:"FF0000"),lineWidth:4)
        state.annotations = [mark];state.style.padding = 0
        let small = try CanvasRenderer.render(source:source,state:state)
        XCTAssertEqual(small.width,100);XCTAssertEqual(small.height,60)
        XCTAssertEqual(pixel(small,0,30),Pixel(255,255,255,255))
        XCTAssertEqual(state.annotations,[mark])
        state.style.padding = 30
        XCTAssertGreaterThan(pixel(try CanvasRenderer.render(source:source,state:state),15,55).r,240)
    }

    func testLegacyStyleKeepsManualInsetAndExplicitModeRoundTrips() throws {
        let data = Data("{\"insetColor\":{\"red\":1,\"green\":0.5,\"blue\":0.25,\"alpha\":1}}".utf8)
        var style = try JSONDecoder().decode(CanvasStyle.self,from:data)
        XCTAssertFalse(style.autoInsetColor)
        XCTAssertEqual(style.insetColor,RGBA(red:1,green:0.5,blue:0.25))
        style.autoInsetColor = true
        let restored = try JSONDecoder().decode(CanvasStyle.self,from:JSONEncoder().encode(style))
        XCTAssertTrue(restored.autoInsetColor)
        XCTAssertEqual(restored.insetColor,style.insetColor)
    }

    private func matState() -> EditState {
        EditState(style:CanvasStyle(padding:30,cornerRadius:0,shadow:0,background:.solid,color1:RGBA(hex:"0000FF"),autoBalance:false))
    }
}
