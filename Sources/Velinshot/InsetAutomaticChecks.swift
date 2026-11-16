import AppKit
import VelinshotCore

enum InsetAutomaticChecks {
    static func run(directory:URL) throws -> Int {
        var count = 0
        func check(_ condition:@autoclosure ()->Bool,_ message:String) throws {
            guard condition() else { throw VelinshotError.invalidImage("Automatic inset check failed: \(message)") };count += 1
        }
        let domain = "com.jacknelson.velinshot.inset."+UUID().uuidString
        guard let defaults = UserDefaults(suiteName:domain),let bitmap = CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VelinshotError.renderingFailed }
        defer { defaults.removePersistentDomain(forName:domain) }
        bitmap.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:40,height:60))
        bitmap.setFillColor(CGColor(srgbRed:0,green:0,blue:1,alpha:1));bitmap.fill(CGRect(x:40,y:0,width:40,height:60))
        guard let source = bitmap.makeImage() else { throw VelinshotError.renderingFailed }
        let preferences = AppSettings(defaults:defaults)
        try check(preferences.autoInsetFill && preferences.style.autoInsetColor,"absent v1 preference enables Auto on new documents")
        preferences.style = CanvasStyle(padding:40,cornerRadius:0,shadow:0,autoBalance:false,autoInsetColor:true)
        let prepared = NewDocument.prepare(source:source,style:preferences.style)
        func blue(_ color:RGBA)->Bool { color.blue>0.99 && color.red<0.01 }
        func red(_ color:RGBA)->Bool { color.red>0.99 && color.blue<0.01 }
        try check(blue(prepared.state.style.insetColor),"new documents derive their inset from the dominant edge palette")
        let editor = EditorController(source:source,state:prepared.state,preparedAnalysis:prepared.analysis,preferences:preferences,supportDirectory:directory.appendingPathComponent("Automatic inset checks"))
        guard let window = editor.window,let root = window.contentView else { throw VelinshotError.renderingFailed }
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        func all(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(all) }
        guard let canvas = all(root).compactMap({$0 as? CanvasView}).first,
              let well = all(root).compactMap({$0 as? StudioColorWell}).first(where:{$0.accessibilityLabel()=="Inset fill color"}),
              let automatic = all(root).compactMap({$0 as? NSButton}).first(where:{$0.accessibilityLabel()=="Automatic inset fill"}) else { throw VelinshotError.invalidImage("Inset controls missing") }
        let green = RGBA(hex:"00FF00")
        well.color = NSColor(srgbRed:0,green:1,blue:0,alpha:1);_ = well.sendAction(well.action,to:well.target)
        try check(!canvas.state.style.autoInsetColor && canvas.state.style.insetColor==green,"manual well choice disables Auto and sets the chosen color")
        try check(!preferences.autoInsetFill,"manual mode persists for future captures")
        try check(NewDocument.state(source:source,style:preferences.style).style.insetColor==green,"manual mode survives new-document preparation")
        editor.undoEdit();try check(canvas.state.style.autoInsetColor && blue(canvas.state.style.insetColor),"manual color choice undoes as one edit")
        editor.redoEdit();try check(!canvas.state.style.autoInsetColor && canvas.state.style.insetColor==green,"manual color choice redoes")
        automatic.state = .on;_ = automatic.sendAction(automatic.action,to:automatic.target)
        func waitFor(_ condition:()->Bool)->Bool {
            let end = Date().addingTimeInterval(2)
            while !condition(),Date()<end { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
            return condition()
        }
        try check(waitFor{blue(canvas.state.style.insetColor)},"Auto restores cached palette without a manual color sticking")
        try check(canvas.state.style.autoInsetColor && preferences.autoInsetFill,"Auto mode persists")
        editor.undoEdit();try check(!canvas.state.style.autoInsetColor && canvas.state.style.insetColor==green,"derived color adds no separate undo step")
        editor.redoEdit();try check(canvas.state.style.autoInsetColor && blue(canvas.state.style.insetColor),"redo restores Auto and its derived color together")
        func mouse(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1) else { throw VelinshotError.renderingFailed };return event
        }
        let size = CGSize(width:160,height:140),available = canvas.bounds.insetBy(dx:32,dy:32)
        let scale = min(available.width/size.width,available.height/size.height)
        func view(_ point:CGPoint)->CGPoint { CGPoint(x:canvas.bounds.midX-size.width*scale/2+point.x*scale,y:canvas.bounds.midY-size.height*scale/2+point.y*scale) }
        canvas.tool = .crop
        let first = view(CGPoint(x:42,y:42)),last = view(CGPoint(x:70,y:98))
        canvas.mouseDown(with:try mouse(.leftMouseDown,first));canvas.mouseDragged(with:try mouse(.leftMouseDragged,last));canvas.mouseUp(with:try mouse(.leftMouseUp,last))
        try check(canvas.state.crop != nil,"manual crop commits before inset analysis")
        canvas.tool = .arrow
        let center = CGPoint(x:canvas.bounds.midX,y:canvas.bounds.midY),finish = CGPoint(x:center.x+12,y:center.y+12)
        canvas.mouseDown(with:try mouse(.leftMouseDown,center));canvas.mouseDragged(with:try mouse(.leftMouseDragged,finish))
        _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.03))
        try check(blue(canvas.state.style.insetColor),"automatic fill is deferred during pointer gestures")
        canvas.mouseUp(with:try mouse(.leftMouseUp,finish))
        try check(waitFor{red(canvas.state.style.insetColor)},"committed crop picks the visible region's palette")
        editor.undoEdit();try check(red(canvas.state.style.insetColor),"undoing a later mark retains the crop's automatic fill")
        editor.undoEdit();try check(canvas.state.crop==nil && blue(canvas.state.style.insetColor),"crop and automatic fill undo together")
        preferences.style = CanvasStyle(insetColor:green,autoInsetColor:false)
        canvas.tool = .crop
        canvas.mouseDown(with:try mouse(.leftMouseDown,first));canvas.mouseDragged(with:try mouse(.leftMouseDragged,last));canvas.mouseUp(with:try mouse(.leftMouseUp,last))
        try check(waitFor{red(canvas.state.style.insetColor)},"an automatic document can still update after another document chooses manual defaults")
        try check(!preferences.autoInsetFill && preferences.style.insetColor==green,"late automatic results preserve a newer manual default")
        return count
    }
}
