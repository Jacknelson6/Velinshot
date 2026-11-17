import AppKit
import VelinshotCore

enum EditorChromeChecks {
    static func run(directory:URL) throws -> Int {
        var count = 0
        func check(_ condition:@autoclosure ()->Bool,_ message:String) throws {
            guard condition() else { throw VelinshotError.invalidImage("Editor chrome check failed: \(message)") };count += 1
        }
        let domain = "com.jacknelson.velinshot.editor-chrome."+UUID().uuidString
        guard let defaults = UserDefaults(suiteName:domain) else { throw VelinshotError.invalidImage("Cannot create isolated editor preferences") }
        defer { defaults.removePersistentDomain(forName:domain) }
        let preferences = AppSettings(defaults:defaults)
        let source = try DemoFixture.make()
        let editor = EditorController(source:source,state:DemoFixture.style(),preferences:preferences,supportDirectory:directory.appendingPathComponent("Editor chrome"))
        guard let window = editor.window as? EditorWindow,let root = window.contentView else { throw VelinshotError.invalidImage("Editor did not create a native window") }
        defer { editor.close() }
        func all(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(all) }
        func identified(_ value:String)->NSView? { all(root).first{$0.identifier?.rawValue == value} }
        guard let rail = identified("editor.tools") as? NSStackView,
              let header = identified("editor.header.actions") as? NSStackView,
              let moreTools = identified("editor.more-tools") as? StudioButton,
              let disclosure = identified("editor.advanced-frame") as? StudioButton,
              let advanced = identified("editor.advanced-frame-content") else { throw VelinshotError.invalidImage("Editor chrome is missing a visible entry point") }
        try check(rail.arrangedSubviews.count == 8,"the rail exposes seven common tools and one More entry")
        try check(header.arrangedSubviews.count == 4,"the header exposes Capture, Undo, Redo and More")
        try check(advanced.isHidden,"advanced framing starts collapsed")
        let moreSymbol = moreTools.image
        try check(moreSymbol != nil,"More has a persistent visible menu symbol")
        guard let exports = identified("editor.export.actions") as? NSStackView,
              let utility = identified("editor.footer.utility") as? NSStackView,
              let reset = all(root).compactMap({$0 as? StudioButton}).first(where:{$0.accessibilityLabel() == "Reset crop"}) else { throw VelinshotError.invalidImage("Missing export pair or crop action") }
        try check(exports.arrangedSubviews.compactMap{($0 as? NSButton)?.accessibilityLabel()} == ["Save screenshot","Copy screenshot"],"Save and Copy remain the consistent right export pair")
        try check(utility.arrangedSubviews.contains{$0 is DragExportButton},"Drag remains available as a separate footer utility")
        try check(reset.alignment == .left && disclosure.alignment == .left,"Frame actions align with their inspector column")
        try check(!reset.isEnabled,"Reset crop is disabled when no crop exists")

        for dark in [false,true] {
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            for size in [NSSize(width:950,height:650),NSSize(width:820,height:560)] {
                window.setContentSize(size);root.layoutSubtreeIfNeeded()
                try check(editor.canvas.bounds.width >= 500 && editor.canvas.bounds.height >= 420,"the canvas retains room at each supported layout")
                try check(editor.frameControlsFit,"Reset crop is visible before opening advanced options")
                for view in rail.arrangedSubviews {
                    guard let button = view as? StudioButton,let parent = button.superview else { throw VelinshotError.invalidImage("Tool entry is not a native button") }
                    try check(button.frame.width >= 40 && button.frame.height >= 40,"every visible tool has a large target")
                    try check(parent.bounds.contains(button.frame),"a tool target is contained by its rail stack")
                    try check(!(button.accessibilityLabel() ?? "").isEmpty,"every tool has an accessible name")
                }
                if let parent = rail.superview { try check(parent.bounds.contains(rail.frame),"the complete tool rail fits at minimum height") }
                for view in header.arrangedSubviews {
                    guard let button = view as? StudioButton else { throw VelinshotError.invalidImage("Header entry is not a native button") }
                    try check(button.frame.width >= 40 && button.frame.height >= 40,"every header action has a large target")
                    try check(root.bounds.contains(root.convert(button.bounds,from:button)),"every header action stays inside the editor")
                }
                for label in ["Copy screenshot","Save screenshot","Drag finished screenshot"] {
                    guard let button = all(root).compactMap({$0 as? StudioButton}).first(where:{$0.accessibilityLabel() == label}) else { throw VelinshotError.invalidImage("Missing \(label)") }
                    try check(button.frame.width >= 40 && button.frame.height >= 40,"\(label) retains a large visible target")
                    try check(!button.isHiddenOrHasHiddenAncestor && root.bounds.contains(root.convert(button.bounds,from:button)),"\(label) stays visible and inside the editor")
                }
                editor.setAdvancedFrameExpanded(true);root.layoutSubtreeIfNeeded()
                guard let border = all(advanced).compactMap({$0 as? NSSlider}).first(where:{$0.identifier?.rawValue == "borderWidth"}),
                      let well = all(advanced).compactMap({$0 as? StudioColorWell}).first,
                      let scroll = all(root).compactMap({$0 as? NSScrollView}).first(where:{ advanced.isDescendant(of:$0) }) else { throw VelinshotError.invalidImage("Expanded framing controls are incomplete") }
                try check(well.bounds.height >= 40 && well.prominentSample,"Inset fill has a large legible color control")
                _ = border.scrollToVisible(border.bounds);root.layoutSubtreeIfNeeded()
                try check(scroll.hasVerticalScroller && scroll.contentView.bounds.contains(scroll.contentView.convert(border.bounds,from:border)),"the expanded inspector can scroll to Border at every supported layout")
                editor.setAdvancedFrameExpanded(false);editor.showInspectorSection(0);root.layoutSubtreeIfNeeded()
            }
        }

        let primary:[EditorTool] = [.select,.arrow,.rectangle,.text,.highlighter,.redact,.crop]
        for tool in primary {
            guard let button = rail.arrangedSubviews.compactMap({$0 as? StudioButton}).first(where:{$0.accessibilityLabel() == tool.title}) else { throw VelinshotError.invalidImage("Missing common tool \(tool.title)") }
            button.performClick(nil)
            try check(editor.canvas.tool == tool && button.state == .on,"clicking \(tool.title) selects its actual canvas tool")
            try check(moreTools.state == .off,"a common tool clears the secondary selection")
        }
        let secondary:[EditorTool] = [.pen,.line,.ellipse,.number,.blur]
        let toolsMenu = editor.makeMoreToolsMenu()
        try check(toolsMenu.items.count == secondary.count,"More retains all five secondary tools")
        for tool in secondary {
            guard let item = editor.makeMoreToolsMenu().items.first(where:{$0.representedObject as? String == tool.rawValue}),let action = item.action else { throw VelinshotError.invalidImage("Missing menu route for \(tool.title)") }
            try check(NSApp.sendAction(action,to:item.target,from:item),"\(tool.title) menu action reaches the editor")
            try check(editor.canvas.tool == tool && moreTools.state == .on,"a menu tool selects the canvas and highlights More")
            try check((moreTools.accessibilityValue() as? String)?.contains(tool.title) == true,"More announces the selected secondary tool")
            try check(editor.makeMoreToolsMenu().items.first(where:{$0.representedObject as? String == tool.rawValue})?.state == .on,"the selected secondary menu item has a checkmark")
            try check(moreTools.showsMenuIndicator && moreTools.image === moreSymbol,"More keeps its menu cue for every secondary tool")
        }
        func key(_ letter:String)->NSEvent? {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:letter,charactersIgnoringModifiers:letter,isARepeat:false,keyCode:0)
        }
        for (letter,tool) in [("v",EditorTool.select),("d",.pen),("a",.arrow),("r",.rectangle),("e",.ellipse),("t",.text),("h",.highlighter),("b",.blur),("k",.redact),("n",.number),("x",.crop),("l",.line)] {
            guard let event = key(letter) else { throw VelinshotError.invalidImage("Missing shortcut event") }
            try check(window.onKey?(event) == true && editor.canvas.tool == tool,"\(letter.uppercased()) still selects \(tool.title)")
        }
        func mouse(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with:type,location:editor.canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1) else { throw VelinshotError.invalidImage("Missing editor gesture event") };return event
        }
        let start = CGPoint(x:editor.canvas.bounds.midX-40,y:editor.canvas.bounds.midY-24),end = CGPoint(x:editor.canvas.bounds.midX+40,y:editor.canvas.bounds.midY+24)
        editor.setTool(.crop)
        editor.canvas.mouseDown(with:try mouse(.leftMouseDown,start));editor.canvas.mouseDragged(with:try mouse(.leftMouseDragged,end));editor.canvas.mouseUp(with:try mouse(.leftMouseUp,end))
        try check(editor.state.crop != nil && reset.isEnabled,"a real crop enables Reset crop")
        reset.performClick(nil)
        try check(editor.state.crop == nil && !reset.isEnabled,"Reset crop clears the crop and returns to its disabled state")
        editor.setTool(.text);root.layoutSubtreeIfNeeded()
        guard let color = identified("editor.annotation.color"),
              let font = all(root).compactMap({$0 as? NSPopUpButton}).first(where:{$0.accessibilityLabel() == "Annotation text size"}) else { throw VelinshotError.invalidImage("Text markup controls are missing") }
        editor.setTool(.blur);root.layoutSubtreeIfNeeded()
        guard let strength = identified("editor.annotation.width") as? NSSegmentedControl,
              let guidance = identified("editor.markup.guidance") as? NSTextField else { throw VelinshotError.invalidImage("Missing contextual markup controls") }
        try check(color.isHiddenOrHasHiddenAncestor && font.isHiddenOrHasHiddenAncestor,"Blur hides its irrelevant color and font controls")
        try check(!strength.isHiddenOrHasHiddenAncestor && strength.accessibilityLabel() == "Blur strength","Blur keeps its functional strength control")
        try check((0..<3).map{strength.label(forSegment:$0) ?? ""} == ["Soft","Medium","Strong"],"Blur labels describe the existing intensity behavior")
        try check(!guidance.isHiddenOrHasHiddenAncestor && !guidance.stringValue.isEmpty,"Blur provides concise gesture guidance")
        let priorCount = editor.state.annotations.count
        editor.canvas.mouseDown(with:try mouse(.leftMouseDown,start));editor.canvas.mouseDragged(with:try mouse(.leftMouseDragged,end));editor.canvas.mouseUp(with:try mouse(.leftMouseUp,end))
        try check(editor.state.annotations.count == priorCount+1 && editor.state.annotations.last?.kind == .blur,"the Blur gesture still creates a real annotation")
        editor.setTool(.select)
        let center = CGPoint(x:editor.canvas.bounds.midX,y:editor.canvas.bounds.midY)
        editor.canvas.mouseDown(with:try mouse(.leftMouseDown,center));editor.canvas.mouseUp(with:try mouse(.leftMouseUp,center))
        strength.selectedSegment = 2
        try check(strength.sendAction(strength.action,to:strength.target),"the Strong choice invokes the existing width action")
        try check(editor.canvas.lineWidth == 12 && editor.state.annotations.last?.lineWidth == 12,"Blur strength updates both the drawing default and selected blur annotation")
        editor.setTool(.select);root.layoutSubtreeIfNeeded()
        disclosure.performClick(nil);root.layoutSubtreeIfNeeded()
        try check(!advanced.isHidden && disclosure.accessibilityValue() as? String == "Expanded","Advanced frame reveals its controls through the actual button")
        guard let inset = all(advanced).compactMap({$0 as? NSSlider}).first(where:{$0.identifier?.rawValue == "inset"}),
              let border = all(advanced).compactMap({$0 as? NSSlider}).first(where:{$0.identifier?.rawValue == "borderWidth"}) else { throw VelinshotError.invalidImage("Advanced controls are missing") }
        try check(!inset.isHiddenOrHasHiddenAncestor && !border.isHiddenOrHasHiddenAncestor,"Inset and Border remain in the expanded inspector hierarchy")
        try check(window.makeFirstResponder(inset) && window.firstResponder === inset,"expanded advanced controls accept keyboard focus")
        disclosure.performClick(nil);root.layoutSubtreeIfNeeded()
        try check(advanced.isHidden && editor.frameControlsFit,"collapsing advanced options keeps Reset crop reachable")
        try check(window.firstResponder === disclosure || window.firstResponder === editor.canvas,"collapsing advanced options moves focus out of hidden controls")

        var opened = false,pasted = false,history = false,settings = false
        editor.onOpen = { opened = true };editor.onPaste = { pasted = true };editor.onHistory = { history = true };editor.onSettings = { settings = true }
        let actionsMenu = editor.makeMoreMenu()
        for title in ["Fit to Preview","Copy Image Text…","Share Screenshot…","Open Image…","Open from Clipboard","Screenshot History…","Settings…"] {
            try check(actionsMenu.items.contains{$0.title == title && $0.action != nil && $0.target === editor},"\(title) is discoverable and routed in More")
        }
        try check(actionsMenu.items.contains{$0.title == "Share Screenshot…" && $0.action == NSSelectorFromString("requestShare") && $0.target === editor},"Share routes from More to the editor's native sharing action")
        for title in ["Open Image…","Open from Clipboard","Screenshot History…","Settings…"] {
            guard let item = actionsMenu.items.first(where:{$0.title == title}),let action = item.action else { throw VelinshotError.invalidImage("Missing More action") }
            try check(NSApp.sendAction(action,to:item.target,from:item),"\(title) invokes its real action")
        }
        try check(opened && pasted && history && settings,"moved More actions reach their application callbacks")

        let field = NSTextView(frame:CGRect(x:0,y:0,width:100,height:40));field.isEditable = true;root.addSubview(field)
        defer { field.removeFromSuperview() }
        try check(window.makeFirstResponder(field),"an editing field can own keyboard focus")
        let selected = editor.canvas.tool
        for letter in ["c","s","a","d"] {
            guard let event = key(letter) else { throw VelinshotError.invalidImage("Missing text event") }
            try check(window.onKey?(event) == false && editor.canvas.tool == selected,"typing \(letter.uppercased()) does not invoke an editor shortcut")
        }
        window.makeFirstResponder(editor.canvas)
        return count
    }
}
