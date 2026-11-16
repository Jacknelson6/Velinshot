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
    private let fieldUndo = UndoManager()
    private var textEditingActive = false
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var sliders: [String: NSSlider] = [:]
    private var valueLabels: [String: NSTextField] = [:]
    private var backgroundPicker = NSPopUpButton()
    private var ratioPicker = NSPopUpButton()
    private var scalePicker = NSPopUpButton()
    private var presetPicker = NSPopUpButton()
    private var inspectorPages:[NSView] = []
    private var inspectorTabs:NSSegmentedControl?
    private let inspectorHeading = Brand.label("Composition",size:15,weight:.semibold)
    private let markupDescription = Brand.label("Arrow",size:12,weight:.medium)
    private weak var inspectorScroll:NSScrollView?
    private weak var resetCropButton:NSButton?
    private var annotationWidth:NSSegmentedControl?
    private var annotationFont:NSPopUpButton?
    private weak var markupSection:NSView?
    private var undoButton:NSButton?
    private var redoButton:NSButton?
    private var firstColor = StudioColorWell()
    private var secondColor = StudioColorWell()
    private var insetColor = StudioColorWell()
    private var annotationColorWell = StudioColorWell()
    private var balanceCheck:NSButton!
    private var autoColorCheck:NSButton!
    private var autoInsetCheck:NSButton!
    private var watermarkField = NSTextField()
    private var watermarkPosition = NSPopUpButton()
    private var watermarkColor = StudioColorWell()
    private var sharePicker:NSSharingServicePicker?
    private var statusLabel = Brand.label("",size:11)
    private var dimensionsLabel = Brand.label("",size:11)
    private var ocrButton: NSButton!
    private var presets: [StylePreset] = []
    private let presetStore:PresetStore
    private let preferences:AppSettings
    private let supportDirectory:URL
    private var historyStore: HistoryStore { HistoryStore(directory: preferences.historyDirectory) }
    private var infoWindow: NSWindow?
    private var userIsClosing = false
    private var isSaving = false
    private var inspectorGestureBefore:EditState?
    private var watermarkGestureBefore:EditState?
    private var historyFailure:String?
    private var analysis:DocumentAnalysis
    private let analysisWork = LatestImageWork<DocumentAnalysis>()
    private var insetRefreshPending = false
    private var insetRefreshScheduled = false
    private var insetJobCrop:KnownContentBounds?
    private let backgroundWork = LatestImageWork<(CGImage,String)>()
    private var loadedBackgroundID:String?
    private var pendingBackgroundID:String?

    init(source: CGImage, state: EditState? = nil, title: String = "Screenshot", preparedPreview:ImagePreview? = nil, preparedAnalysis:DocumentAnalysis = DocumentAnalysis(), preferences:AppSettings = .shared, supportDirectory:URL = AppSettings.supportDirectory) {
        self.preferences = preferences;self.supportDirectory = supportDirectory
        self.analysis = preparedAnalysis
        self.presetStore = PresetStore(fileURL:supportDirectory.appendingPathComponent("presets.json"))
        self.source = source
        let initial:EditState
        if let state { initial = state }
        else { let prepared = NewDocument.prepare(source:source,style:preferences.style);initial = prepared.state;self.analysis = prepared.analysis }
        canvas = CanvasView(source:source,state:initial,preparedPreview:preparedPreview)
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
        canvas.onTextEditingChange = { [weak self] active in self?.textEditingActive = active;self?.fieldUndo.removeAllActions();if !active { self?.scheduleInsetRefresh() } }
        canvas.onSelection = { [weak self] annotation in
            guard let self else { return }
            self.updateInspectorContext(annotation)
            guard let annotation else { return }
            self.annotationColorWell.color = annotation.color.nsColor
            self.canvas.annotationColor = annotation.color;self.canvas.lineWidth = annotation.lineWidth;self.canvas.fontSize = annotation.fontSize
            self.annotationWidth?.selectedSegment = [3.0,6,12].firstIndex(of:annotation.lineWidth) ?? -1
            self.annotationFont?.selectItem(at:[24.0,36,48,72,96].firstIndex(of:annotation.fontSize) ?? 1)
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
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if textEditingActive || (window.firstResponder as? NSTextView)?.isEditable == true { return fieldUndo }
        return editorUndo
    }
    func windowWillClose(_ notification: Notification) {
        canvas.finishText();canvas.finishPointerGesture()
        persistHistory()
        userIsClosing = true
        analysisWork.cancel();backgroundWork.cancel()
        infoWindow?.close()
        onClose?()
    }
    func windowDidResignKey(_ notification:Notification) { canvas.finishPointerGesture() }
    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let header = StudioSurface();let content = NSView();let footer = StudioSurface()
        for view in [header,content,footer] { root.addSubview(view);view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:root.topAnchor),header.leadingAnchor.constraint(equalTo:root.leadingAnchor),header.trailingAnchor.constraint(equalTo:root.trailingAnchor),header.heightAnchor.constraint(equalToConstant:56),
            content.topAnchor.constraint(equalTo:header.bottomAnchor),content.leadingAnchor.constraint(equalTo:root.leadingAnchor),content.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            footer.topAnchor.constraint(equalTo:content.bottomAnchor),footer.bottomAnchor.constraint(equalTo:root.bottomAnchor),footer.leadingAnchor.constraint(equalTo:root.leadingAnchor),footer.trailingAnchor.constraint(equalTo:root.trailingAnchor),footer.heightAnchor.constraint(equalToConstant:58)
        ])
        let title = Brand.label("Velinshot",size:13,weight:.semibold)
        let documentTitle = Brand.label(window?.title ?? "Screenshot",size:10.5)
        documentTitle.textColor = .secondaryLabelColor;documentTitle.lineBreakMode = .byTruncatingMiddle
        documentTitle.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let titleGroup = NSStackView(views:[title,documentTitle]);titleGroup.orientation = .vertical;titleGroup.alignment = .leading;titleGroup.spacing = 1
        let icon = NSImageView(image:NSImage(named:NSImage.Name("AppIcon")) ?? Brand.symbol("viewfinder")!)
        icon.translatesAutoresizingMaskIntoConstraints = false;icon.widthAnchor.constraint(equalToConstant:27).isActive = true;icon.heightAnchor.constraint(equalToConstant:27).isActive = true
        let undo = StudioButton(symbol:"arrow.uturn.backward") { [weak self] in self?.undoEdit() };undo.toolTip = "Undo (⌘Z)";undoButton = undo
        let redo = StudioButton(symbol:"arrow.uturn.forward") { [weak self] in self?.redoEdit() };redo.toolTip = "Redo (⇧⌘Z)";redoButton = redo
        let fit = StudioButton("Fit",symbol:"arrow.up.left.and.arrow.down.right") { [weak self] in self?.canvas.fit() };fit.toolTip = "Fit to preview (⌘0)"
        ocrButton = StudioButton("Text",symbol:"text.viewfinder") { [weak self] in self?.recognizeText() };ocrButton.toolTip = "Select and copy image text"
        let capture = StudioButton("Capture",symbol:"viewfinder") { [weak self] in self?.onCapture?() };capture.toolTip = "New capture"
        let more = StudioButton(symbol:"ellipsis") {};more.actionHandler = { [weak self,weak more] in if let more { self?.showMore(more) } };more.toolTip = "Open, history and settings"
        let spacer = NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let headerStack = NSStackView(views:[icon,titleGroup,spacer,undo,redo,fit,ocrButton,capture,more]);headerStack.spacing = 7;headerStack.alignment = .centerY
        header.addSubview(headerStack);headerStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerStack.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:80),headerStack.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-14),headerStack.centerYAnchor.constraint(equalTo:header.centerYAnchor)])
        for button in [undo,redo,more] { button.widthAnchor.constraint(equalToConstant:34).isActive = true;button.setAccessibilityLabel(button.toolTip) }
        capture.setAccessibilityLabel("New capture");fit.setAccessibilityLabel("Fit image to preview");ocrButton.setAccessibilityLabel("Select and copy image text")

        let rail = StudioSurface()
        let inspector = buildInspector()
        for view in [rail,canvas,inspector] { content.addSubview(view);view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo:content.leadingAnchor),rail.topAnchor.constraint(equalTo:content.topAnchor),rail.bottomAnchor.constraint(equalTo:content.bottomAnchor),rail.widthAnchor.constraint(equalToConstant:58),
            inspector.trailingAnchor.constraint(equalTo:content.trailingAnchor),inspector.topAnchor.constraint(equalTo:content.topAnchor),inspector.bottomAnchor.constraint(equalTo:content.bottomAnchor),inspector.widthAnchor.constraint(equalToConstant:250),
            canvas.leadingAnchor.constraint(equalTo:rail.trailingAnchor),canvas.trailingAnchor.constraint(equalTo:inspector.leadingAnchor),canvas.topAnchor.constraint(equalTo:content.topAnchor),canvas.bottomAnchor.constraint(equalTo:content.bottomAnchor)
        ])
        let tools = NSStackView();tools.orientation = .vertical;tools.spacing = 3
        rail.addSubview(tools);tools.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tools.topAnchor.constraint(equalTo:rail.topAnchor,constant:12),tools.centerXAnchor.constraint(equalTo:rail.centerXAnchor)])
        let order:[EditorTool] = [.select,.pen,.arrow,.line,.rectangle,.ellipse,.text,.highlighter,.number,.blur,.redact,.crop]
        for tool in order {
            let button = StudioButton(symbol:tool.symbol,kind:.tool) { [weak self] in self?.setTool(tool) }
            button.toolTip = tool.title;button.setAccessibilityLabel(tool.title);button.setButtonType(.pushOnPushOff)
            button.widthAnchor.constraint(equalToConstant:38).isActive = true
            toolButtons[tool] = button;tools.addArrangedSubview(button)
        }
        setTool(.select)
        let copy = StudioButton("Copy",symbol:"doc.on.doc",kind:.primary,shortcut:"C") { [weak self] in self?.copyImage() };copy.setAccessibilityLabel("Copy screenshot");copy.toolTip = "Copy and close (C or ⌘C)"
        let save = StudioButton("Save",symbol:"square.and.arrow.down",kind:.secondary,shortcut:"S") { [weak self] in self?.saveImage() };save.setAccessibilityLabel("Save screenshot");save.toolTip = "Choose where to save (S or ⌘S)"
        let drag = DragExportButton();drag.imageProvider = { [weak self] in
            guard let self else { throw VelinshotError.renderingFailed };return try self.renderedImage()
        };drag.onError = { [weak self] in self?.showError($0) };drag.controlSize = .small
        let share = StudioButton(symbol:"square.and.arrow.up",kind:.footer) {}
        share.actionHandler = { [weak self,weak share] in if let share { self?.shareScreenshot(share) } };share.toolTip = "Share finished screenshot";share.setAccessibilityLabel("Share screenshot");share.widthAnchor.constraint(equalToConstant:36).isActive = true
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium);dimensionsLabel.textColor = .labelColor
        statusLabel.textColor = .secondaryLabelColor;statusLabel.lineBreakMode = .byTruncatingTail;statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let information = NSStackView(views:[dimensionsLabel,statusLabel]);information.orientation = .vertical;information.alignment = .leading;information.spacing = 3
        let footerSpacer = NSView();footerSpacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let bottom = NSStackView(views:[information,footerSpacer,drag,share,save,copy]);bottom.spacing = 10;bottom.alignment = .centerY
        footer.addSubview(bottom);bottom.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bottom.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:18),bottom.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-16),bottom.centerYAnchor.constraint(equalTo:footer.centerYAnchor),copy.widthAnchor.constraint(equalToConstant:110),save.widthAnchor.constraint(equalToConstant:110)])
    }
    private func showMore(_ sender:NSView) {
        let menu = NSMenu()
        let entries:[(String,Selector,String)] = [("Open Image…",#selector(requestOpen),"o"),("Open from Clipboard",#selector(requestPaste),"v"),("Screenshot History…",#selector(requestHistory),""),("Settings…",#selector(requestSettings),",")]
        for (title,action,key) in entries { let item = NSMenuItem(title:title,action:action,keyEquivalent:key);item.target = self;menu.addItem(item) }
        menu.popUp(positioning:nil,at:CGPoint(x:sender.bounds.maxX,y:sender.bounds.minY-5),in:sender)
    }
    @objc private func requestOpen() { onOpen?() }
    @objc private func requestPaste() { onPaste?() }
    @objc private func requestHistory() { onHistory?() }
    @objc private func requestSettings() { onSettings?() }
    private func buildInspector() -> NSView {
        let panel = StudioSurface()
        let heading = inspectorHeading
        let tabs = StudioSegments(labels:["Frame","Backdrop","Output"],trackingMode:.selectOne,target:self,action:#selector(inspectorTabChanged));tabs.selectedSegment = 0;tabs.segmentDistribution = .fillEqually;tabs.controlSize = .regular;tabs.setAccessibilityLabel("Inspector section")
        inspectorTabs = tabs
        let top = NSStackView(views:[heading,tabs]);top.orientation = .vertical;top.alignment = .leading;top.spacing = 10
        panel.addSubview(top);top.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.drawsBackground = false;scroll.borderType = .noBorder
        panel.addSubview(scroll);scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([top.leadingAnchor.constraint(equalTo:panel.leadingAnchor,constant:18),top.trailingAnchor.constraint(equalTo:panel.trailingAnchor,constant:-18),top.topAnchor.constraint(equalTo:panel.topAnchor,constant:16),tabs.widthAnchor.constraint(equalTo:top.widthAnchor),scroll.topAnchor.constraint(equalTo:top.bottomAnchor,constant:12),scroll.leadingAnchor.constraint(equalTo:panel.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:panel.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:panel.bottomAnchor)])
        let document = FlippedView();scroll.documentView = document;document.translatesAutoresizingMaskIntoConstraints = false;document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor).isActive = true
        let stack = NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 18;stack.detachesHiddenViews = true
        document.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-18),stack.topAnchor.constraint(equalTo:document.topAnchor,constant:2),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-20)])
        inspectorScroll = scroll
        func add(_ view:NSView,to group:NSStackView) { group.addArrangedSubview(view);view.translatesAutoresizingMaskIntoConstraints = false;view.widthAnchor.constraint(equalTo:group.widthAnchor).isActive = true }
        func group() -> NSStackView { let view = NSStackView();view.orientation = .vertical;view.alignment = .leading;view.spacing = 16;view.detachesHiddenViews = true;add(view,to:stack);return view }
        let frame = group(),backdrop = group(),output = group();frame.spacing = 10;inspectorPages = [frame,backdrop,output];backdrop.isHidden = true;output.isHidden = true
        add(sliderRow("Padding",key:"padding",min:0,max:240),to:frame)
        add(sliderRow("Inset",key:"inset",min:0,max:160),to:frame)
        insetColor.target = self;insetColor.action = #selector(insetColorChanged);insetColor.setAccessibilityLabel("Inset fill color")
        autoInsetCheck = CheckButton(title:"Auto",value:canvas.state.style.autoInsetColor) { [weak self] enabled in self?.setAutomaticInset(enabled) }
        autoInsetCheck.font = .systemFont(ofSize:11,weight:.medium);autoInsetCheck.controlSize = .small;autoInsetCheck.setAccessibilityLabel("Automatic inset fill")
        add(colorRow("Inset fill",well:insetColor,mode:autoInsetCheck),to:frame)
        add(sliderRow("Corners",key:"cornerRadius",min:0,max:100),to:frame)
        add(sliderRow("Shadow",key:"shadow",min:0,max:100),to:frame)
        add(sliderRow("Border",key:"borderWidth",min:0,max:12),to:frame)
        add(separator(),to:frame)
        balanceCheck = CheckButton(title:"Auto balance",value:canvas.state.style.autoBalance) { [weak self] enabled in self?.setAutomaticBalance(enabled) };add(balanceCheck,to:frame)
        let reset = StudioButton("Reset crop",symbol:"arrow.uturn.backward") { [weak self] in self?.change { $0.crop = nil;$0.style.autoBalance = false };self?.canvas.fit() };resetCropButton = reset;add(reset,to:frame)

        backgroundPicker.addItems(withTitles:["Gradient","Solid color","Image","Transparent"]);backgroundPicker.target = self;backgroundPicker.action = #selector(backgroundChanged);backgroundPicker.setAccessibilityLabel("Background type");add(backgroundPicker,to:backdrop)
        let swatches = NSStackView();swatches.spacing = 9
        let combinations = [("Iris","#B7AEF8","#E6E3FF"),("Peach","#F5AF98","#F9E4BD"),("Ocean","#92C6E9","#C4E4DC"),("Ink","#292B3E","#54517B"),("Paper","#F1EEE6","#FBFAF7")]
        for (name,c1,c2) in combinations {
            swatches.addArrangedSubview(GradientSwatch(name:name,first:RGBA(hex:c1).nsColor,second:RGBA(hex:c2).nsColor) { [weak self] in self?.change { $0.style.color1 = RGBA(hex:c1);$0.style.color2 = RGBA(hex:c2);$0.style.background = .gradient;$0.style.autoColor = false } })
        };add(swatches,to:backdrop)
        for well in [firstColor,secondColor] { well.target = self;well.action = #selector(colorsChanged) }
        firstColor.setAccessibilityLabel("First background color");secondColor.setAccessibilityLabel("Second background color")
        add(colorRow("First color",well:firstColor),to:backdrop);add(colorRow("Second color",well:secondColor),to:backdrop)
        add(sliderRow("Gradient angle",key:"gradientAngle",min:0,max:360),to:backdrop)
        add(separator(),to:backdrop)
        add(ActionButton(title:"Choose background image…",symbol:"photo") { [weak self] in self?.chooseBackground() },to:backdrop)
        add(ActionButton(title:"Use desktop wallpaper",symbol:"desktopcomputer") { [weak self] in self?.useDesktopBackground() },to:backdrop)
        autoColorCheck = CheckButton(title:"Match image colors",value:canvas.state.style.autoColor) { [weak self] enabled in self?.setAutomaticColors(enabled) };add(autoColorCheck,to:backdrop)
        add(ActionButton(title:"Balance & match",symbol:"wand.and.stars") { [weak self] in self?.autoBeautify() },to:backdrop)

        add(Brand.label("CANVAS",size:10,weight:.semibold),to:output)
        ratioPicker.addItems(withTitles:Self.ratios.map{$0.0}+["Custom ratio or size…"]+Self.sizes.map{$0.0});ratioPicker.target = self;ratioPicker.action = #selector(ratioChanged);ratioPicker.setAccessibilityLabel("Canvas aspect ratio");add(ratioPicker,to:output)
        scalePicker.addItems(withTitles:["1×  Original pixels","2×  Double pixels","½×  Smaller image","Set output width…"]);scalePicker.target = self;scalePicker.action = #selector(scaleChanged);scalePicker.setAccessibilityLabel("Output scale");add(scalePicker,to:output)
        add(separator(),to:output);add(Brand.label("WATERMARK",size:10,weight:.semibold),to:output)
        watermarkField.placeholderString = "Optional text";watermarkField.delegate = self;watermarkField.isBezeled = false;watermarkField.drawsBackground = false;watermarkField.setAccessibilityLabel("Optional watermark text")
        let watermarkInput = StudioSurface();watermarkInput.fill = StudioPalette.field;watermarkInput.wantsLayer = true;watermarkInput.layer?.cornerRadius = 6;watermarkInput.layer?.masksToBounds = true
        watermarkInput.addSubview(watermarkField);watermarkField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([watermarkInput.heightAnchor.constraint(equalToConstant:28),watermarkField.leadingAnchor.constraint(equalTo:watermarkInput.leadingAnchor,constant:8),watermarkField.trailingAnchor.constraint(equalTo:watermarkInput.trailingAnchor,constant:-8),watermarkField.centerYAnchor.constraint(equalTo:watermarkInput.centerYAnchor)])
        add(watermarkInput,to:output)
        watermarkPosition.addItems(withTitles:["Top left","Top right","Bottom left","Bottom right"]);watermarkPosition.target = self;watermarkPosition.action = #selector(watermarkPositionChanged);watermarkPosition.setAccessibilityLabel("Watermark position");add(watermarkPosition,to:output)
        watermarkColor.target = self;watermarkColor.action = #selector(watermarkColorChanged);watermarkColor.setAccessibilityLabel("Watermark color");add(colorRow("Text color",well:watermarkColor),to:output)
        add(separator(),to:output);add(Brand.label("SAVED STYLES",size:10,weight:.semibold),to:output)
        presetPicker.target = self;presetPicker.action = #selector(presetChanged);presetPicker.setAccessibilityLabel("Saved frame preset");add(presetPicker,to:output)
        add(ActionButton(title:"Save current style…",symbol:"plus") { [weak self] in self?.savePreset() },to:output)
        add(ActionButton(title:"Delete selected preset",symbol:"minus") { [weak self] in self?.deletePreset() },to:output)

        let annotation = NSStackView();annotation.orientation = .vertical;annotation.alignment = .leading;annotation.spacing = 18;annotation.detachesHiddenViews = true
        add(markupDescription,to:annotation)
        annotationColorWell.color = canvas.annotationColor.nsColor;annotationColorWell.target = self;annotationColorWell.action = #selector(annotationColorChanged);annotationColorWell.setAccessibilityLabel("Annotation color");add(colorRow("Color",well:annotationColorWell),to:annotation)
        let width = StudioSegments(labels:["Thin","Medium","Bold"],trackingMode:.selectOne,target:self,action:#selector(widthChanged));width.selectedSegment = 1;width.segmentDistribution = .fillEqually;width.setAccessibilityLabel("Annotation stroke width");annotationWidth = width;add(width,to:annotation)
        let fonts = NSPopUpButton();fonts.addItems(withTitles:["Text 24 px","Text 36 px","Text 48 px","Text 72 px","Text 96 px"]);fonts.selectItem(at:1);fonts.target = self;fonts.action = #selector(fontChanged);fonts.setAccessibilityLabel("Annotation text size");annotationFont = fonts;add(fonts,to:annotation)
        add(StudioButton("Back to composition",symbol:"arrow.left") { [weak self] in self?.setTool(.select) },to:annotation)
        add(annotation,to:stack);stack.removeArrangedSubview(annotation);stack.insertArrangedSubview(annotation,at:0)
        markupSection = annotation;annotation.isHidden = true
        return panel
    }
    private func colorRow(_ title:String,well:NSColorWell,mode:NSButton? = nil) -> NSView {
        well.controlSize = .small;well.colorWellStyle = .minimal
        well.widthAnchor.constraint(equalToConstant:100).isActive = true;well.heightAnchor.constraint(equalToConstant:30).isActive = true
        let row = NSStackView(views:[Brand.label(title),NSView()]);if let mode { row.addArrangedSubview(mode) };row.addArrangedSubview(well)
        row.spacing = mode == nil ? 8 : 4;row.alignment = .centerY;return row
    }
    @objc private func inspectorTabChanged(_ tabs:NSSegmentedControl) {
        window?.makeFirstResponder(canvas)
        for (index,page) in inspectorPages.enumerated() { page.isHidden = index != tabs.selectedSegment }
        if let scroll = inspectorScroll { scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView) }
    }
    func showInspectorSection(_ index:Int) {
        guard (0..<inspectorPages.count).contains(index),let tabs = inspectorTabs else { return }
        setTool(.select)
        tabs.selectedSegment = index;inspectorTabChanged(tabs)
    }
    var frameControlsFit:Bool {
        guard let button = resetCropButton,let clip = inspectorScroll?.contentView,!button.isHiddenOrHasHiddenAncestor else { return false }
        return clip.bounds.contains(clip.convert(button.bounds,from:button))
    }
    private func separator() -> NSView { let space = NSView();space.heightAnchor.constraint(equalToConstant:4).isActive = true;return space }
    private func sliderRow(_ title:String,key:String,min:Double,max:Double) -> NSView {
        let label = Brand.label(title)
        let value = Brand.label("",size:11);value.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);value.textColor = .secondaryLabelColor
        let spacer = NSView();let top = NSStackView(views:[label,spacer,value]);top.distribution = .fill;top.alignment = .centerY
        let slider = GestureSlider(value:0,minValue:min,maxValue:max,target:self,action:#selector(sliderChanged));slider.identifier = .init(key);slider.isContinuous = true;slider.setAccessibilityLabel(title)
        slider.onBegin = { [weak self] in self?.canvas.finishText();self?.inspectorGestureBefore = self?.canvas.state }
        slider.onEnd = { [weak self] in
            guard let self,let before = self.inspectorGestureBefore else { return }
            self.inspectorGestureBefore = nil;self.commit(before:before,after:self.canvas.state)
        }
        sliders[key] = slider;valueLabels[key] = value
        let group = NSStackView(views:[top,slider]);group.orientation = .vertical;group.spacing = 5;group.alignment = .leading
        top.widthAnchor.constraint(equalTo:group.widthAnchor).isActive = true;slider.widthAnchor.constraint(equalTo:group.widthAnchor).isActive = true
        return group
    }
    func setTool(_ tool:EditorTool) {
        canvas.finishText();canvas.finishPointerGesture();canvas.tool = tool
        updateInspectorContext(nil)
        if let scroll = inspectorScroll { scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView) }
        for (kind,button) in toolButtons {
            button.state = kind == tool ? .on : .off
            button.needsDisplay = true
        }
        window?.makeFirstResponder(canvas)
        setStatus(tool.title)
    }
    private func updateInspectorContext(_ annotation:Annotation?) {
        let active = annotation != nil || ![.select,.crop].contains(canvas.tool)
        markupSection?.isHidden = !active;inspectorTabs?.isHidden = active
        inspectorHeading.stringValue = active ? "Markup" : "Composition"
        let index = inspectorTabs?.selectedSegment ?? 0
        for (pageIndex,page) in inspectorPages.enumerated() { page.isHidden = active || pageIndex != index }
        let kind = annotation?.kind ?? canvas.tool.annotationKind
        markupDescription.stringValue = kind?.rawValue.capitalized ?? canvas.tool.rawValue.capitalized
        annotationFont?.isHidden = kind != .text && kind != .number
        annotationWidth?.isHidden = kind == .text || kind == .number || kind == .redact
    }
    private func commit(before:EditState,after:EditState) {
        guard before != after else { return }
        editorUndo.registerUndo(withTarget:self) { target in target.restore(before) }
        editorUndo.setActionName("Edit screenshot")
        storeStyle(after.style,previous:before.style)
        syncInspector()
        updateInsetRequest(before:before,after:after)
    }
    private func restore(_ state:EditState) {
        cancelAnalysis()
        let previous = canvas.state
        var restored = state
        if restored.style.autoInsetColor,analysis.insetCrop == restored.crop,let color = analysis.insetColor { restored.style.insetColor = color }
        editorUndo.registerUndo(withTarget:self) { target in target.restore(previous) }
        canvas.state = restored;storeStyle(restored.style,previous:previous.style);canvas.clearSelection();loadBackground();syncInspector()
        updateInsetRequest(before:previous,after:restored)
    }
    private func change(_ mutation:(inout EditState)->Void) {
        canvas.finishText();canvas.finishPointerGesture()
        let before = canvas.state;var after = before;mutation(&after)
        do { _ = try CanvasRenderer.layout(sourceSize:CGSize(width:source.width,height:source.height),state:after) }
        catch { setStatus(error.localizedDescription,error:true);return }
        canvas.state = after
        if inspectorGestureBefore == nil && watermarkGestureBefore == nil { commit(before:before,after:after) } else { syncInspector() }
    }
    private func storeStyle(_ style:CanvasStyle,previous:CanvasStyle) {
        let automatic = preferences.autoInsetFill
        var stored = style
        if !automatic,style.autoInsetColor,style.autoInsetColor == previous.autoInsetColor {
            stored.insetColor = preferences.style.insetColor
        }
        preferences.style = stored
        if style.autoInsetColor == previous.autoInsetColor { preferences.autoInsetFill = automatic }
    }
    func undoEdit() { canvas.finishText();if !canvas.cancelPointerGesture() { editorUndo.undo() };syncInspector() }
    func redoEdit() { canvas.finishText();if !canvas.cancelPointerGesture() { editorUndo.redo() };syncInspector() }
    private func syncInspector() {
        let style = canvas.state.style
        undoButton?.isEnabled = editorUndo.canUndo;redoButton?.isEnabled = editorUndo.canRedo
        let values = ["padding":style.padding,"inset":style.inset,"cornerRadius":style.cornerRadius,"shadow":style.shadow,"borderWidth":style.borderWidth,"gradientAngle":style.gradientAngle]
        for (key,value) in values { sliders[key]?.doubleValue = value;valueLabels[key]?.stringValue = "\(Int(value))\(key == "gradientAngle" ? "°" : " px")" }
        backgroundPicker.selectItem(at:[BackgroundKind.gradient,.solid,.image,.transparent].firstIndex(of:style.background) ?? 0)
        firstColor.color = style.color1.nsColor;secondColor.color = style.color2.nsColor
        insetColor.color = style.insetColor.nsColor;balanceCheck?.state = style.autoBalance ? .on : .off;autoColorCheck?.state = style.autoColor ? .on : .off
        autoInsetCheck?.state = style.autoInsetColor ? .on : .off
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
    @objc private func insetColorChanged(_ sender:NSColorWell) {
        cancelAnalysis();insetRefreshPending = false;preferences.autoInsetFill = false
        change{$0.style.insetColor = RGBA(sender.color);$0.style.autoInsetColor = false}
    }
    @objc private func annotationColorChanged(_ sender:NSColorWell) { canvas.annotationColor = RGBA(sender.color);canvas.changeSelection(color:canvas.annotationColor) }
    @objc private func widthChanged(_ sender:NSSegmentedControl) { canvas.lineWidth = [3.0,6,12][sender.selectedSegment];canvas.changeSelection(lineWidth:canvas.lineWidth) }
    @objc private func fontChanged(_ sender:NSPopUpButton) { canvas.fontSize = [24.0,36,48,72,96][sender.indexOfSelectedItem];canvas.changeSelection(fontSize:canvas.fontSize) }
    @objc private func watermarkPositionChanged(_ sender:NSPopUpButton) { change{$0.style.watermarkPosition = WatermarkPosition.allCases[sender.indexOfSelectedItem]} }
    @objc private func watermarkColorChanged(_ sender:NSColorWell) { change{$0.style.watermarkColor = RGBA(sender.color)} }
    func controlTextDidChange(_ notification:Notification) {
        guard notification.object as? NSTextField === watermarkField else { return }
        let text = String(watermarkField.stringValue.prefix(512));change{$0.style.watermarkText = text}
    }
    func controlTextDidBeginEditing(_ notification:Notification) {
        guard notification.object as? NSTextField === watermarkField else { return }
        watermarkGestureBefore = canvas.state;textEditingActive = true;fieldUndo.removeAllActions()
    }
    func controlTextDidEndEditing(_ notification:Notification) {
        guard notification.object as? NSTextField === watermarkField else { return }
        textEditingActive = false;fieldUndo.removeAllActions()
        if let before = watermarkGestureBefore { watermarkGestureBefore = nil;commit(before:before,after:canvas.state) }
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
    private func setAutomaticBalance(_ enabled:Bool) {
        if enabled { requestAnalysis(balance:true,colors:false) }
        else { cancelAnalysis();change{$0.style.autoBalance = false;$0.crop = nil};canvas.fit() }
    }
    private func setAutomaticColors(_ enabled:Bool) {
        if enabled { requestAnalysis(balance:false,colors:true) }
        else { cancelAnalysis();change{$0.style.autoColor = false} }
    }
    private func cancelAnalysis() { analysisWork.cancel();insetJobCrop = nil }
    private func setAutomaticInset(_ enabled:Bool) {
        cancelAnalysis();insetRefreshPending = enabled;preferences.autoInsetFill = enabled
        change{$0.style.autoInsetColor = enabled};scheduleInsetRefresh()
    }
    private func updateInsetRequest(before:EditState,after:EditState) {
        if !after.style.autoInsetColor { insetRefreshPending = false;return }
        if before.crop != after.crop || !before.style.autoInsetColor || before.style.insetColor != after.style.insetColor { insetRefreshPending = true }
        scheduleInsetRefresh()
    }
    private func scheduleInsetRefresh() {
        guard insetRefreshPending,!insetRefreshScheduled,!userIsClosing else { return }
        insetRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return };self.insetRefreshScheduled = false;self.refreshInsetIfReady()
        }
    }
    private func refreshInsetIfReady() {
        guard insetRefreshPending,!userIsClosing,canvas.state.style.autoInsetColor else { return }
        guard !canvas.hasActiveGesture,inspectorGestureBefore == nil,watermarkGestureBefore == nil else { return }
        let crop = canvas.state.crop
        if analysis.insetCrop == crop,let color = analysis.insetColor {
            insetRefreshPending = false
            if canvas.state.style.insetColor != color {
                var updated = canvas.state;updated.style.insetColor = color
                canvas.state = updated;storeStyle(updated.style,previous:updated.style);syncInspector()
            }
            return
        }
        if let pending = insetJobCrop,pending.bounds == crop { return }
        let source = source,cached = analysis
        insetJobCrop = KnownContentBounds(bounds:crop)
        analysisWork.submit(work:{ ticket in
            try ticket.checkpoint();var value = cached
            value.insetColor = AutoBeautify.suggestInsetColor(source:source,crop:crop);value.insetCrop = crop
            return value
        }) { [weak self] result in
            guard let self,!self.userIsClosing else { return };self.insetJobCrop = nil
            switch result {
            case .success(let value):
                self.analysis.insetColor = value.insetColor;self.analysis.insetCrop = value.insetCrop
                guard self.canvas.state.style.autoInsetColor,self.canvas.state.crop == crop else { return }
                self.insetRefreshPending = true;self.scheduleInsetRefresh()
            case .failure(let error):self.insetRefreshPending = false;self.showError(error)
            }
        }
    }
    private func autoBeautify() { requestAnalysis(balance:true,colors:true) }
    private func requestAnalysis(balance:Bool,colors:Bool) {
        window?.makeFirstResponder(canvas);canvas.finishText()
        let before = canvas.state,source = source,cached = analysis
        insetJobCrop = nil
        setStatus(balance ? "Balancing your image…" : "Matching image colors…")
        analysisWork.submit(work:{ ticket in
            var result = cached
            if balance,result.bounds == nil { result.bounds = KnownContentBounds(bounds:AutoBeautify.contentBounds(source:source)) }
            try ticket.checkpoint()
            if colors,result.colors == nil { result.colors = AutoBeautify.suggestColors(source:source) }
            if balance,before.style.autoInsetColor {
                let crop = result.bounds?.bounds
                if result.insetColor == nil || result.insetCrop != crop { result.insetColor = AutoBeautify.suggestInsetColor(source:source,crop:crop);result.insetCrop = crop }
            }
            return result
        }) { [weak self] result in
            guard let self,!self.userIsClosing else { return }
            switch result {
            case .success(let value):
                self.analysis = value
                guard self.canInstallAnalysis(for:before) else { self.syncInspector();self.setStatus("Image changed. Choose balance again when ready.");return }
                self.change {
                    if balance { $0.crop = value.bounds?.bounds;$0.style.autoBalance = true }
                    if colors,let pair = value.colors { $0.style.color1 = pair.0;$0.style.color2 = pair.1;$0.style.background = .gradient;$0.style.autoColor = true }
                    if balance,$0.style.autoInsetColor,let color = value.insetColor { $0.style.insetColor = color }
                }
                self.canvas.fit();self.setStatus(balance && colors ? "Balanced and matched to your image" : balance ? "Image balanced" : "Colors matched")
            case .failure(let error):self.syncInspector();self.showError(error)
            }
        }
    }
    func canInstallAnalysis(for state:EditState) -> Bool {
        canvas.state == state && !canvas.hasActiveGesture && inspectorGestureBefore == nil && watermarkGestureBefore == nil && !userIsClosing
    }
    private func chooseBackground() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.image];panel.canChooseDirectories = false
        guard panel.runModal() == .OK,let url = panel.url else { return }
        setBackground(url:url)
    }
    private func setBackground(url:URL,wallpaper:Bool = false) {
        let directory = supportDirectory.appendingPathComponent("Backgrounds",isDirectory:true),before = canvas.state.style
        setStatus("Opening background…")
        pendingBackgroundID = nil
        backgroundWork.submit(work:{ ticket in
            let image = try ImageLoader.open(url:url).fullResolution();try ticket.checkpoint()
            let data = try ImageExporter.data(image:image,format:.png);try ticket.checkpoint()
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let id = UUID().uuidString;try data.write(to:directory.appendingPathComponent(id+".png"),options:.atomic)
            return (image,id)
        }) { [weak self] result in
            guard let self,!self.userIsClosing,self.canvas.state.style == before else { return }
            switch result {
            case .success(let (image,id)):
                self.loadedBackgroundID = id
                self.change{$0.style.background = .image;$0.style.backgroundAssetID = id;$0.style.autoColor = false};self.canvas.backgroundImage = image;self.setStatus("Background ready")
            case .failure(let error):
                if wallpaper { self.change{$0.style.background = .gradient};self.setStatus("Wallpaper unavailable. Using the gradient; choose an image instead.",error:true) }
                else { self.showError(error) }
            }
        }
    }
    private func useDesktopBackground() {
        guard let screen = window?.screen ?? NSScreen.main,let url = NSWorkspace.shared.desktopImageURL(for:screen),!url.hasDirectoryPath else {
            change{$0.style.background = .gradient};setStatus("Wallpaper unavailable. Choose a background image instead.",error:true);return
        }
        setBackground(url:url,wallpaper:true)
    }
    private func loadBackground() {
        guard let id = canvas.state.style.backgroundAssetID,UUID(uuidString:id) != nil else {
            backgroundWork.cancel();pendingBackgroundID = nil;loadedBackgroundID = nil
            if canvas.backgroundImage != nil { canvas.backgroundImage = nil };return
        }
        if loadedBackgroundID == id,canvas.backgroundImage != nil { return }
        if pendingBackgroundID == id,backgroundWork.isBusy { return }
        let url = supportDirectory.appendingPathComponent("Backgrounds",isDirectory:true).appendingPathComponent(id+".png")
        pendingBackgroundID = id
        backgroundWork.submit(work:{ _ in (try ImageLoader.open(url:url).fullResolution(),id) }) { [weak self] result in
            guard let self,!self.userIsClosing,self.canvas.state.style.backgroundAssetID == id else { return }
            self.pendingBackgroundID = nil
            switch result {
            case .success(let (image,id)):self.loadedBackgroundID = id;self.canvas.backgroundImage = image
            case .failure:self.loadedBackgroundID = nil;self.canvas.backgroundImage = nil;self.setStatus("Background image is missing. Choose it again.",error:true)
            }
        }
    }
    private func loadPresets() {
        do { presets = try presetStore.load() }
        catch { presets = [];setStatus("Could not read presets: \(error.localizedDescription)",error:true) }
        presetPicker.removeAllItems();presetPicker.addItem(withTitle:"Choose a saved style…");presetPicker.addItems(withTitles:presets.map(\.name))
    }
    @objc private func presetChanged(_ sender:NSPopUpButton) {
        let index = sender.indexOfSelectedItem-1
        guard presets.indices.contains(index) else { return }
        preferences.autoInsetFill = presets[index].style.autoInsetColor
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
        window?.makeFirstResponder(canvas)
        canvas.finishText();canvas.finishPointerGesture()
        return try CanvasRenderer.render(source:source,state:canvas.state,backgroundImage:canvas.backgroundImage)
    }
    func copyImage(original:Bool = false,forceClose:Bool = false) {
        canvas.finishText();canvas.finishPointerGesture()
        do {
            let image:CGImage
            if original { image = source } else { image = try renderedImage() }
            let board = NSPasteboard.general
            board.clearContents()
            guard board.writeObjects([NSImage(cgImage:image,size:CGSize(width:image.width,height:image.height))]) else {
                setStatus("Clipboard is busy. Try copying again.",error:true);return
            }
            let historyOK = persistHistory();playSound()
            if !historyOK { setStatus("Copied. History not saved: \(historyFailure ?? "Choose another history folder in Settings.")",error:true);return }
            setStatus("Copied to clipboard")
            if forceClose || preferences.closeAfterCopy { close() }
        } catch { showError(error) }
    }
    func saveImage(original:Bool = false) {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        canvas.finishText();canvas.finishPointerGesture()
        let panel = NSSavePanel();panel.title = "Save screenshot";panel.canCreateDirectories = true;panel.isExtensionHidden = false;panel.allowsOtherFileTypes = false
        panel.directoryURL = preferences.directory
        let format = ExportAccessory(format:preferences.jpegByDefault ? .jpeg : .png,quality:preferences.quality)
        panel.accessoryView = format
        defer { format.onFormatChange = nil;panel.accessoryView = nil }
        func updateType() {
            panel.allowedContentTypes = [format.format == .png ? .png : .jpeg]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + (format.format == .png ? ".png" : ".jpg")
        }
        let formatter = DateFormatter();formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeName = preferences.filename.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-")
        panel.nameFieldStringValue = "\(safeName.isEmpty ? "Screenshot" : safeName) \(formatter.string(from:Date()))"
        updateType();format.onFormatChange = updateType
        guard panel.runModal() == .OK,let url = panel.url else { setStatus("Save cancelled");return }
        do {
            let image:CGImage
            if original { image = source } else { image = try renderedImage() }
            let savedFormat = ExportAccessory.encoding(for:url,selected:format.format)
            let data = try ImageExporter.data(image:image,format:savedFormat,quality:format.quality)
            try data.write(to:url,options:.atomic)
            preferences.directory = url.deletingLastPathComponent();preferences.jpegByDefault = savedFormat == .jpeg;preferences.quality = format.quality
            let historyOK = persistHistory();playSound()
            setStatus(historyOK ? "Saved \(url.lastPathComponent)" : "Saved file. History not saved: \(historyFailure ?? "Choose another folder in Settings.")",error:!historyOK)
        } catch { showError(error) }
    }
    func shareScreenshot(_ sender:NSView) {
        do {
            let image = try renderedImage()
            let picker = NSSharingServicePicker(items:[NSImage(cgImage:image,size:.zero)])
            sharePicker = picker;picker.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)
        } catch { showError(error) }
    }
    @discardableResult func persistHistory() -> Bool {
        historyFailure = nil
        guard preferences.historyEnabled else { return true }
        do {
            if let entry = historyEntry { try historyStore.update(entry,state:canvas.state) }
            else { historyEntry = try historyStore.save(image:source,state:canvas.state) }
            return true
        } catch { historyFailure = error.localizedDescription;setStatus("History could not be saved: \(error.localizedDescription)",error:true);return false }
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
    private func playSound() { if preferences.sound { NSSound(named:"Pop")?.play() } }
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
            case "1","2","3":if let index = Int(key) { showInspectorSection(index-1) };return true
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

final class GestureSlider:NSSlider {
    var onBegin:(()->Void)?
    var onEnd:(()->Void)?
    override func mouseDown(with event:NSEvent) { onBegin?();defer{onEnd?()};super.mouseDown(with:event) }
}

final class ExportAccessory: NSView {
    let picker:NSSegmentedControl
    let qualitySlider = NSSlider(value:0.92,minValue:0.1,maxValue:1,target:nil,action:nil)
    var onFormatChange: (() -> Void)?
    var format: ImageFormat { picker.selectedSegment == 1 ? .jpeg : .png }
    var quality: Double { qualitySlider.doubleValue }
    static func encoding(for destination:URL,selected:ImageFormat) -> ImageFormat {
        switch destination.pathExtension.lowercased() {
        case "png":return .png
        case "jpg","jpeg":return .jpeg
        default:return selected
        }
    }
    init(format:ImageFormat,quality:Double) {
        picker = NSSegmentedControl(labels:["PNG · Lossless","JPEG · Smaller"],trackingMode:.selectOne,target:nil,action:nil)
        super.init(frame:CGRect(x:0,y:0,width:340,height:64))
        picker.selectedSegment = format == .png ? 0 : 1;picker.segmentDistribution = .fillEqually;picker.target = self;picker.action = #selector(changed);picker.setAccessibilityLabel("Export format")
        qualitySlider.doubleValue = quality;qualitySlider.setAccessibilityLabel("JPEG quality")
        qualitySlider.isEnabled = format == .jpeg
        let stack = NSStackView(views:[picker,NSStackView(views:[Brand.label("JPEG quality"),qualitySlider])]);stack.orientation = .vertical;stack.spacing = 8
        addSubview(stack);stack.pin(to:self,inset:4)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func changed() { qualitySlider.isEnabled = format == .jpeg;onFormatChange?() }
}
