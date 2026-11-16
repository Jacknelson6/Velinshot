import AppKit
import VelinshotCore

/// Exports the real native view hierarchy using only our synthetic fixture.
/// No screen capture, user preference edits or user screenshots are involved.
enum StudioSnapshots {
    static func run(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let domain = "com.jacknelson.velinshot.studio-preview."+UUID().uuidString
        guard let defaults = UserDefaults(suiteName:domain) else { throw VelinshotError.renderingFailed }
        defer { defaults.removePersistentDomain(forName:domain) }
        let preferences = AppSettings(defaults:defaults)
        let source = try DemoFixture.make()
        var final = DemoFixture.style()
        final.style.autoInsetColor = true
        final.style.insetColor = AutoBeautify.suggestInsetColor(source:source,crop:final.crop)
        let proxy = try ImageLoader.preview(image:source)
        let framed = EditState(style:final.style)
        let sourceData = try ImageExporter.data(image:source,format:.png)
        try sourceData.write(to:directory.appendingPathComponent("source.png"),options:.atomic)
        try ImageExporter.data(image:CanvasRenderer.render(source:source,state:framed),format:.png).write(to:directory.appendingPathComponent("framed.png"),options:.atomic)
        try ImageExporter.data(image:CanvasRenderer.render(source:source,state:final),format:.png).write(to:directory.appendingPathComponent("finished.png"),options:.atomic)
        var records:[[String:Any]] = []
        for dark in [false,true] {
            for minimum in [false,true] {
                let size = minimum ? NSSize(width:820,height:560) : NSSize(width:950,height:650)
                let name = "editor-\(dark ? "dark" : "light")\(minimum ? "-minimum" : "")"
                let editor = EditorController(source:source,state:final,title:"Studio notes",preparedPreview:proxy,preferences:preferences,supportDirectory:directory.appendingPathComponent("isolated-support"))
                guard let window = editor.window,let root = window.contentView else { throw VelinshotError.renderingFailed }
                window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
                window.setContentSize(size);root.layoutSubtreeIfNeeded()
                guard editor.canvas.bounds.width >= 500,editor.canvas.bounds.height >= 420 else { throw VelinshotError.invalidImage("The compact editor clipped its canvas.") }
                guard editor.frameControlsFit else { throw VelinshotError.invalidImage("The Frame inspector clipped Reset crop.") }
                try editor.canvas.prepareDocumentationSnapshot()
                let view = root.superview ?? root
                try write(view:view,to:directory.appendingPathComponent(name+".png"))
                records.append(["file":name+".png","appearance":dark ? "dark" : "light","windowWidth":size.width,"windowHeight":size.height,"canvasWidth":editor.canvas.bounds.width,"canvasHeight":editor.canvas.bounds.height,"source":"native AppKit view hierarchy with synthetic fixture"])
                if !minimum {
                    editor.showInspectorSection(1);root.layoutSubtreeIfNeeded()
                    try write(view:view,to:directory.appendingPathComponent(name+"-backdrop.png"))
                    editor.showInspectorSection(2);root.layoutSubtreeIfNeeded()
                    try write(view:view,to:directory.appendingPathComponent(name+"-output.png"))
                    editor.showInspectorSection(0);editor.setTool(.arrow);root.layoutSubtreeIfNeeded()
                    try write(view:view,to:directory.appendingPathComponent(name+"-markup.png"))
                    var margin = final;margin.style.inset = 12
                    margin.annotations.append(Annotation(kind:.arrow,points:[CGPoint(x:-40,y:CGFloat(source.height)*0.7),CGPoint(x:CGFloat(source.width)*0.25,y:-40)],color:RGBA(hex:"F05A6E"),lineWidth:8))
                    editor.canvas.state = margin
                    try editor.canvas.prepareDocumentationSnapshot();root.layoutSubtreeIfNeeded()
                    try write(view:view,to:directory.appendingPathComponent(name+"-margin.png"))
                    try ImageExporter.data(image:CanvasRenderer.render(source:source,state:margin),format:.png).write(to:directory.appendingPathComponent(name+"-margin-export.png"),options:.atomic)
                }
                editor.close()
            }
        }
        let provenance:[String:Any] = ["description":"Native UI rendered from the real app with a synthetic fixture. These are view exports, not live screen recordings.","drawingSymbolPoints":20,"toolbarSymbolPoints":17,"drawingTargetPoints":[38,32],"footerActionHeightPoints":36,"panelBorders":false,"layouts":records]
        try JSONSerialization.data(withJSONObject:provenance,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("provenance.json"),options:.atomic)
        print("Native studio views exported to \(directory.path)")
    }
    private static func write(view:NSView,to url:URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw VelinshotError.renderingFailed }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw VelinshotError.encodingFailed }
        try data.write(to:url,options:.atomic)
    }
}
