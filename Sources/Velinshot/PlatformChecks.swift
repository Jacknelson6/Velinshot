import AppKit
import Carbon
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
        preferences.captureShortcut = AppShortcut(keyCode:UInt32(kVK_F19),modifiers:UInt32(cmdKey | optionKey | controlKey | shiftKey),key:"F19")
        preferences.quickCopyShortcut = AppShortcut(keyCode:UInt32(kVK_F18),modifiers:UInt32(cmdKey | optionKey | controlKey | shiftKey),key:"F18")
        let firstShortcuts = GlobalShortcuts(preferences:preferences)
        let secondShortcuts = GlobalShortcuts(preferences:preferences)
        defer { firstShortcuts.suspend();secondShortcuts.suspend() }
        firstShortcuts.refresh()
        try check(firstShortcuts.captureError == nil && firstShortcuts.quickCopyError == nil,"available shortcuts register without a process-name heuristic")
        secondShortcuts.refresh()
        try check(secondShortcuts.captureError != nil && secondShortcuts.quickCopyError != nil,"macOS registration failure reports an actual occupied shortcut")
        firstShortcuts.suspend();secondShortcuts.refresh()
        try check(secondShortcuts.captureError == nil && secondShortcuts.quickCopyError == nil,"retry succeeds after occupied shortcuts are released")
        secondShortcuts.suspend();firstShortcuts.resume()
        try check(firstShortcuts.captureError == nil && firstShortcuts.quickCopyError == nil,"suspended shortcuts can register again")
        firstShortcuts.suspend()
        preferences.captureShortcut = .fallback;preferences.quickCopyShortcut = .quickCopy
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
        canvas.state = baseline;canvas.tool = .text
        canvas.mouseDown(with:try event(.leftMouseDown,start))
        canvas.subviews.compactMap{$0 as? NSTextField}.first?.stringValue = "Cancelled text must stay absent"
        canvas.finishText(cancel:true)
        try check(canvas.state.annotations.isEmpty,"cancelled text never commits through a reentrant end-edit notification")
        canvas.state = baseline;canvas.tool = .crop
        canvas.mouseDown(with:try event(.leftMouseDown,start));canvas.mouseDragged(with:try event(.leftMouseDragged,end));canvas.mouseUp(with:try event(.leftMouseUp,end))
        try check(canvas.state.crop != nil,"crop gesture commits a source-space crop")
        try check((canvas.state.crop?.width ?? 0)>1 && (canvas.state.crop?.height ?? 0)>1,"crop gesture has positive source-pixel dimensions")
        try check(!canvas.state.style.autoBalance,"manual crop turns automatic balance off")
        canvas.state = baseline;canvas.tool = .pen
        var interruptedCommits = 0
        canvas.onCommit = { _,_ in interruptedCommits += 1 }
        canvas.mouseDown(with:try event(.leftMouseDown,start));canvas.mouseDragged(with:try event(.leftMouseDragged,end))
        canvas.tool = .arrow
        try check(interruptedCommits == 1 && canvas.state.annotations.count == 1,"changing tools commits an in-flight stroke once")
        canvas.mouseUp(with:try event(.leftMouseUp,end))
        try check(interruptedCommits == 1 && !canvas.hasActiveGesture,"a delayed mouse-up cannot duplicate the interrupted stroke")
        canvas.onCommit = nil
        let arrow = Annotation(kind:.arrow,points:[CGPoint(x:0,y:0),CGPoint(x:100,y:100)])
        let resized = AnnotationGeometry.resize(arrow,from:CGRect(x:0,y:0,width:100,height:100),to:CGRect(x:20,y:30,width:200,height:150))
        try check(resized.points == [CGPoint(x:20,y:30),CGPoint(x:220,y:180)],"resize maps both arrow endpoints to the new box")
        try check(resized.id == arrow.id,"resize preserves annotation identity for undo")
        let png = try ImageExporter.data(image:source,format:.png)
        let acceptedJPEG = directory.appendingPathComponent("rapid-switch.png.jpg")
        let acceptedPNG = directory.appendingPathComponent("rapid-switch.png")
        try check(ExportAccessory.encoding(for:acceptedJPEG,selected:.png) == .jpeg,"accepted JPEG extension wins a late PNG picker callback")
        try check(ExportAccessory.encoding(for:acceptedPNG,selected:.jpeg) == .png,"accepted PNG extension wins a late JPEG picker callback")
        let matchedJPEG = try ImageExporter.data(image:source,format:ExportAccessory.encoding(for:acceptedJPEG,selected:.png))
        try check(matchedJPEG.starts(with:[0xff,0xd8]),"rapid format switching cannot write PNG bytes under a JPEG extension")
        let formats = ExportAccessory(format:.png,quality:0.82)
        var chosen:ImageFormat?
        formats.onFormatChange = { chosen = formats.format }
        formats.picker.selectedSegment = 1;_ = formats.picker.sendAction(formats.picker.action,to:formats.picker.target)
        try check(chosen == .jpeg && formats.qualitySlider.isEnabled,"one-click JPEG choice updates encoding and enables quality")
        formats.picker.selectedSegment = 0;_ = formats.picker.sendAction(formats.picker.action,to:formats.picker.target)
        try check(chosen == .png && !formats.qualitySlider.isEnabled,"one-click PNG choice restores lossless encoding and disables JPEG quality")
        formats.onFormatChange = nil
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

        let editor = EditorController(source:source,state:baseline,preferences:preferences,supportDirectory:directory)
        guard let editorWindow = editor.window else { throw VelinshotError.invalidImage("Editor window construction failed.") }
        editorWindow.contentView?.layoutSubtreeIfNeeded()
        let undo = editor.windowWillReturnUndoManager(editorWindow)
        undo?.groupsByEvent = false
        let editorCanvas = editor.canvas
        let editorStart = CGPoint(x:editorCanvas.bounds.midX-50,y:editorCanvas.bounds.midY-25)
        let editorEnd = CGPoint(x:editorCanvas.bounds.midX+70,y:editorCanvas.bounds.midY+30)
        func editorEvent(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with:type,location:editorCanvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:editorWindow.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:1) else { throw VelinshotError.invalidImage("Cannot create editor test event.") }
            return event
        }
        editorCanvas.tool = .arrow
        undo?.beginUndoGrouping()
        editorCanvas.mouseDown(with:try editorEvent(.leftMouseDown,editorStart));editorCanvas.mouseDragged(with:try editorEvent(.leftMouseDragged,editorEnd));editorCanvas.mouseUp(with:try editorEvent(.leftMouseUp,editorEnd))
        undo?.endUndoGrouping()
        try check(editor.state.annotations.count == 1,"integrated editor routes a canvas gesture into the document")
        editor.undoEdit();try check(editor.state.annotations.isEmpty,"integrated document undo removes the arrow")
        editor.redoEdit();try check(editor.state.annotations.count == 1,"integrated document redo restores the arrow")
        func findSlider(_ view:NSView) -> GestureSlider? {
            if let slider = view as? GestureSlider,slider.identifier?.rawValue == "padding" { return slider }
            return view.subviews.compactMap{findSlider($0)}.first
        }
        editor.showInspectorSection(0)
        func findReset(_ view:NSView) -> NSButton? {
            if let button = view as? NSButton,button.title == "Reset crop" { return button }
            return view.subviews.compactMap{findReset($0)}.first
        }
        try check(editorWindow.contentView.flatMap{findReset($0)}?.accessibilityLabel() == "Reset crop","an action exposes its visible name instead of the SF Symbol's generic undo label")
        guard let slider = editorWindow.contentView.flatMap({findSlider($0)}) else { throw VelinshotError.invalidImage("Padding slider was not built.") }
        let analysisState = editor.state
        try check(editor.canInstallAnalysis(for:analysisState),"automatic analysis may install only in an idle matching document")
        slider.onBegin?()
        try check(!editor.canInstallAnalysis(for:analysisState),"a pending frame slider gesture blocks late automatic crop installation")
        slider.onEnd?()
        try check(editor.canInstallAnalysis(for:analysisState),"ending an unchanged frame gesture allows analysis again")
        let oldPadding = editor.state.style.padding
        undo?.beginUndoGrouping()
        slider.onBegin?()
        for value in [70.0,90,120,150] { slider.doubleValue = value;_ = slider.sendAction(slider.action,to:slider.target) }
        slider.onEnd?()
        undo?.endUndoGrouping()
        try check(editor.state.style.padding == 150,"integrated slider updates the visible style")
        editor.undoEdit()
        try check(editor.state.style.padding == oldPadding,"one undo restores an entire slider drag")
        try check(preferences.style.padding == oldPadding,"undo restores next-document style defaults too")
        try check(editor.state.annotations.count == 1,"slider undo preserves earlier annotation history")
        editor.undoEdit();try check(editor.state.annotations.isEmpty,"earlier annotation undo survives the slider gesture")
        editor.redoEdit()
        undo?.beginUndoGrouping()
        editorCanvas.tool = .text
        editorCanvas.mouseDown(with:try editorEvent(.leftMouseDown,editorStart))
        guard let editorField = editorCanvas.subviews.compactMap({$0 as? NSTextField}).first else { throw VelinshotError.invalidImage("Integrated text tool did not create a field.") }
        if let textView = editorField.currentEditor() as? NSTextView {
            textView.insertText("Typed C and S",replacementRange:NSRange(location:NSNotFound,length:0))
        } else { editorField.stringValue = "Typed C and S" }
        editorCanvas.finishText()
        undo?.endUndoGrouping()
        try check(editor.state.annotations.count == 2,"integrated text entry commits one mark")
        editor.undoEdit()
        try check(editor.state.annotations.count == 1,"document undo removes the committed text mark")
        editor.redoEdit()
        try check(editor.state.annotations.count == 2,"document redo restores committed text")
        editorCanvas.tool = .pen
        editorCanvas.mouseDown(with:try editorEvent(.leftMouseDown,editorStart));editorCanvas.mouseDragged(with:try editorEvent(.leftMouseDragged,editorEnd))
        try check(editor.state.annotations.count == 3,"a pending stroke appears before pointer release")
        editor.undoEdit()
        try check(editor.state.annotations.count == 2 && !editorCanvas.hasActiveGesture,"undo during a stroke cancels the draft without touching earlier history")
        editorCanvas.mouseDragged(with:try editorEvent(.leftMouseDragged,editorEnd));editorCanvas.mouseUp(with:try editorEvent(.leftMouseUp,editorEnd))
        try check(editor.state.annotations.count == 2,"late drag and mouse-up after undo preserve the document")
        editor.undoEdit();try check(editor.state.annotations.count == 1,"canceling a pending stroke preserves the preceding text undo")
        editor.redoEdit();try check(editor.state.annotations.count == 2,"earlier document redo survives gesture cancellation")
        let blockedHistory = directory.appendingPathComponent("not-a-history-directory")
        try Data("This file must be preserved".utf8).write(to:blockedHistory,options:.atomic)
        preferences.historyDirectory = blockedHistory;preferences.historyEnabled = true
        try check(!editor.persistHistory(),"an unwritable history destination is reported as a history failure")
        try check(editor.state.annotations.count == 2,"history failure preserves the working document")
        preferences.historyEnabled = false;preferences.historyDirectory = firstHistory
        editor.close()
        count += try ImageWorkChecks.run()
        count += try CanvasMarginChecks.run(directory:directory)
        count += try InsetAutomaticChecks.run(directory:directory)
        count += try CaptureChecks.run()
        count += try EditorChromeChecks.run(directory:directory)
        print("\(count) platform integration checks passed in isolated settings and hidden native views.")
        return count
    }
}
