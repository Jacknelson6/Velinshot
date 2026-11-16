import AppKit
import VelinshotCore

enum PlatformChecks {
    static func run(directory:URL) throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool,_ message:String) throws {
            guard condition() else { throw VelinshotError.invalidImage("Platform check failed: \(message)") }
            count += 1
        }
        let domain = "com.jacknelson.velinshot.validation."+UUID().uuidString
        guard let defaults = UserDefaults(suiteName:domain) else { throw VelinshotError.invalidImage("Cannot create isolated validation preferences.") }
        defer { defaults.removePersistentDomain(forName:domain) }
        let preferences = AppSettings(defaults:defaults)
        preferences.directory = directory
        try check(preferences.directory.standardizedFileURL == directory.standardizedFileURL,"save folder survives typed UserDefaults URL round trip")
        preferences.jpegByDefault = false
        try check(!AppSettings(defaults:defaults).jpegByDefault,"export format persists")
        preferences.captureShortcut = .fallback
        try check(AppSettings(defaults:defaults).captureShortcut == .fallback,"recorded shortcut persists")
        try check(GlobalShortcuts.protectsXnapper(.capture,runningBundleIDs:["com.devuap.beautyshotapp"]),"Xnapper capture shortcut is protected")
        try check(GlobalShortcuts.protectsXnapper(.quickCopy,runningBundleIDs:["com.devuap.beautyshotapp"]),"Xnapper quick-copy shortcut is protected")
        try check(!GlobalShortcuts.protectsXnapper(.fallback,runningBundleIDs:["com.devuap.beautyshotapp"]),"alternate shortcut remains available")
        try check(!GlobalShortcuts.protectsXnapper(.capture,runningBundleIDs:[]),"Command-4 is eligible after Xnapper quits")
        let firstHistory = directory.appendingPathComponent("History A",isDirectory:true),secondHistory = directory.appendingPathComponent("History B",isDirectory:true)
        preferences.historyDirectory = firstHistory;preferences.historyDirectory = secondHistory
        try check(AppSettings(defaults:defaults).historyDirectory.standardizedFileURL == secondHistory.standardizedFileURL,"history folder switch persists")
        preferences.historyDirectory = firstHistory
        try check(AppSettings(defaults:defaults).historyDirectory.standardizedFileURL == firstHistory.standardizedFileURL,"history folder switch back restores the original location")

        let source = try DemoFixture.make()
        let baseline = EditState(style:CanvasStyle(padding:40,cornerRadius:12,shadow:10))
        let canvas = CanvasView(source:source,state:baseline)
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = canvas
        canvas.frame = CGRect(x:0,y:0,width:800,height:600)
        defer { window.close() }
        let start = CGPoint(x:canvas.bounds.midX-70,y:canvas.bounds.midY-35)
        let end = CGPoint(x:canvas.bounds.midX+60,y:canvas.bounds.midY+35)
        func event(_ type:NSEvent.EventType,_ point:CGPoint,clicks:Int = 1) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1) else { throw VelinshotError.invalidImage("Cannot create local view test event.") }
            return event
        }
        for tool in [EditorTool.pen,.arrow,.rectangle,.ellipse,.highlighter,.blur,.redact,.number,.line] {
            canvas.state = baseline;canvas.tool = tool
            canvas.mouseDown(with:try event(.leftMouseDown,start))
            canvas.mouseDragged(with:try event(.leftMouseDragged,end))
            canvas.mouseUp(with:try event(.leftMouseUp,end))
            try check(canvas.state.annotations.count == 1,"\(tool.rawValue) gesture creates exactly one annotation")
            try check(canvas.state.annotations[0].kind.rawValue == tool.rawValue,"\(tool.rawValue) gesture routes to correct renderer kind")
            let image = try CanvasRenderer.render(source:source,state:canvas.state,previewMaxDimension:600)
            try check(image.width > 0 && image.height > 0,"\(tool.rawValue) gesture produces a renderable image")
        }
        canvas.state = baseline;canvas.tool = .text
        canvas.mouseDown(with:try event(.leftMouseDown,start))
        guard let field = canvas.subviews.compactMap({$0 as? NSTextField}).first else { throw VelinshotError.invalidImage("Text tool did not create an editable field.") }
        field.stringValue = "C and S stay text"
        canvas.finishText()
        try check(canvas.state.annotations.last?.text == "C and S stay text","text entry preserves shortcut letters")
        canvas.state = baseline;canvas.tool = .crop
        canvas.mouseDown(with:try event(.leftMouseDown,start));canvas.mouseDragged(with:try event(.leftMouseDragged,end));canvas.mouseUp(with:try event(.leftMouseUp,end))
        try check(canvas.state.crop != nil,"crop gesture commits a source-space crop")
        try check((canvas.state.crop?.width ?? 0)>1 && (canvas.state.crop?.height ?? 0)>1,"crop gesture has positive source-pixel dimensions")
        try check(!canvas.state.style.autoBalance,"manual crop turns automatic balance off")
        let arrow = Annotation(kind:.arrow,points:[CGPoint(x:0,y:0),CGPoint(x:100,y:100)])
        let resized = AnnotationGeometry.resize(arrow,from:CGRect(x:0,y:0,width:100,height:100),to:CGRect(x:20,y:30,width:200,height:150))
        try check(resized.points == [CGPoint(x:20,y:30),CGPoint(x:220,y:180)],"resize maps both arrow endpoints to the new box")
        try check(resized.id == arrow.id,"resize preserves annotation identity for undo")
        let png = try ImageExporter.data(image:source,format:.png)
        let promise = ScreenshotPromise(data:png)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try check(promise.writableTypes(for:board).contains(.png),"drag promise offers image PNG data")
        try check((promise.pasteboardPropertyList(forType:.png) as? Data) == png,"drag promise image data is unchanged")
        let fileName = promise.writer.filePromiseProvider(promise,fileNameForType:"public.png")
        try check(fileName.hasSuffix(".png") && !fileName.contains("/"),"promised filename is a safe unique PNG")
        let promisedURL = directory.appendingPathComponent(fileName)
        var writeError:Error?
        promise.writer.filePromiseProvider(promise,writePromiseTo:promisedURL){writeError = $0}
        try check(writeError == nil,"promised PNG writes successfully")
        let promisedImage = try ImageLoader.load(url:promisedURL)
        try check(promisedImage.width == source.width && promisedImage.height == source.height,"promised file is a valid image")
        promise.writer.filePromiseProvider(promise,writePromiseTo:promisedURL){writeError = $0}
        try check(writeError != nil,"promised-file writer refuses to overwrite an existing file")
        print("\(count) platform integration checks passed in isolated settings and hidden native views.")
        return count
    }
}
