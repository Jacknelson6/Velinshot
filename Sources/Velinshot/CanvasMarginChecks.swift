import AppKit
import VelinshotCore

enum CanvasMarginChecks {
    static func run(directory:URL) throws -> Int {
        var count = 0
        func check(_ condition:@autoclosure ()->Bool,_ message:String) throws {
            guard condition() else { throw VelinshotError.invalidImage("Canvas margin check failed: \(message)") };count += 1
        }
        let domain = "com.jacknelson.velinshot.margins."+UUID().uuidString
        guard let defaults = UserDefaults(suiteName:domain) else { throw VelinshotError.invalidImage("Cannot create isolated preferences") }
        defer { defaults.removePersistentDomain(forName:domain) }
        let preferences = AppSettings(defaults:defaults)
        let source = try DemoFixture.make()
        let style = CanvasStyle(padding:120,cornerRadius:0,shadow:0,inset:30,autoBalance:false)
        let initial = EditState(style:style)
        let editor = EditorController(source:source,state:initial,preferences:preferences,supportDirectory:directory.appendingPathComponent("Margin checks"))
        guard let window = editor.window,let root = window.contentView else { throw VelinshotError.invalidImage("Editor did not create a window") }
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        func all(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(all) }
        guard let canvas = all(root).compactMap({$0 as? CanvasView}).first else { throw VelinshotError.invalidImage("Missing canvas") }
        let composition = CGSize(width:source.width+300,height:source.height+300)
        func view(_ point:CGPoint)->CGPoint {
            let available = canvas.bounds.insetBy(dx:32,dy:32)
            let scale = min(available.width/composition.width,available.height/composition.height)
            return CGPoint(x:canvas.bounds.midX-composition.width*scale/2+point.x*scale,y:canvas.bounds.midY-composition.height*scale/2+point.y*scale)
        }
        func mouse(_ type:NSEvent.EventType,_ point:CGPoint,clicks:Int = 1) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1) else { throw VelinshotError.invalidImage("Missing mouse event") };return event
        }
        let start = view(CGPoint(x:35,y:50)),end = view(CGPoint(x:90,y:180))
        canvas.tool = .arrow;canvas.lineWidth = 4
        canvas.mouseDown(with:try mouse(.leftMouseDown,start));canvas.mouseDragged(with:try mouse(.leftMouseDragged,end));canvas.mouseUp(with:try mouse(.leftMouseUp,end))
        try check(canvas.state.annotations.count==1,"arrow starts wholly in the mat")
        let original = canvas.state.annotations[0]
        try check(abs(original.points[0].x + 115)<0.001 && abs(original.points[0].y + 100)<0.001,"mat points retain extended source coordinates")
        try check(original.points.allSatisfy{$0.x<0},"both endpoints remain outside the image")
        try check(preferences.autoInsetFill,"editing legacy manual state does not disable the new-document Auto default")
        editor.undoEdit();try check(canvas.state.annotations.isEmpty,"one undo removes outside-only arrow")
        editor.redoEdit();try check(canvas.state.annotations==[original],"redo restores outside-only arrow")
        canvas.tool = .select
        var selected:Annotation?
        let originalSelection = canvas.onSelection
        canvas.onSelection = { value in selected = value;originalSelection?(value) }
        let middle = view(CGPoint(x:60,y:110)),moved = view(CGPoint(x:75,y:125))
        canvas.mouseDown(with:try mouse(.leftMouseDown,middle));canvas.mouseDragged(with:try mouse(.leftMouseDragged,moved));canvas.mouseUp(with:try mouse(.leftMouseUp,moved))
        try check(selected?.id==original.id,"selection finds a mark on the mat")
        try check(abs(canvas.state.annotations[0].points[0].x-original.points[0].x-15)<0.001,"mat mark moves without image-edge clamping")
        editor.undoEdit();try check(canvas.state.annotations==[original],"moving a mat arrow undoes in one step")
        canvas.tool = .select
        canvas.mouseDown(with:try mouse(.leftMouseDown,middle));canvas.mouseUp(with:try mouse(.leftMouseUp,middle))
        let lower = view(CGPoint(x:original.points.last!.x+152,y:original.points.last!.y+152))
        let handle = CGPoint(x:lower.x+5,y:lower.y+5),resized = view(CGPoint(x:120,y:220))
        canvas.mouseDown(with:try mouse(.leftMouseDown,handle));canvas.mouseDragged(with:try mouse(.leftMouseDragged,resized));canvas.mouseUp(with:try mouse(.leftMouseUp,resized))
        try check(canvas.state.annotations[0].id==original.id,"mat resize preserves mark identity")
        try check(canvas.state.annotations[0].points != original.points,"resize handle works outside the image")
        editor.undoEdit();try check(canvas.state.annotations==[original],"mat resize undoes")
        canvas.tool = .select
        canvas.mouseDown(with:try mouse(.leftMouseDown,middle));canvas.mouseDragged(with:try mouse(.leftMouseDragged,moved))
        guard let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{1B}",charactersIgnoringModifiers:"\u{1B}",isARepeat:false,keyCode:53) else { throw VelinshotError.invalidImage("Missing Escape event") }
        canvas.keyDown(with:escape)
        try check(canvas.state.annotations==[original] && !canvas.hasActiveGesture,"Escape cancels a Select drag before leaving canvas focus")
        try check(selected==nil,"Escape clears the selection")
        var hidden = canvas.state;hidden.style.padding = 0;hidden.style.inset = 0;canvas.state = hidden;canvas.tool = .select
        guard let tab = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48) else { throw VelinshotError.invalidImage("Missing tab event") }
        canvas.keyDown(with:tab);try check(selected?.id==original.id,"Tab can select a hidden off-canvas mark")
        canvas.deleteSelection();try check(canvas.state.annotations.isEmpty,"hidden marks can be deleted")
        editor.undoEdit();try check(canvas.state.annotations==[original],"hidden mark deletion undoes")
        editor.redoEdit();try check(canvas.state.annotations.isEmpty,"hidden mark deletion redoes")
        let second = Annotation(kind:.rectangle,points:[CGPoint(x:-60,y:-60),CGPoint(x:-40,y:-40)])
        var cycling = hidden;cycling.annotations = [original,second];canvas.state = cycling;canvas.tool = .select
        canvas.keyDown(with:tab);try check(selected?.id==original.id,"Tab starts with the first hidden mark")
        canvas.keyDown(with:tab);try check(selected?.id==second.id,"Tab progresses to the next hidden mark")
        canvas.keyDown(with:tab);try check(selected==nil,"Tab past the last mark clears selection")
        guard let previous = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.shift],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48) else { throw VelinshotError.invalidImage("Missing Shift-Tab event") }
        canvas.keyDown(with:previous);try check(selected?.id==second.id,"Shift-Tab from no selection starts at the last mark")
        canvas.keyDown(with:previous);try check(selected?.id==original.id,"Shift-Tab progresses backwards")
        canvas.keyDown(with:previous);try check(selected==nil,"Shift-Tab past the first mark clears selection")
        canvas.state = initial
        var copies = 0;canvas.onBackgroundDoubleClick = { copies += 1 }
        let empty = view(CGPoint(x:25,y:source.height+240))
        canvas.tool = .select;canvas.mouseDown(with:try mouse(.leftMouseDown,empty,clicks:2));canvas.mouseUp(with:try mouse(.leftMouseUp,empty,clicks:2))
        try check(copies==1,"Select double-click copies on empty mat")
        canvas.tool = .arrow;canvas.mouseDown(with:try mouse(.leftMouseDown,empty,clicks:2));canvas.mouseUp(with:try mouse(.leftMouseUp,empty,clicks:2))
        try check(copies==1,"Arrow double-click does not copy or close")
        canvas.tool = .text;canvas.mouseDown(with:try mouse(.leftMouseDown,empty,clicks:2))
        guard let field = canvas.subviews.compactMap({$0 as? NSTextField}).first else { throw VelinshotError.invalidImage("Text cannot begin on mat") }
        field.stringValue = "Margin text";canvas.finishText()
        try check(canvas.state.annotations.last?.kind == .text && copies==1,"text is created on the mat")
        canvas.tool = .select;canvas.mouseDown(with:try mouse(.leftMouseDown,empty,clicks:2))
        try check(canvas.subviews.contains{$0 is NSTextField},"double-click edits mat text before considering background copy")
        canvas.finishText(cancel:true);try check(copies==1,"mat text editing never copies the image")
        for (label,height) in [("Copy screenshot",StudioMetrics.controlHeight),("Save screenshot",StudioMetrics.controlHeight),("Drag finished screenshot",StudioMetrics.controlHeight),("Arrow (A)",StudioMetrics.toolTarget)] {
            guard let button = all(root).compactMap({$0 as? StudioButton}).first(where:{$0.accessibilityLabel()==label}) else { throw VelinshotError.invalidImage("Missing \(label)") }
            try check(abs(button.frame.height-height)<0.01,"\(label) uses its declared visible control height")
        }
        try check(editor.makeMoreMenu().items.contains{$0.title == "Share Screenshot…" && $0.action == NSSelectorFromString("requestShare") && $0.target === editor},"Share retains its native action through the visible More menu")
        return count
    }
}
