import AppKit
import VelinshotCore

enum DemoFixture {
    static func make() throws -> CGImage {
        let width = 1280,height = 800
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VelinshotError.renderingFailed }
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        defer { NSGraphicsContext.current = previous }
        func fill(_ rect:CGRect,_ hex:String,radius:CGFloat = 0) {
            context.setFillColor(RGBA(hex:hex).cgColor)
            context.addPath(CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil));context.fillPath()
        }
        func text(_ value:String,_ point:CGPoint,_ size:CGFloat,_ color:String = "232436",_ weight:NSFont.Weight = .regular) {
            (value as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:RGBA(hex:color).nsColor])
        }
        fill(CGRect(x:0,y:0,width:1280,height:800),"FBFAFD")
        fill(CGRect(x:0,y:0,width:1280,height:64),"F0EEF5")
        for (index,color) in ["F47073","F7C45C","70CA8E"].enumerated() { fill(CGRect(x:24+index*24,y:25,width:12,height:12),color,radius:6) }
        text("Studio / Launch notes",CGPoint(x:138,y:21),18,"666174",.medium)
        fill(CGRect(x:0,y:64,width:226,height:736),"F5F3F8")
        text("STUDIO",CGPoint(x:28,y:103),14,"7160E8",.bold)
        text("Workspace",CGPoint(x:28,y:146),26,"232436",.semibold)
        fill(CGRect(x:16,y:210,width:194,height:44),"E8E3FA",radius:10)
        text("Overview",CGPoint(x:34,y:221),16,"6352CD",.semibold)
        for (index,label) in ["Notes","Files","Archive"].enumerated() { text(label,CGPoint(x:34,y:283+index*54),16,"80798C") }
        text("A little more clarity.",CGPoint(x:280,y:120),48,"262336",.bold)
        text("Good things happen when the details have room to breathe.",CGPoint(x:283,y:191),19,"787184")
        fill(CGRect(x:282,y:259,width:938,height:175),"EAE5FC",radius:18)
        text("Make room for what matters.",CGPoint(x:315,y:290),30,"5B49B5",.semibold)
        text("A note, a mark, a little context. Then share it.",CGPoint(x:315,y:343),19,"71658C")
        fill(CGRect(x:315,y:385,width:145,height:20),"D5CDF3",radius:6)
        text("Ready to share",CGPoint(x:485,y:382),15,"71658C",.medium)
        text("The small details",CGPoint(x:282,y:478),24,"262336",.semibold)
        let tasks = [("Capture the idea","Start with one clear moment."),("Add what matters","An arrow can say a lot."),("Share the moment","Good work travels light.")]
        for (index,task) in tasks.enumerated() {
            let y = CGFloat(533+index*76)
            fill(CGRect(x:282,y:y,width:36,height:36),"EFECF8",radius:10)
            text(String(index+1),CGPoint(x:294,y:y+7),17,"7160E8",.semibold)
            text(task.0,CGPoint(x:337,y:y-1),18,"3B364C",.semibold)
            text(task.1,CGPoint(x:337,y:y+27),15,"8B8397")
        }
        guard let image = context.makeImage() else { throw VelinshotError.renderingFailed }
        return image
    }
    static func style() -> EditState {
        EditState(style:CanvasStyle(padding:72,cornerRadius:24,shadow:30),annotations:[
            Annotation(kind:.arrow,points:[CGPoint(x:1050,y:610),CGPoint(x:825,y:491)],color:RGBA(hex:"EC687C"),lineWidth:7),
            Annotation(kind:.rectangle,points:[CGPoint(x:327,y:603),CGPoint(x:715,y:662)],color:RGBA(hex:"7160E8"),lineWidth:4)
        ])
    }
    static func smokeCheck(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let platformChecks = try PlatformChecks.run(directory:directory)
        let source = try make();let state = style();let started = Date()
        let output = try CanvasRenderer.render(source:source,state:state)
        let renderSeconds = Date().timeIntervalSince(started)
        try ImageExporter.data(image:source,format:.png).write(to:directory.appendingPathComponent("synthetic-source.png"),options:.atomic)
        try ImageExporter.data(image:output,format:.png).write(to:directory.appendingPathComponent("framed-demo.png"),options:.atomic)
        let jpeg = try ImageExporter.data(image:output,format:.jpeg,quality:0.85)
        try jpeg.write(to:directory.appendingPathComponent("framed-demo.jpg"),options:.atomic)
        let decoded = try ImageLoader.load(data:jpeg)
        guard decoded.width == output.width,decoded.height == output.height else { throw VelinshotError.encodingFailed }
        let text = try TextRecognizer.recognize(image:source).map(\.text).joined(separator:"\n")
        guard text.localizedCaseInsensitiveContains("clarity") else { throw VelinshotError.invalidImage("Synthetic OCR check did not find the expected text.") }
        try text.write(to:directory.appendingPathComponent("recognized-text.txt"),atomically:true,encoding:.utf8)
        let result:[String:Any] = ["sourceWidth":source.width,"sourceHeight":source.height,"outputWidth":output.width,"outputHeight":output.height,"renderMilliseconds":renderSeconds*1000,"jpegBytes":jpeg.count,"ocrFoundClarity":true,"synthetic":true,"platformChecks":platformChecks]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("smoke-result.json"),options:.atomic)
        print("Integrated smoke check passed: \(output.width)×\(output.height), render \(Int(renderSeconds*1000)) ms, OCR verified.")
    }
}
