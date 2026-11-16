import AppKit
import UniformTypeIdentifiers
import VelinshotCore

final class EditorWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let text = firstResponder as? NSTextView, text.isEditable { return super.performKeyEquivalent(with:event) }
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with:event)
    }
}

final class EditorController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let canvas: CanvasView
    let source: CGImage
    var onClose: (() -> Void)?
    var onCapture: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHistory: (() -> Void)?
    var onImportURL: ((URL) -> Void)?
    var onImportData: ((Data) -> Void)?
    var historyEntry: HistoryEntry?
    private let editorUndo = UndoManager()
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var sliders: [String: NSSlider] = [:]
    private var valueLabels: [String: NSTextField] = [:]
    private var backgroundPicker = NSPopUpButton()
    private var ratioPicker = NSPopUpButton()
    private var scalePicker = NSPopUpButton()
    private var presetPicker = NSPopUpButton()
    private var firstColor = NSColorWell()
    private var secondColor = NSColorWell()
    private var insetColor = NSColorWell()
    private var annotationColorWell = NSColorWell()
    private var balanceCheck:NSButton!
    private var autoColorCheck:NSButton!
    private var watermarkField = NSTextField()
    private var watermarkPosition = NSPopUpButton()
    private var watermarkColor = NSColorWell()
    private var sharePicker:NSSharingServicePicker?
    private var statusLabel = Brand.label("",size:11)
    private var dimensionsLabel = Brand.label("",size:11)
    private var ocrButton: NSButton!
    private var presets: [StylePreset] = []
    private let presetStore = PresetStore(fileURL: AppSettings.supportDirectory.appendingPathComponent("presets.json"))
    private var historyStore: HistoryStore { HistoryStore(directory: AppSettings.shared.historyDirectory) }
    private var infoWindow: NSWindow?
    private var userIsClosing = false
    private var isSaving = false

    init(source: CGImage, state: EditState? = nil, title: String = "Screenshot") {
        self.source = source
        let initial = state ?? NewDocument.state(source:source,style:AppSettings.shared.style)
        canvas = CanvasView(source:source,state:initial)
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x:0,y:0,width:1200,height:800)
        let size = CGSize(width:min(950,visible.width-32),height:min(650,visible.height-32))
        let window = EditorWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = CGSize(width:820,height:560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window:window)
        window.delegate = self
        editorUndo.levelsOfUndo = 100
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        buildInterface()
        canvas.onCommit = { [weak self] before, after in self?.commit(before:before,after:after) }
        canvas.onError = { [weak self] in self?.setStatus($0.localizedDescription,error:true) }
        canvas.onImportURL = { [weak self] in self?.onImportURL?($0) }
        canvas.onImportData = { [weak self] in self?.onImportData?($0) }
        canvas.onBackgroundDoubleClick = { [weak self] in self?.copyImage(forceClose:true) }
        canvas.onKey = { [weak self] in self?.handleKey($0) ?? false }
        canvas.onSelection = { [weak self] annotation in
            guard let self,let annotation else { return }
            self.annotationColorWell.color = annotation.color.nsColor
            self.canvas.annotationColor = annotation.color;self.canvas.lineWidth = annotation.lineWidth;self.canvas.fontSize = annotation.fontSize
        }
        loadBackground()
        loadPresets()
        syncInspector()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    var state: EditState { canvas.state }
    var canUndo:Bool { editorUndo.canUndo }
    var canRedo:Bool { editorUndo.canRedo }
    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps:true)
        window?.makeFirstResponder(canvas)
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editorUndo }
    func windowWillClose(_ notification: Notification) {
        canvas.finishText()
        persistHistory()
        userIsClosing = true
        infoWindow?.close()
        onClose?()
    }
    private func buildInterface() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        let header = NSView(); let content = NSView();let footer = NSView()
        for view in [header,content,footer] { root.addSubview(view);view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:root.topAnchor),header.leadingAnchor.constraint(equalTo:root.leadingAnchor),header.trailingAnchor.constraint(equalTo:root.trailingAnchor),header.heightAnchor.constraint(equalToConstant:52),
            content.topAnchor.constraint(equalTo:header.bottomAnchor),content.leadingAnchor.constraint(equalTo:root.leadingAnchor),content.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            footer.topAnchor.constraint(equalTo:content.bottomAnchor),footer.bottomAnchor.constraint(equalTo:root.bottomAnchor),footer.leadingAnchor.constraint(equalTo:root.leadingAnchor),footer.trailingAnchor.constraint(equalTo:root.trailingAnchor),footer.heightAnchor.constraint(equalToConstant:54)
        ])
        let title = Brand.label("Velinshot",size:13,weight:.semibold)
        let icon = NSImageView(image:NSImage(named:NSImage.Name("AppIcon")) ?? Brand.symbol("viewfinder")!)
        icon.translatesAutoresizingMaskIntoConstraints = false;icon.widthAnchor.constraint(equalToConstant:23).isActive = true;icon.heightAnchor.constraint(equalToConstant:23).isActive = true
        let capture = ActionButton(title:"",symbol:"viewfinder") { [weak self] in self?.onCapture?() };capture.toolTip = "New capture"
        let open = ActionButton(title:"",symbol:"folder") { [weak self] in self?.onOpen?() };open.toolTip = "Open image (⌘O)"
        let paste = ActionButton(title:"",symbol:"clipboard") { [weak self] in self?.onPaste?() };paste.toolTip = "Open image from clipboard (⌘V)"
        let undo = ActionButton(title:"",symbol:"arrow.uturn.backward") { [weak self] in self?.undoEdit() };undo.toolTip = "Undo (⌘Z)"
        let redo = ActionButton(title:"",symbol:"arrow.uturn.forward") { [weak self] in self?.redoEdit() };redo.toolTip = "Redo (⇧⌘Z)"
        ocrButton = ActionButton(title:"",symbol:"text.viewfinder") { [weak self] in self?.recognizeText() };ocrButton.toolTip = "Select and copy text from this image"
        let history = ActionButton(title:"",symbol:"clock.arrow.circlepath") { [weak self] in self?.onHistory?() };history.toolTip = "Screenshot history"
        let settings = ActionButton(title:"",symbol:"slider.horizontal.3") { [weak self] in self?.onSettings?() };settings.toolTip = "Settings"
        let fit = ActionButton(title:"Fit") { [weak self] in self?.canvas.fit() };fit.toolTip = "Fit image to preview"
        let spacer = NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let headerStack = NSStackView(views:[icon,title,spacer,undo,redo,fit,ocrButton,history,capture,open,paste,settings])
        headerStack.orientation = .horizontal;headerStack.spacing = 8;headerStack.alignment = .centerY
        header.addSubview(headerStack);headerStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerStack.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:80),headerStack.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-14),headerStack.centerYAnchor.constraint(equalTo:header.centerYAnchor)])
        for button in [capture,open,paste,undo,redo,ocrButton!,history,settings] { button.isBordered = false;button.widthAnchor.constraint(equalToConstant:25).isActive = true;button.setAccessibilityLabel(button.toolTip) }

        let rail = NSView();rail.wantsLayer = true
        let inspector = buildInspector()
        for view in [rail,canvas,inspector] { content.addSubview(view);view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo:content.leadingAnchor),rail.topAnchor.constraint(equalTo:content.topAnchor),rail.bottomAnchor.constraint(equalTo:content.bottomAnchor),rail.widthAnchor.constraint(equalToConstant:50),
            inspector.trailingAnchor.constraint(equalTo:content.trailingAnchor),inspector.topAnchor.constraint(equalTo:content.topAnchor),inspector.bottomAnchor.constraint(equalTo:content.bottomAnchor),inspector.widthAnchor.constraint(equalToConstant:238),
            canvas.leadingAnchor.constraint(equalTo:rail.trailingAnchor),canvas.trailingAnchor.constraint(equalTo:inspector.leadingAnchor),canvas.topAnchor.constraint(equalTo:content.topAnchor),canvas.bottomAnchor.constraint(equalTo:content.bottomAnchor)
        ])
        let tools = NSStackView();tools.orientation = .vertical;tools.spacing = 3
        rail.addSubview(tools);tools.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tools.topAnchor.constraint(equalTo:rail.topAnchor,constant:8),tools.centerXAnchor.constraint(equalTo:rail.centerXAnchor)])
        for tool in EditorTool.allCases {
            let button = ActionButton(title:"",symbol:tool.symbol) { [weak self] in self?.setTool(tool) }
            button.toolTip = tool.title;button.setAccessibilityLabel(tool.title)
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false;button.wantsLayer = true;button.layer?.cornerRadius = 7
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant:34),button.heightAnchor.constraint(equalToConstant:32)])
            toolButtons[tool] = button;tools.addArrangedSubview(button)
        }
        setTool(.select)
        addRule(to:root,yAnchor:header.bottomAnchor)
        addRule(to:root,yAnchor:footer.topAnchor)
        let copy = ActionButton(title:"Copy  C",symbol:"doc.on.doc") { [weak self] in self?.copyImage() }
        copy.bezelColor = Brand.iris;copy.contentTintColor = .white;copy.setAccessibilityLabel("Copy screenshot")
        copy.attributedTitle = NSAttributedString(string:"Copy  C",attributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:12,weight:.semibold)])
        copy.image = copy.image?.withSymbolConfiguration(.init(paletteColors:[.white]))
        let save = ActionButton(title:"Save…  S",symbol:"square.and.arrow.down") { [weak self] in self?.saveImage() };save.setAccessibilityLabel("Save screenshot")
        let drag = DragExportButton();drag.imageProvider = { [weak self] in
            guard let self else { throw VelinshotError.renderingFailed };return try self.renderedImage()
        };drag.onError = { [weak self] in self?.showError($0) }
        let share = ActionButton(title:"",symbol:"square.and.arrow.up") {}
        share.actionHandler = { [weak self,weak share] in if let share { self?.shareScreenshot(share) } }
        share.toolTip = "Share finished screenshot";share.setAccessibilityLabel("Share screenshot")
        let footerSpacer = NSView();footerSpacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);dimensionsLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor;statusLabel.lineBreakMode = .byTruncatingTail;statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let bottom = NSStackView(views:[dimensionsLabel,statusLabel,footerSpacer,drag,share,save,copy]);bottom.spacing = 10;bottom.alignment = .centerY
        footer.addSubview(bottom);bottom.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bottom.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:16),bottom.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-16),bottom.centerYAnchor.constraint(equalTo:footer.centerYAnchor),copy.widthAnchor.constraint(equalToConstant:108),save.widthAnchor.constraint(equalToConstant:108)])
    }
    private func addRule(to root: NSView,yAnchor:NSLayoutYAxisAnchor) {
        let rule = NSBox();rule.boxType = .separator;root.addSubview(rule);rule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rule.leadingAnchor.constraint(equalTo:root.leadingAnchor),rule.trailingAnchor.constraint(equalTo:root.trailingAnchor),rule.topAnchor.constraint(equalTo:yAnchor),rule.heightAnchor.constraint(equalToConstant:1)])
    }
    private func buildInspector() -> NSScrollView {
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.drawsBackground = false
        let document = FlippedView();scroll.documentView = document;document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor)])
        let stack = NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 14;stack.detachesHiddenViews = true
        document.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:document.topAnchor,constant:18),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-18)])
        func add(_ view:NSView) { stack.addArrangedSubview(view);view.translatesAutoresizingMaskIntoConstraints = false;view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        add(Brand.label("Frame",size:17,weight:.semibold))
        backgroundPicker.addItems(withTitles:["Gradient","Solid color","Image","Transparent"]);backgroundPicker.target = self;backgroundPicker.action = #selector(backgroundChanged)
        backgroundPicker.setAccessibilityLabel("Background type");add(backgroundPicker)
        firstColor.target = self;firstColor.action = #selector(colorsChanged);secondColor.target = self;secondColor.action = #selector(colorsChanged)
        firstColor.setAccessibilityLabel("First background color");secondColor.setAccessibilityLabel("Second background color")
        let colors = NSStackView(views:[firstColor,secondColor]);colors.spacing = 8;colors.distribution = .fillEqually;add(colors)
        for well in [firstColor,secondColor] { well.heightAnchor.constraint(equalToConstant:24).isActive = true }
        let swatches = NSStackView();swatches.spacing = 7
        let combinations = [("Iris","#B7AEF8","#E6E3FF"),("Peach","#F5AF98","#F9E4BD"),("Ocean","#92C6E9","#C4E4DC"),("Ink","#292B3E","#54517B"),("Paper","#F1EEE6","#FBFAF7")]
        for (name,c1,c2) in combinations {
            let button = ActionButton(title:"") { [weak self] in self?.change { $0.style.color1 = RGBA(hex:c1);$0.style.color2 = RGBA(hex:c2);$0.style.background = .gradient;$0.style.autoColor = false } }
            button.isBordered = false;button.wantsLayer = true;button.layer?.backgroundColor = RGBA(hex:c1).nsColor.cgColor;button.layer?.cornerRadius = 10
            button.toolTip = name;button.setAccessibilityLabel("\(name) gradient")
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant:26),button.heightAnchor.constraint(equalToConstant:24)])
            swatches.addArrangedSubview(button)
        }
        add(swatches)
        let customBackground = ActionButton(title:"Choose image…",symbol:"photo") { [weak self] in self?.chooseBackground() };customBackground.toolTip = "Choose a custom background image";add(customBackground)
        add(ActionButton(title:"Use desktop wallpaper",symbol:"desktopcomputer") { [weak self] in self?.useDesktopBackground() })
        add(sliderRow("Padding",key:"padding",min:0,max:240))
        add(sliderRow("Inset",key:"inset",min:0,max:160))
        insetColor.target = self;insetColor.action = #selector(insetColorChanged);insetColor.setAccessibilityLabel("Inset fill color")
        add(NSStackView(views:[Brand.label("Inset fill"),insetColor]))
        add(sliderRow("Corners",key:"cornerRadius",min:0,max:100))
        add(sliderRow("Shadow",key:"shadow",min:0,max:100))
        add(sliderRow("Border",key:"borderWidth",min:0,max:12))
        add(sliderRow("Gradient angle",key:"gradientAngle",min:0,max:360))
        balanceCheck = CheckButton(title:"Auto balance",value:canvas.state.style.autoBalance) { [weak self] enabled in
            guard let self else { return };let crop = enabled ? AutoBeautify.contentBounds(source:self.source) : nil
            self.change{$0.style.autoBalance = enabled;$0.crop = crop};self.canvas.fit()
        };add(balanceCheck)
        autoColorCheck = CheckButton(title:"Match image colors",value:canvas.state.style.autoColor) { [weak self] enabled in
            guard let self else { return };let colors = AutoBeautify.suggestColors(source:self.source)
            self.change{$0.style.autoColor = enabled;if enabled {$0.style.color1 = colors.0;$0.style.color2 = colors.1;$0.style.background = .gradient}}
        };add(autoColorCheck)
        let balance = ActionButton(title:"Balance & color",symbol:"wand.and.stars") { [weak self] in self?.autoBeautify() };add(balance)
        let resetCrop = ActionButton(title:"Reset crop",symbol:"arrow.uturn.backward") { [weak self] in self?.change { $0.crop = nil;$0.style.autoBalance = false };self?.canvas.fit() };add(resetCrop)
        add(separator())
        add(Brand.label("Canvas",size:13,weight:.semibold))
        ratioPicker.addItems(withTitles:Self.ratios.map{$0.0}+["Custom ratio or size…"]+Self.sizes.map{$0.0})
        ratioPicker.target = self;ratioPicker.action = #selector(ratioChanged);ratioPicker.setAccessibilityLabel("Canvas aspect ratio");add(ratioPicker)
        scalePicker.addItems(withTitles:["1×  Original pixels","2×  Double pixels","½×  Smaller image","Set output width…"])
        scalePicker.target = self;scalePicker.action = #selector(scaleChanged);scalePicker.setAccessibilityLabel("Output scale");add(scalePicker)
        add(separator());add(Brand.label("Annotation",size:13,weight:.semibold))
        annotationColorWell.color = canvas.annotationColor.nsColor;annotationColorWell.target = self;annotationColorWell.action = #selector(annotationColorChanged);annotationColorWell.setAccessibilityLabel("Annotation color");add(annotationColorWell)
        let width = NSSegmentedControl(labels:["Thin","Medium","Bold"],trackingMode:.selectOne,target:self,action:#selector(widthChanged));width.selectedSegment = 1;add(width)
        let fonts = NSPopUpButton();fonts.addItems(withTitles:["Text 24 px","Text 36 px","Text 48 px","Text 72 px","Text 96 px"]);fonts.selectItem(at:1);fonts.target = self;fonts.action = #selector(fontChanged);fonts.setAccessibilityLabel("Annotation text size");add(fonts)
        add(separator());add(Brand.label("Watermark",size:13,weight:.semibold))
        watermarkField.placeholderString = "Optional text (empty hides it)";watermarkField.delegate = self;watermarkField.setAccessibilityLabel("Optional watermark text");add(watermarkField)
        watermarkPosition.addItems(withTitles:["Top left","Top right","Bottom left","Bottom right"]);watermarkPosition.target = self;watermarkPosition.action = #selector(watermarkPositionChanged);watermarkPosition.setAccessibilityLabel("Watermark position");add(watermarkPosition)
        watermarkColor.target = self;watermarkColor.action = #selector(watermarkColorChanged);watermarkColor.setAccessibilityLabel("Watermark color");add(NSStackView(views:[Brand.label("Text color"),watermarkColor]))
        add(separator());add(Brand.label("Presets",size:13,weight:.semibold))
        presetPicker.target = self;presetPicker.action = #selector(presetChanged);presetPicker.setAccessibilityLabel("Saved frame preset");add(presetPicker)
        let savePreset = ActionButton(title:"Save current style…",symbol:"plus") { [weak self] in self?.savePreset() };add(savePreset)
        let deletePreset = ActionButton(title:"Delete selected preset",symbol:"minus") { [weak self] in self?.deletePreset() };add(deletePreset)
        return scroll
    }
    private func separator() -> NSView { let box = NSBox();box.boxType = .separator;return box }
    private func sliderRow(_ title:String,key:String,min:Double,max:Double) -> NSView {
        let label = Brand.label(title)
        let value = Brand.label("",size:11);value.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);value.textColor = .secondaryLabelColor
        let spacer = NSView();let top = NSStackView(views:[label,spacer,value]);top.distribution = .fill;top.alignment = .centerY
        let slider = NSSlider(value:0,minValue:min,maxValue:max,target:self,action:#selector(sliderChanged));slider.identifier = .init(key);slider.isContinuous = true;slider.setAccessibilityLabel(title)
        sliders[key] = slider;valueLabels[key] = value
        let group = NSStackView(views:[top,slider]);group.orientation = .vertical;group.spacing = 5;group.alignment = .leading
        top.widthAnchor.constraint(equalTo:group.widthAnchor).isActive = true;slider.widthAnchor.constraint(equalTo:group.widthAnchor).isActive = true
        return group
    }
    private func setTool(_ tool:EditorTool) {
        canvas.finishText();canvas.tool = tool
        for (kind,button) in toolButtons {
            button.state = kind == tool ? .on : .off
            button.layer?.backgroundColor = (kind == tool ? Brand.iris.withAlphaComponent(0.13) : .clear).cgColor
            button.contentTintColor = kind == tool ? Brand.iris : .secondaryLabelColor
        }
        window?.makeFirstResponder(canvas)
        setStatus(tool.title)
    }
    private func commit(before:EditState,after:EditState) {
        guard before != after else { return }
        editorUndo.registerUndo(withTarget:self) { target in target.restore(before) }
        editorUndo.setActionName("Edit screenshot")
        AppSettings.shared.style = after.style
        syncInspector()
    }
    private func restore(_ state:EditState) {
        let previous = canvas.state
        editorUndo.registerUndo(withTarget:self) { target in target.restore(previous) }
        canvas.state = state;canvas.clearSelection();loadBackground();syncInspector()
    }
    private func change(_ mutation:(inout EditState)->Void) {
        canvas.finishText()
        let before = canvas.state;var after = before;mutation(&after)
        do { _ = try CanvasRenderer.layout(sourceSize:CGSize(width:source.width,height:source.height),state:after) }
        catch { setStatus(error.localizedDescription,error:true);return }
        canvas.state = after;commit(before:before,after:after)
    }
    func undoEdit() { canvas.finishText();editorUndo.undo();syncInspector() }
    func redoEdit() { canvas.finishText();editorUndo.redo();syncInspector() }
    private func syncInspector() {
        let style = canvas.state.style
        let values = ["padding":style.padding,"inset":style.inset,"cornerRadius":style.cornerRadius,"shadow":style.shadow,"borderWidth":style.borderWidth,"gradientAngle":style.gradientAngle]
        for (key,value) in values { sliders[key]?.doubleValue = value;valueLabels[key]?.stringValue = "\(Int(value))\(key == "gradientAngle" ? "°" : " px")" }
        backgroundPicker.selectItem(at:[BackgroundKind.gradient,.solid,.image,.transparent].firstIndex(of:style.background) ?? 0)
        firstColor.color = style.color1.nsColor;secondColor.color = style.color2.nsColor
        insetColor.color = style.insetColor.nsColor;balanceCheck?.state = style.autoBalance ? .on : .off;autoColorCheck?.state = style.autoColor ? .on : .off
        if let width = style.fixedWidth,let height = style.fixedHeight {
            ratioPicker.selectItem(at:Self.sizes.firstIndex(where:{$0.1 == width && $0.2 == height}).map{Self.ratios.count+1+$0} ?? Self.ratios.count)
            scalePicker.selectItem(at:3)
        } else {
            ratioPicker.selectItem(at:Self.ratios.firstIndex(where:{abs($0.1-style.ratioWidth)<0.001 && abs($0.2-style.ratioHeight)<0.001}) ?? Self.ratios.count)
            scalePicker.selectItem(at:abs(style.outputScale-1)<0.001 ? 0 : abs(style.outputScale-2)<0.001 ? 1 : abs(style.outputScale-0.5)<0.001 ? 2 : 3)
        }
        if watermarkField.stringValue != style.watermarkText { watermarkField.stringValue = style.watermarkText }
        watermarkPosition.selectItem(at:WatermarkPosition.allCases.firstIndex(of:style.watermarkPosition) ?? 3);watermarkColor.color = style.watermarkColor.nsColor
        if let layout = try? CanvasRenderer.layout(sourceSize:CGSize(width:source.width,height:source.height),state:canvas.state) {
            dimensionsLabel.stringValue = "\(Int(layout.exportSize.width)) × \(Int(layout.exportSize.height)) px"
        }
    }
    @objc private func sliderChanged(_ slider:NSSlider) {
        guard let key = slider.identifier?.rawValue else { return }
        let value = slider.doubleValue.rounded()
        change {
            switch key {
            case "padding":$0.style.padding = value
            case "inset":$0.style.inset = value
            case "cornerRadius":$0.style.cornerRadius = value
            case "shadow":$0.style.shadow = value
            case "borderWidth":$0.style.borderWidth = value
            case "gradientAngle":$0.style.gradientAngle = value
            default:break
            }
        }
    }
    @objc private func backgroundChanged(_ sender:NSPopUpButton) { let types:[BackgroundKind] = [.gradient,.solid,.image,.transparent];change{$0.style.background = types[sender.indexOfSelectedItem];$0.style.autoColor = false};if sender.indexOfSelectedItem == 2, canvas.backgroundImage == nil { chooseBackground() } }
    @objc private func colorsChanged(_ sender:NSColorWell) { change{$0.style.color1 = RGBA(firstColor.color);$0.style.color2 = RGBA(secondColor.color);$0.style.autoColor = false} }
    @objc private func insetColorChanged(_ sender:NSColorWell) { change{$0.style.insetColor = RGBA(sender.color)} }
    @objc private func annotationColorChanged(_ sender:NSColorWell) { canvas.annotationColor = RGBA(sender.color);canvas.changeSelection(color:canvas.annotationColor) }
    @objc private func widthChanged(_ sender:NSSegmentedControl) { canvas.lineWidth = [3.0,6,12][sender.selectedSegment];canvas.changeSelection(lineWidth:canvas.lineWidth) }
    @objc private func fontChanged(_ sender:NSPopUpButton) { canvas.fontSize = [24.0,36,48,72,96][sender.indexOfSelectedItem];canvas.changeSelection(fontSize:canvas.fontSize) }
    @objc private func watermarkPositionChanged(_ sender:NSPopUpButton) { change{$0.style.watermarkPosition = WatermarkPosition.allCases[sender.indexOfSelectedItem]} }
    @objc private func watermarkColorChanged(_ sender:NSColorWell) { change{$0.style.watermarkColor = RGBA(sender.color)} }
    func controlTextDidChange(_ notification:Notification) {
        guard notification.object as? NSTextField === watermarkField else { return }
        let text = String(watermarkField.stringValue.prefix(512));change{$0.style.watermarkText = text}
    }
    private static let ratios:[(String,Double,Double)] = [("Original ratio",0,0),("4:3  Classic",4,3),("3:2  Photo",3,2),("1:1  Square",1,1),("4:5  Portrait",4,5),("9:16  Story",9,16),("16:9  Wide",16,9),("1.91:1  Social",1.91,1)]
    private static let sizes:[(String,Int,Int)] = [("Instagram · 1080 × 1080",1080,1080),("Portrait · 1080 × 1350",1080,1350),("Stories · 1080 × 1920",1080,1920),("X / Twitter · 1600 × 900",1600,900),("Facebook · 1200 × 630",1200,630),("LinkedIn · 1200 × 627",1200,627),("YouTube · 1280 × 720",1280,720),("Pinterest · 1000 × 1500",1000,1500),("Reddit · 1200 × 628",1200,628)]
    @objc private func ratioChanged(_ sender:NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index < Self.ratios.count { let ratio = Self.ratios[index];change{$0.style.ratioWidth = ratio.1;$0.style.ratioHeight = ratio.2;$0.style.fixedWidth = nil;$0.style.fixedHeight = nil};canvas.fit();return }
        if index > Self.ratios.count { let size = Self.sizes[index-Self.ratios.count-1];setFixedSize(width:size.1,height:size.2);return }
        guard let result = ask("Custom canvas",message:"Enter a ratio (3:2) or an exact size in pixels (1920x1080).",placeholder:"1920x1080") else { syncInspector();return }
        let sizeParts = result.lowercased().replacingOccurrences(of:"×",with:"x").split(separator:"x").compactMap{Int($0.trimmingCharacters(in:.whitespaces))}
        if sizeParts.count == 2 { setFixedSize(width:sizeParts[0],height:sizeParts[1]);return }
        let parts = result.split(separator:":").compactMap { Double($0.trimmingCharacters(in:.whitespaces)) }
        guard parts.count == 2,parts.allSatisfy({$0.isFinite && $0>0 && $0<=1000}) else { setStatus("Enter a ratio such as 3:2.",error:true);syncInspector();return }
        change{$0.style.ratioWidth = parts[0];$0.style.ratioHeight = parts[1];$0.style.fixedWidth = nil;$0.style.fixedHeight = nil};canvas.fit()
    }
    private func setFixedSize(width:Int,height:Int) {
        guard width>0,height>0,width<=16384,height<=16384,width*height<=40_000_000 else { setStatus("Choose dimensions up to 40 megapixels and 16384 px per side.",error:true);syncInspector();return }
        let maximum = Double(max(width,height))
        change{$0.style.fixedWidth = width;$0.style.fixedHeight = height;$0.style.ratioWidth = Double(width)/maximum*1000;$0.style.ratioHeight = Double(height)/maximum*1000}
        canvas.fit()
    }
    @objc private func scaleChanged(_ sender:NSPopUpButton) {
        if sender.indexOfSelectedItem < 3 { let scale = [1.0,2,0.5][sender.indexOfSelectedItem];change{$0.style.outputScale = scale;$0.style.fixedWidth = nil;$0.style.fixedHeight = nil};return }
        guard let input = ask("Output width",message:"Enter the final width in pixels. Height follows the canvas ratio.",placeholder:"1920"),let width = Double(input),width.isFinite,width>0,let layout = try? CanvasRenderer.layout(sourceSize:CGSize(width:source.width,height:source.height),state:canvas.state) else { syncInspector();return }
        guard width<=16384 else { syncInspector();return };setFixedSize(width:Int(width.rounded()),height:max(1,Int((width/layout.canvasSize.width*layout.canvasSize.height).rounded())))
    }
    private func autoBeautify() {
        let colors = AutoBeautify.suggestColors(source:source)
        let crop = AutoBeautify.contentBounds(source:source)
        change{$0.style.color1 = colors.0;$0.style.color2 = colors.1;$0.style.background = .gradient;$0.crop = crop;$0.style.autoBalance = true;$0.style.autoColor = true}
        canvas.fit();setStatus("Balanced and matched to your image")
    }
    private func chooseBackground() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.image];panel.canChooseDirectories = false
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            try setBackground(url:url)
        } catch { showError(error) }
    }
    private func setBackground(url:URL) throws {
            let image = try ImageLoader.load(url:url)
            let data = try ImageExporter.data(image:image,format:.png)
            let directory = AppSettings.supportDirectory.appendingPathComponent("Backgrounds",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let id = UUID().uuidString
            try data.write(to:directory.appendingPathComponent(id+".png"),options:.atomic)
            change{$0.style.background = .image;$0.style.backgroundAssetID = id;$0.style.autoColor = false};canvas.backgroundImage = image
    }
    private func useDesktopBackground() {
        do {
            guard let screen = window?.screen ?? NSScreen.main,let url = NSWorkspace.shared.desktopImageURL(for:screen),!url.hasDirectoryPath else { throw VelinshotError.invalidImage("The current desktop wallpaper is not an accessible image.") }
            try setBackground(url:url)
        } catch { change{$0.style.background = .gradient};setStatus("Wallpaper unavailable. Using the gradient; choose an image instead.",error:true) }
    }
    private func loadBackground() {
        guard let id = canvas.state.style.backgroundAssetID,UUID(uuidString:id) != nil else { canvas.backgroundImage = nil;return }
        let url = AppSettings.supportDirectory.appendingPathComponent("Backgrounds",isDirectory:true).appendingPathComponent(id+".png")
        do { canvas.backgroundImage = try ImageLoader.load(url:url) }
        catch { canvas.backgroundImage = nil;setStatus("Background image is missing. Choose it again.",error:true) }
    }
    private func loadPresets() {
        do { presets = try presetStore.load() }
        catch { presets = [];setStatus("Could not read presets: \(error.localizedDescription)",error:true) }
        presetPicker.removeAllItems();presetPicker.addItem(withTitle:"Choose a saved style…");presetPicker.addItems(withTitles:presets.map(\.name))
    }
    @objc private func presetChanged(_ sender:NSPopUpButton) {
        let index = sender.indexOfSelectedItem-1
        guard presets.indices.contains(index) else { return }
        change{$0.style = presets[index].style};loadBackground();canvas.fit()
    }
    private func savePreset() {
        guard let name = ask("Save frame preset",message:"Your background, inset, corners, shadow and canvas settings will be saved.",placeholder:"My style"),!name.trimmingCharacters(in:.whitespaces).isEmpty else { return }
        if let index = presets.firstIndex(where:{$0.name == name}) { presets[index].style = canvas.state.style }
        else { presets.append(StylePreset(name:name,style:canvas.state.style)) }
        do { try presetStore.save(presets);loadPresets();setStatus("Preset saved") } catch { showError(error) }
    }
    private func deletePreset() {
        let index = presetPicker.indexOfSelectedItem-1
        guard presets.indices.contains(index) else { setStatus("Choose a saved preset first");return }
        presets.remove(at:index)
        do { try presetStore.save(presets);loadPresets();setStatus("Preset deleted") } catch { showError(error) }
    }
    private func ask(_ title:String,message:String,placeholder:String) -> String? {
        let alert = NSAlert();alert.messageText = title;alert.informativeText = message
        let field = NSTextField(frame:CGRect(x:0,y:0,width:280,height:24));field.placeholderString = placeholder;alert.accessoryView = field
        alert.addButton(withTitle:"OK");alert.addButton(withTitle:"Cancel");alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func renderedImage() throws -> CGImage {
        canvas.finishText()
        return try CanvasRenderer.render(source:source,state:canvas.state,backgroundImage:canvas.backgroundImage)
    }
    func copyImage(original:Bool = false,forceClose:Bool = false) {
        do {
            let image:CGImage
            if original { image = source } else { image = try renderedImage() }
            let board = NSPasteboard.general
            board.clearContents()
            guard board.writeObjects([NSImage(cgImage:image,size:CGSize(width:image.width,height:image.height))]) else {
                setStatus("Clipboard is busy. Try copying again.",error:true);return
            }
            persistHistory();playSound();setStatus("Copied to clipboard")
            if forceClose || AppSettings.shared.closeAfterCopy { close() }
        } catch { showError(error) }
    }
    func saveImage(original:Bool = false) {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        canvas.finishText()
        let panel = NSSavePanel();panel.title = "Save screenshot";panel.canCreateDirectories = true;panel.isExtensionHidden = false
        panel.directoryURL = AppSettings.shared.directory
        let format = ExportAccessory(format:AppSettings.shared.jpegByDefault ? .jpeg : .png,quality:AppSettings.shared.quality)
        panel.accessoryView = format
        defer { format.onFormatChange = nil;panel.accessoryView = nil }
        func updateType() {
            panel.allowedContentTypes = [format.format == .png ? .png : .jpeg]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + (format.format == .png ? ".png" : ".jpg")
        }
        let formatter = DateFormatter();formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeName = AppSettings.shared.filename.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-")
        panel.nameFieldStringValue = "\(safeName.isEmpty ? "Screenshot" : safeName) \(formatter.string(from:Date()))"
        updateType();format.onFormatChange = updateType
        guard panel.runModal() == .OK,let url = panel.url else { setStatus("Save cancelled");return }
        do {
            let image:CGImage
            if original { image = source } else { image = try renderedImage() }
            let data = try ImageExporter.data(image:image,format:format.format,quality:format.quality)
            try data.write(to:url,options:.atomic)
            AppSettings.shared.directory = url.deletingLastPathComponent();AppSettings.shared.jpegByDefault = format.format == .jpeg;AppSettings.shared.quality = format.quality
            persistHistory();playSound();setStatus("Saved \(url.lastPathComponent)")
        } catch { showError(error) }
    }
    func shareScreenshot(_ sender:NSView) {
        do {
            let image = try renderedImage()
            let picker = NSSharingServicePicker(items:[NSImage(cgImage:image,size:.zero)])
            sharePicker = picker;picker.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)
        } catch { showError(error) }
    }
    func persistHistory() {
        guard AppSettings.shared.historyEnabled else { return }
        do {
            if let entry = historyEntry { try historyStore.update(entry,state:canvas.state) }
            else { historyEntry = try historyStore.save(image:source,state:canvas.state) }
        } catch { setStatus("History could not be saved: \(error.localizedDescription)",error:true) }
    }
    func recognizeText() {
        do {
            let image = try renderedImage()
            ocrButton.isEnabled = false;setStatus("Recognizing text on this Mac…")
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try TextRecognizer.recognize(image:image) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return };self.ocrButton.isEnabled = true
                    switch result {
                    case .success(let lines):self.showRecognizedText(lines.map(\.text).joined(separator:"\n"));self.setStatus("\(lines.count) text regions recognized")
                    case .failure(let error):self.showError(error)
                    }
                }
            }
        } catch { showError(error) }
    }
    private func showRecognizedText(_ text:String) {
        let panel = NSWindow(contentRect:CGRect(x:0,y:0,width:520,height:350),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = "Recognized text";panel.isReleasedWhenClosed = false
        let scroll = NSScrollView();scroll.hasVerticalScroller = true
        let view = NSTextView();view.isEditable = false;view.isSelectable = true;view.font = .systemFont(ofSize:14);view.textContainerInset = CGSize(width:18,height:18)
        view.string = text.isEmpty ? "No text was found. Try a larger or sharper image." : text
        scroll.documentView = view;panel.contentView = scroll
        infoWindow?.close();infoWindow = panel;panel.center();panel.makeKeyAndOrderFront(nil)
    }
    private func playSound() { if AppSettings.shared.sound { NSSound(named:"Pop")?.play() } }
    private func setStatus(_ text:String,error:Bool = false) { statusLabel.stringValue = text;statusLabel.textColor = error ? .systemRed : .secondaryLabelColor;statusLabel.toolTip = text }
    private func showError(_ error:Error) {
        setStatus(error.localizedDescription,error:true)
        let alert = NSAlert(error:error);if let window { alert.beginSheetModal(for:window) } else { alert.runModal() }
    }
    private func handleKey(_ event:NSEvent) -> Bool {
        if let responder = window?.firstResponder as? NSTextView,responder.isEditable { return false }
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "c":copyImage();return true
            case "s":saveImage();return true
            case "z":undoEdit();return true
            case "o":onOpen?();return true
            case "v":onPaste?();return true
            case "a":setTool(.select);return true
            case "+","=":canvas.changeZoom(1.2);return true
            case "-":canvas.changeZoom(1/1.2);return true
            case "0":canvas.fit();return true
            default:return false
            }
        }
        if flags == [.command,.shift],key == "z" { redoEdit();return true }
        guard flags.isEmpty else { return false }
        if event.keyCode == 51 || event.keyCode == 117 { canvas.deleteSelection();return true }
        if event.keyCode == 53 { canvas.finishText(cancel:true);setTool(.select);return true }
        if key == "c" { copyImage();return true };if key == "s" { saveImage();return true }
        let tools:[String:EditorTool] = ["v":.select,"d":.pen,"a":.arrow,"r":.rectangle,"e":.ellipse,"t":.text,"h":.highlighter,"b":.blur,"k":.redact,"n":.number,"x":.crop,"l":.line]
        if let tool = tools[key] { setTool(tool);return true }
        return false
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ExportAccessory: NSView {
    let picker = NSPopUpButton()
    let qualitySlider = NSSlider(value:0.92,minValue:0.1,maxValue:1,target:nil,action:nil)
    var onFormatChange: (() -> Void)?
    var format: ImageFormat { picker.indexOfSelectedItem == 0 ? .png : .jpeg }
    var quality: Double { qualitySlider.doubleValue }
    init(format:ImageFormat,quality:Double) {
        super.init(frame:CGRect(x:0,y:0,width:340,height:64))
        picker.addItems(withTitles:["PNG · Lossless, supports transparency","JPEG · Smaller file, white transparency"])
        picker.selectItem(at:format == .png ? 0 : 1);picker.target = self;picker.action = #selector(changed)
        qualitySlider.doubleValue = quality;qualitySlider.setAccessibilityLabel("JPEG quality")
        let stack = NSStackView(views:[picker,NSStackView(views:[Brand.label("JPEG quality"),qualitySlider])]);stack.orientation = .vertical;stack.spacing = 8
        addSubview(stack);stack.pin(to:self,inset:4)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func changed() { qualitySlider.isEnabled = format == .jpeg;onFormatChange?() }
}
