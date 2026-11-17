import AppKit
import SwiftUI
import XCTest
@testable import VelinshotCore

final class ContinuousCornerTests:XCTestCase {
    func testRendererMatchesNativeContinuousMaskAndRejectsCircularControl() throws {
        let source = makeImage(width:160,height:120) { _,_ in (255,255,255,255) }
        var state = plainState();state.style.padding = 16;state.style.cornerRadius = 40
        let layout = try CanvasRenderer.layout(sourceSize:CGSize(width:160,height:120),state:state)
        let native = SwiftUI.Path(roundedRect:layout.imageRect,cornerRadius:40,style:.continuous).cgPath
        let circular = CGPath(roundedRect:layout.imageRect,cornerWidth:40,cornerHeight:40,transform:nil)
        let size = CGSize(width:layout.exportSize.width,height:layout.exportSize.height)
        let expected = try CornerTestImages.mask(native,size:size)
        let control = try CornerTestImages.mask(circular,size:size)
        let shapeDifference = try CornerTestImages.alphaDifference(expected,control)
        XCTAssertGreaterThan(shapeDifference,0,"The fixture must distinguish Apple's continuous geometry from the old circular control.")
        let actual = try CanvasRenderer.render(source:source,state:state)
        XCTAssertEqual(try CornerTestImages.alphaDifference(actual,expected),0,"The screenshot clip must use Apple's continuous curve, not the circular control.")
    }

    func testContinuousPathWorksOnABackgroundThread() throws {
        let completion = DispatchSemaphore(value:0)
        let result = CornerWorkerResult()
        Thread.detachNewThread {
            defer { completion.signal() }
            result.store(Result {
                let rect = CGRect(x:0,y:0,width:160,height:120)
                let path = ContinuousCorners.path(in:rect,radius:40)
                let circular = CGPath(roundedRect:rect,cornerWidth:40,cornerHeight:40,transform:nil)
                let nativeMask = try CornerTestImages.mask(path,size:rect.size)
                let controlMask = try CornerTestImages.mask(circular,size:rect.size)
                return (Thread.isMainThread,try CornerTestImages.alphaDifference(nativeMask,controlMask),path.boundingBoxOfPath)
            })
        }
        XCTAssertEqual(completion.wait(timeout:.now()+10),.success,"Native path creation must complete without a main-thread hop.")
        let observed = try XCTUnwrap(result.read()).get()
        XCTAssertFalse(observed.0,"The actual geometry was constructed off the main thread.")
        XCTAssertGreaterThan(observed.1,0,"The worker must return a real continuous path, not a circular fallback.")
        XCTAssertEqual(observed.2,CGRect(x:0,y:0,width:160,height:120))
    }

    func testZeroRadiusPreservesLegacyGeometryAndSourcePixels() throws {
        let rect = CGRect(x:3.25,y:5.5,width:80,height:60)
        let path = ContinuousCorners.path(in:rect,radius:0)
        let legacy = CGPath(roundedRect:rect,cornerWidth:0,cornerHeight:0,transform:nil)
        XCTAssertEqual(try CornerTestImages.alphaDifference(CornerTestImages.mask(path,size:CGSize(width:100,height:80)),CornerTestImages.mask(legacy,size:CGSize(width:100,height:80))),0)
        let source = makeImage(width:80,height:60) { x,y in (UInt8(x*3),UInt8(y*4),80,(x>30 && x<40 && y>20 && y<30) ? 0 : 255) }
        let output = try CanvasRenderer.render(source:source,state:plainState())
        XCTAssertEqual(try XCTUnwrap(PixelSample(source:output)).bytes,try XCTUnwrap(PixelSample(source:source)).bytes)
        var cropped = plainState();cropped.crop = CGRect(x:10,y:8,width:50,height:40)
        let cropOutput = try CanvasRenderer.render(source:source,state:cropped)
        let cropSource = try XCTUnwrap(source.cropping(to:CGRect(x:10,y:8,width:50,height:40)))
        XCTAssertEqual(try XCTUnwrap(PixelSample(source:cropOutput)).bytes,try XCTUnwrap(PixelSample(source:cropSource)).bytes)
    }

    func testCornerBoundsAndClampingAcrossAspectRatios() throws {
        for rect in [CGRect(x:3.25,y:5.5,width:80,height:60),CGRect(x:7,y:4,width:140,height:40),CGRect(x:4,y:7,width:40,height:140)] {
            for radius:CGFloat in [0,12,40,400] {
                let bounded = min(radius,min(rect.width,rect.height)/2)
                let path = ContinuousCorners.path(in:rect,radius:radius)
                let native = SwiftUI.Path(roundedRect:rect,cornerRadius:bounded,style:.continuous).cgPath
                XCTAssertEqual(path.boundingBoxOfPath,rect)
                let size = CGSize(width:ceil(rect.maxX+4),height:ceil(rect.maxY+4))
                XCTAssertEqual(try CornerTestImages.alphaDifference(CornerTestImages.mask(path,size:size),CornerTestImages.mask(native,size:size)),0)
            }
        }
    }

    func testInsetBorderAndShadowKeepNativeSilhouetteAndTransparentInterior() throws {
        let source = makeImage(width:100,height:80) { x,y in (0,0,255,(x>42 && x<58 && y>32 && y<48) ? 0 : 255) }
        var state = plainState();state.style.padding = 24;state.style.inset = 12;state.style.cornerRadius = 32;state.style.insetColor = RGBA(hex:"00FF00")
        let layout = try CanvasRenderer.layout(sourceSize:CGSize(width:100,height:80),state:state)
        let outer = SwiftUI.Path(roundedRect:layout.panelRect,cornerRadius:32,style:.continuous).cgPath
        let inner = SwiftUI.Path(roundedRect:layout.imageRect,cornerRadius:20,style:.continuous).cgPath
        let baseline = try CanvasRenderer.render(source:source,state:state)
        let sample = try XCTUnwrap(PixelSample(source:baseline))
        var ringPixels = 0,sourcePixels = 0
        for y in stride(from:2,to:baseline.height-2,by:4) {
            for x in stride(from:2,to:baseline.width-2,by:4) {
                let point = CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
                if CornerTestImages.safelyInside(outer,point),CornerTestImages.safelyOutside(inner,point) {
                    XCTAssertEqual(sample.pixel(x:x,y:y).1,255,"The even-odd inset ring must retain its own color.");ringPixels += 1
                } else if CornerTestImages.safelyInside(inner,point),abs(point.x-layout.imageRect.midX)>12 || abs(point.y-layout.imageRect.midY)>12 {
                    XCTAssertEqual(sample.pixel(x:x,y:y).2,255);sourcePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(ringPixels,10);XCTAssertGreaterThan(sourcePixels,10)
        XCTAssertEqual(sample.pixel(x:Int(layout.imageRect.midX),y:Int(layout.imageRect.midY)).3,0,"The inset ring must not fill a transparent source hole.")

        state.style.borderWidth = 4
        let bordered = try CanvasRenderer.render(source:source,state:state)
        let stroke = try CornerTestImages.stroke(outer,size:layout.exportSize,width:4)
        let baseAlpha = try CornerTestImages.alpha(baseline),borderAlpha = try CornerTestImages.alpha(bordered),strokeAlpha = try CornerTestImages.alpha(stroke)
        let outside = baseAlpha.indices.filter{baseAlpha[$0] == 0}
        XCTAssertTrue(outside.allSatisfy{borderAlpha[$0] == strokeAlpha[$0]},"The border must stroke the native panel curve without filling its interior.")
        XCTAssertGreaterThan(outside.filter{strokeAlpha[$0]>0}.count,0,"The border oracle must inspect visible stroke pixels.")

        state.style.borderWidth = 0;state.style.shadow = 12
        let shadowed = try CanvasRenderer.render(source:source,state:state)
        let shadow = try CornerTestImages.shadow(outer,canvas:layout.canvasSize,size:layout.exportSize,strength:12)
        let shadowedAlpha = try CornerTestImages.alpha(shadowed),shadowAlpha = try CornerTestImages.alpha(shadow)
        XCTAssertTrue(outside.allSatisfy{shadowedAlpha[$0] == shadowAlpha[$0]},"The even-odd shadow silhouette must use the native panel curve.")
        XCTAssertGreaterThan(outside.filter{shadowAlpha[$0]>0}.count,0,"The shadow oracle must inspect visible shadow pixels.")
        XCTAssertEqual(pixel(shadowed,Int(layout.imageRect.midX),Int(layout.imageRect.midY)).a,0)
    }

    func testBlurClipFollowsContinuousImageCornersAtANonzeroCropOrigin() throws {
        let source = makeImage(width:120,height:100) { x,_ in x%4<2 ? (255,255,255,255) : (0,0,0,255) }
        var state = plainState();state.style.padding = 24;state.style.inset = 12;state.style.cornerRadius = 36;state.style.insetColor = RGBA(hex:"00FF00")
        state.crop = CGRect(x:20,y:10,width:80,height:60)
        let layout = try CanvasRenderer.layout(sourceSize:CGSize(width:120,height:100),state:state)
        let native = SwiftUI.Path(roundedRect:layout.imageRect,cornerRadius:24,style:.continuous).cgPath
        let mask = try CornerTestImages.alpha(CornerTestImages.mask(native,size:layout.exportSize))
        let baseline = try CanvasRenderer.render(source:source,state:state)
        state.annotations = [Annotation(kind:.blur,points:[CGPoint(x:0,y:-10),CGPoint(x:120,y:90)],lineWidth:8)]
        let blurred = try CanvasRenderer.render(source:source,state:state)
        let before = try XCTUnwrap(PixelSample(source:baseline)).bytes,after = try XCTUnwrap(PixelSample(source:blurred)).bytes
        var outsideChanges = 0,insideChanges = 0
        for index in mask.indices {
            let offset = index*4
            let changed = (0..<4).contains{before[offset+$0] != after[offset+$0]}
            if mask[index] == 0,changed { outsideChanges += 1 }
            if mask[index] == 255,changed { insideChanges += 1 }
        }
        XCTAssertEqual(outsideChanges,0,"Blur must not paint the mat or transparent native corners.")
        XCTAssertGreaterThan(insideChanges,20,"The blur regression must inspect an actual changed image region.")
    }

    func testProxyAndDirectPreviewShareNativeMasksAt1xAnd2x() throws {
        let source = makeImage(width:160,height:120) { _,_ in (255,255,255,255) }
        let proxy = try ImageLoader.preview(image:source,maxDimension:40)
        for outputScale in [1.0,2.0] {
            var state = plainState();state.style.padding = 16;state.style.cornerRadius = 32;state.style.outputScale = outputScale
            let layout = try CanvasRenderer.layout(sourceSize:CGSize(width:160,height:120),state:state)
            let native = SwiftUI.Path(roundedRect:layout.imageRect,cornerRadius:32,style:.continuous).cgPath
            let full = try CanvasRenderer.render(source:source,state:state)
            XCTAssertEqual(full.width,Int(layout.exportSize.width));XCTAssertEqual(full.height,Int(layout.exportSize.height))
            let fullMask = try CornerTestImages.mask(native,size:layout.exportSize,scale:CGFloat(outputScale))
            XCTAssertEqual(try CornerTestImages.alphaDifference(full,fullMask),0)
            let direct = try CanvasRenderer.render(source:source,state:state,previewMaxDimension:96)
            let cached = try CanvasRenderer.renderPreview(source:proxy,state:state,maximumDimension:96)
            XCTAssertEqual(try CornerTestImages.alphaDifference(direct,cached),0,"Cached proxy and direct preview must use the same geometry.")
            let previewSize = CGSize(width:direct.width,height:direct.height)
            let previewMask = try CornerTestImages.mask(native,size:previewSize,scale:0.5)
            XCTAssertEqual(try CornerTestImages.alphaDifference(direct,previewMask),0,"Preview and export must rasterize the same native curve at their respective scales.")
        }
    }
}

private final class CornerWorkerResult:@unchecked Sendable {
    private let lock = NSLock()
    private var value:Result<(Bool,Int,CGRect),Error>?
    func store(_ result:Result<(Bool,Int,CGRect),Error>) { lock.lock();defer { lock.unlock() };value = result }
    func read() -> Result<(Bool,Int,CGRect),Error>? { lock.lock();defer { lock.unlock() };return value }
}

private enum CornerTestImages {
    static func context(size:CGSize,scale:CGFloat = 1) throws -> CGContext {
        guard let context = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,
                                      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VelinshotError.renderingFailed }
        context.translateBy(x:0,y:size.height);context.scaleBy(x:scale,y:-scale)
        return context
    }
    static func mask(_ path:CGPath,size:CGSize,scale:CGFloat = 1) throws -> CGImage {
        let context = try context(size:size,scale:scale)
        context.addPath(path);context.clip();context.setFillColor(CGColor(gray:1,alpha:1))
        context.fill(CGRect(x:0,y:0,width:size.width/scale,height:size.height/scale))
        guard let image = context.makeImage() else { throw VelinshotError.renderingFailed };return image
    }
    static func alpha(_ image:CGImage) throws -> [UInt8] {
        guard let sample = PixelSample(source:image) else { throw VelinshotError.renderingFailed }
        let bytes = sample.bytes
        return stride(from:3,to:bytes.count,by:4).map{bytes[$0]}
    }
    static func alphaDifference(_ first:CGImage,_ second:CGImage) throws -> Int {
        guard first.width == second.width,first.height == second.height else { throw VelinshotError.invalidImage("Corner oracle dimensions disagree.") }
        return zip(try alpha(first),try alpha(second)).reduce(0){$0+($1.0 == $1.1 ? 0 : 1)}
    }
    static func safelyInside(_ path:CGPath,_ point:CGPoint) -> Bool {
        [-1.5,0,1.5].allSatisfy{dx in [-1.5,0,1.5].allSatisfy{dy in path.contains(CGPoint(x:point.x+dx,y:point.y+dy))}}
    }
    static func safelyOutside(_ path:CGPath,_ point:CGPoint) -> Bool {
        [-1.5,0,1.5].allSatisfy{dx in [-1.5,0,1.5].allSatisfy{dy in !path.contains(CGPoint(x:point.x+dx,y:point.y+dy))}}
    }
    static func stroke(_ path:CGPath,size:CGSize,width:CGFloat) throws -> CGImage {
        let context = try context(size:size);context.setLineWidth(width);context.setStrokeColor(CGColor(gray:1,alpha:0.65))
        context.addPath(path);context.strokePath()
        guard let image = context.makeImage() else { throw VelinshotError.renderingFailed };return image
    }
    static func shadow(_ path:CGPath,canvas:CGSize,size:CGSize,strength:CGFloat) throws -> CGImage {
        let context = try context(size:size)
        context.addRect(CGRect(origin:.zero,size:canvas));context.addPath(path);context.clip(using:.evenOdd)
        context.setShadow(offset:CGSize(width:0,height:strength*0.28),blur:strength,color:CGColor(gray:0,alpha:0.25))
        context.setFillColor(CGColor(gray:0,alpha:1));context.addPath(path);context.fillPath()
        guard let image = context.makeImage() else { throw VelinshotError.renderingFailed };return image
    }
}
