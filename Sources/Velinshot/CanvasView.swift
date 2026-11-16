import AppKit
import VelinshotCore

enum EditorTool: String, CaseIterable {
    case select, pen, arrow, rectangle, ellipse, text, highlighter, blur, redact, number, crop, line
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .blur: return "drop.halffull"
        case .redact: return "rectangle.fill"
        case .number: return "1.circle"
        case .crop: return "crop"
        case .line: return "line.diagonal"
        }
    }
    var title: String {
        switch self {
        case .select: return "Select and move (V)"
        case .pen: return "Draw (D)"
        case .arrow: return "Arrow (A)"
        case .rectangle: return "Rectangle (R)"
        case .ellipse: return "Ellipse (E)"
        case .text: return "Text (T)"
        case .highlighter: return "Highlight (H)"
        case .blur: return "Blur (B)"
        case .redact: return "Redact (K)"
        case .number: return "Number (N)"
        case .crop: return "Crop (X)"
        case .line: return "Line (L)"
        }
    }
    var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        default: return AnnotationKind(rawValue: rawValue)
        }
    }
}

final class CanvasView: NSView, NSTextFieldDelegate {
    static let renderQueue = DispatchQueue(label: "app.velinshot.preview", qos: .userInteractive)
    let source: CGImage
    var state: EditState { didSet { setAccessibilityValue("\(state.annotations.count) annotations");requestRender() } }
    var backgroundImage: CGImage? { didSet { requestRender() } }
    var tool: EditorTool = .select { didSet { if oldValue != tool { finishPointerGesture() };clearSelection(); window?.invalidateCursorRects(for: self) } }
    var annotationColor = RGBA(hex: "#F05A6E")
    var lineWidth: Double = 6
    var fontSize: Double = 36
    var onCommit: ((EditState, EditState) -> Void)?
    var onGestureEnd:(()->Void)?
    var onError: ((Error) -> Void)?
    var onImportURL: ((URL) -> Void)?
    var onImportData: ((Data) -> Void)?
    var onBackgroundDoubleClick:(() -> Void)?
    var onSelection:((Annotation?) -> Void)?
    var onKey:((NSEvent)->Bool)?
    var onTextEditingChange:((Bool)->Void)?
    private var preview: CGImage?
    private let previewSource:PreviewSourceCache
    private var renderScheduled = false
    private var renderInFlight = false
    private var renderTask: DispatchWorkItem?
    private var renderTicket: PreviewTicket?
    private var generation = 0
    private var selectedIndex: Int?
    private var gestureBefore: EditState?
    private var gestureStart: CGPoint?
    private var draftIndex: Int?
    private var cropDraft: CGRect?
    private var resizeCorner:Int?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private var textAnnotationIndex:Int?
    private var zoom: CGFloat = 1
    private var panOffset = CGPoint.zero

    init(source: CGImage, state: EditState, preparedPreview:ImagePreview? = nil) {
        self.source = source; self.state = state;self.previewSource = PreviewSourceCache(source:source,prepared:preparedPreview)
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot canvas")
        setAccessibilityValue("\(state.annotations.count) annotations")
        setAccessibilityHelp("Draw anywhere in the framed canvas. C copies. S saves. In Select, Tab and Shift-Tab cycle marks, including hidden marks. Delete removes the selected mark. Escape or tabbing past the last mark leaves the canvas.")
        requestRender()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    deinit { renderTicket?.cancel();renderTask?.cancel() }

    private var layout: RenderLayout? {
        try? CanvasRenderer.layout(sourceSize: CGSize(width: source.width, height: source.height), state: state)
    }
    private var displayRect: CGRect {
        guard let layout else { return bounds.insetBy(dx: 32, dy: 32) }
        let available = bounds.insetBy(dx: 32, dy: 32)
        let scale = min(available.width / layout.canvasSize.width, available.height / layout.canvasSize.height) * zoom
        let size = CGSize(width: layout.canvasSize.width * scale, height: layout.canvasSize.height * scale)
        return CGRect(x: bounds.midX-size.width/2+panOffset.x, y: bounds.midY-size.height/2+panOffset.y, width: size.width, height: size.height)
    }
    private func sourcePoint(_ point: CGPoint, clamp: Bool = true) -> CGPoint? {
        guard let layout else { return nil }
        let display = displayRect
        guard display.width > 0,display.height > 0 else { return nil }
        let canvas = CGPoint(x: (point.x-display.minX) / display.width * layout.canvasSize.width,
                             y: (point.y-display.minY) / display.height * layout.canvasSize.height)
        let source = layout.sourcePoint(forComposition:canvas)
        let limits = tool == .crop || tool == .blur ? layout.cropRect : layout.canvasBoundsInSource
        if !clamp,!limits.contains(source) { return nil }
        return CGPoint(x:max(limits.minX,min(limits.maxX,source.x)),y:max(limits.minY,min(limits.maxY,source.y)))
    }
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        guard let layout else { return .zero }
        let canvas = layout.compositionPoint(forSource:point)
        return CGPoint(x: displayRect.minX+canvas.x/layout.canvasSize.width*displayRect.width,
                       y: displayRect.minY+canvas.y/layout.canvasSize.height*displayRect.height)
    }
    private func viewRect(_ rect: CGRect) -> CGRect {
        let start = viewPoint(rect.origin), end = viewPoint(CGPoint(x: rect.maxX,y: rect.maxY))
        return CGRect(x: start.x, y: start.y, width: end.x-start.x, height: end.y-start.y)
    }
    private func requestRender() {
        generation += 1
        scheduleRender()
    }
    private func scheduleRender() {
        guard !renderScheduled,!renderInFlight else { return }
        renderScheduled = true
        // One pending frame and one in flight, rather than a queue of canceled
        // full-resolution renders. Pointer movement cannot starve live drawing.
        let task = DispatchWorkItem { [weak self] in self?.startRender() }
        renderTask = task;DispatchQueue.main.asyncAfter(deadline:.now()+0.008,execute:task)
    }
    private func startRender() {
        renderScheduled = false;renderInFlight = true
        let number = generation,state = state,background = backgroundImage,cache = previewSource
        let ticket = PreviewTicket();renderTicket = ticket
        Self.renderQueue.async { [weak self] in
            guard !ticket.isCancelled else { return }
            let result = autoreleasepool { Result { try cache.render(state:state,background:background) } }
            DispatchQueue.main.async { [weak self] in
                guard let self,!ticket.isCancelled else { return }
                self.renderInFlight = false
                switch result {
                case .success(let image):self.preview = image;self.needsDisplay = true
                case .failure(let error):if self.generation == number { self.onError?(error) }
                }
                if self.generation != number { self.scheduleRender() }
            }
        }
    }
    var hasActiveGesture:Bool { gestureBefore != nil || textField != nil }
    /// Finite native view export for documentation, with the same preview path.
    /// Normal editing uses the asynchronous scheduler above.
    func prepareDocumentationSnapshot() throws {
        let state = state,background = backgroundImage,cache = previewSource
        preview = try Self.renderQueue.sync { try cache.render(state:state,background:background) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        StudioPalette.surface.setFill()
        bounds.fill()
        StudioPalette.canvas.setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:10,dy:10),xRadius:14,yRadius:14).fill()
        if let preview {
            NSImage(cgImage: preview, size: .zero).draw(in: displayRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                                      hints: [.interpolation: NSImageInterpolation.high])
        } else {
            let text = "Preparing preview…" as NSString
            text.draw(at: CGPoint(x: bounds.midX-55,y: bounds.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 12),.foregroundColor:NSColor.secondaryLabelColor])
        }
        if let index = selectedIndex, state.annotations.indices.contains(index) {
            let rect = viewRect(annotationBounds(state.annotations[index])).insetBy(dx: -5, dy: -5)
            drawSelection(rect)
        }
        if let cropDraft { drawSelection(viewRect(cropDraft)) }
    }
    private func drawSelection(_ rect: CGRect) {
        Brand.iris.setStroke()
        let path = NSBezierPath(rect: rect); path.lineWidth = 1.5
        path.setLineDash([5,3],count:2,phase:0); path.stroke()
        for point in [rect.origin,CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)] {
            NSColor.white.setFill(); let handle = NSBezierPath(ovalIn: CGRect(x:point.x-3,y:point.y-3,width:6,height:6));handle.fill();Brand.iris.setStroke();handle.stroke()
        }
    }
    private func annotationBounds(_ annotation: Annotation) -> CGRect {
        guard let first = annotation.points.first else { return .zero }
        if annotation.kind == .text {
            let size = (annotation.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize,weight:.semibold)])
            return CGRect(origin: first, size: size)
        }
        if annotation.kind == .number { return CGRect(x:first.x-annotation.fontSize/2,y:first.y-annotation.fontSize/2,width:annotation.fontSize,height:annotation.fontSize) }
        let xs = annotation.points.map(\.x), ys = annotation.points.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y, width: max(1,(xs.max() ?? first.x)-(xs.min() ?? first.x)),height:max(1,(ys.max() ?? first.y)-(ys.min() ?? first.y))).insetBy(dx: -annotation.lineWidth/2,dy:-annotation.lineWidth/2)
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: tool == .select ? .arrow : .crosshair) }
    override func keyDown(with event:NSEvent) {
        if tool == .select,event.keyCode == 48 {
            finishText();finishPointerGesture()
            let backwards = event.modifierFlags.contains(.shift)
            let next = selectedIndex.map{$0 + (backwards ? -1 : 1)} ?? (backwards ? state.annotations.count-1 : 0)
            if state.annotations.indices.contains(next) {
                selectedIndex = next;onSelection?(state.annotations[next]);needsDisplay = true
                setAccessibilityValue("\(state.annotations.count) annotations; selected \(next+1), \(state.annotations[next].kind.rawValue)")
            } else {
                clearSelection()
                if backwards { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            }
            return
        }
        if tool == .select,event.keyCode == 53 { cancelPointerGesture();clearSelection();window?.makeFirstResponder(nil);return }
        if onKey?(event) != true { super.keyDown(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        finishText()
        window?.makeFirstResponder(self)
        let viewLocation = convert(event.locationInWindow,from:nil)
        if tool == .select,let index = selectedIndex,state.annotations.indices.contains(index) {
            let rect = viewRect(annotationBounds(state.annotations[index])).insetBy(dx:-5,dy:-5)
            let corners = [rect.origin,CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)]
            if let corner = corners.firstIndex(where:{hypot($0.x-viewLocation.x,$0.y-viewLocation.y)<=9}) {
                gestureBefore = state;gestureStart = sourcePoint(viewLocation);resizeCorner = corner;return
            }
        }
        guard let point = sourcePoint(viewLocation,clamp:false) else {
            if tool == .select,event.clickCount == 2 { onBackgroundDoubleClick?() }
            clearSelection();return
        }
        let hit = tool == .select ? state.annotations.indices.reversed().first { annotationBounds(state.annotations[$0]).insetBy(dx:-10,dy:-10).contains(point) } : nil
        if tool == .select,event.clickCount == 2,hit == nil,layout?.cropRect.contains(point) == false {
            onBackgroundDoubleClick?();return
        }
        gestureBefore = state; gestureStart = point; draftIndex = nil;resizeCorner = nil
        if tool == .select {
            selectedIndex = hit
            onSelection?(selectedIndex.map{state.annotations[$0]})
            if event.clickCount == 2,let index = selectedIndex,state.annotations[index].kind == .text,let origin = state.annotations[index].points.first { startText(at:origin,annotationIndex:index) }
            needsDisplay = true; return
        }
        if tool == .text { startText(at:point); return }
        if tool == .crop { cropDraft = CGRect(origin:point,size:.zero); return }
        guard let kind = tool.annotationKind else { return }
        var annotation = Annotation(kind:kind,points:[point,point],color:annotationColor,lineWidth:lineWidth,text:"",fontSize:fontSize)
        if kind == .number { annotation.text = String(state.annotations.filter{$0.kind == .number}.count+1) }
        state.annotations.append(annotation); draftIndex = state.annotations.count-1
    }
    override func mouseDragged(with event: NSEvent) {
        guard textField == nil else { return }
        guard let start = gestureStart, var point = sourcePoint(convert(event.locationInWindow,from:nil)) else { return }
        if tool == .select, let index = selectedIndex, let before = gestureBefore, before.annotations.indices.contains(index),state.annotations.indices.contains(index),state.annotations[index].id == before.annotations[index].id {
            if let corner = resizeCorner {
                let bounds = annotationBounds(before.annotations[index])
                let corners = [bounds.origin,CGPoint(x:bounds.maxX,y:bounds.minY),CGPoint(x:bounds.minX,y:bounds.maxY),CGPoint(x:bounds.maxX,y:bounds.maxY)]
                let anchor = corners[3-corner]
                let resized = CGRect(x:min(anchor.x,point.x),y:min(anchor.y,point.y),width:max(1,abs(point.x-anchor.x)),height:max(1,abs(point.y-anchor.y)))
                state.annotations[index] = AnnotationGeometry.resize(before.annotations[index],from:bounds,to:resized)
            } else { state.annotations[index].points = before.annotations[index].points.map { CGPoint(x:$0.x+point.x-start.x,y:$0.y+point.y-start.y) } }
        } else if tool == .crop {
            cropDraft = CGRect(x:min(start.x,point.x),y:min(start.y,point.y),width:abs(point.x-start.x),height:abs(point.y-start.y)); needsDisplay = true
        } else if let index = draftIndex,state.annotations.indices.contains(index),!state.annotations[index].points.isEmpty {
            if event.modifierFlags.contains(.shift) {
                let dx = point.x-start.x,dy = point.y-start.y
                if tool == .rectangle || tool == .ellipse {
                    let side = max(abs(dx),abs(dy));point = CGPoint(x:start.x+(dx<0 ? -side:side),y:start.y+(dy<0 ? -side:side))
                } else if tool == .arrow || tool == .line {
                    let angle = (atan2(dy,dx)/(.pi/4)).rounded()*(.pi/4),length = hypot(dx,dy)
                    point = CGPoint(x:start.x+cos(angle)*length,y:start.y+sin(angle)*length)
                }
                if let limits = layout?.canvasBoundsInSource {
                    let dx = point.x-start.x,dy = point.y-start.y
                    var fraction:CGFloat = 1
                    if dx>0 { fraction = min(fraction,(limits.maxX-start.x)/dx) }
                    if dx<0 { fraction = min(fraction,(limits.minX-start.x)/dx) }
                    if dy>0 { fraction = min(fraction,(limits.maxY-start.y)/dy) }
                    if dy<0 { fraction = min(fraction,(limits.minY-start.y)/dy) }
                    point = CGPoint(x:start.x+dx*max(0,fraction),y:start.y+dy*max(0,fraction))
                }
            }
            if tool == .pen || tool == .highlighter {
                if state.annotations[index].points.count < 20_000 { state.annotations[index].points.append(point) }
            } else { state.annotations[index].points[state.annotations[index].points.count-1] = point }
        }
    }
    override func mouseUp(with event: NSEvent) {
        finishPointerGesture()
    }
    func finishPointerGesture() {
        guard textField == nil,gestureBefore != nil else { return }
        if let crop = cropDraft,crop.width >= 4,crop.height >= 4 { state.crop = crop;state.style.autoBalance = false;fit() }
        if let index = draftIndex,state.annotations.indices.contains(index),state.annotations[index].kind != .number {
            let points = state.annotations[index].points
            if let first = points.first, let last = points.last, hypot(last.x-first.x,last.y-first.y)<1, state.annotations[index].kind != .pen {
                state.annotations.remove(at:index)
            }
        }
        completeGesture()
    }
    @discardableResult func cancelPointerGesture() -> Bool {
        guard textField == nil,let before = gestureBefore else { return false }
        state = before;completeGesture();return true
    }
    private func completeGesture() {
        if let before = gestureBefore, before != state { onCommit?(before,state) }
        gestureBefore = nil; gestureStart = nil; draftIndex = nil; cropDraft = nil;resizeCorner = nil; needsDisplay = true
        onGestureEnd?()
    }
    private func startText(at point: CGPoint,annotationIndex:Int? = nil) {
        onTextEditingChange?(true)
        textOrigin = point
        textAnnotationIndex = annotationIndex
        let position = viewPoint(point)
        let field = NSTextField(frame:CGRect(x:position.x,y:position.y,width:max(80,min(280,bounds.width-position.x-12)),height:32))
        field.font = .systemFont(ofSize:16,weight:.semibold)
        field.placeholderString = "Type, then press Return"
        field.delegate = self
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        if let annotationIndex { field.stringValue = state.annotations[annotationIndex].text }
        addSubview(field); textField = field; window?.makeFirstResponder(field)
    }
    func finishText(cancel: Bool = false) {
        guard let field = textField else { return }
        let text = field.stringValue
        let origin = textOrigin,index = textAnnotationIndex
        textField = nil;textOrigin = nil;textAnnotationIndex = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !cancel, let point = origin {
            if let index,state.annotations.indices.contains(index) {
                if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { state.annotations.remove(at:index) }
                else { state.annotations[index].text = text }
            } else if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                state.annotations.append(Annotation(kind:.text,points:[point],color:annotationColor,lineWidth:lineWidth,text:text,fontSize:fontSize))
            }
        }
        completeGesture();onTextEditingChange?(false)
    }
    func controlTextDidEndEditing(_ obj: Notification) { finishText() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishText();window?.makeFirstResponder(self);return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishText(cancel:true);window?.makeFirstResponder(self);return true }
        return false
    }
    func deleteSelection() {
        cancelPointerGesture()
        guard let index = selectedIndex, state.annotations.indices.contains(index) else { return }
        let before = state; state.annotations.remove(at:index);clearSelection();onCommit?(before,state)
    }
    func clearSelection() { selectedIndex = nil;onSelection?(nil);setAccessibilityValue("\(state.annotations.count) annotations");needsDisplay = true }
    func changeSelection(color:RGBA? = nil,lineWidth:Double? = nil,fontSize:Double? = nil) {
        guard let index = selectedIndex,state.annotations.indices.contains(index) else { return }
        let before = state
        if let color { state.annotations[index].color = color }
        if let lineWidth { state.annotations[index].lineWidth = lineWidth }
        if let fontSize { state.annotations[index].fontSize = fontSize }
        onCommit?(before,state)
    }
    func fit() { zoom = 1; panOffset = .zero;needsDisplay = true }
    func changeZoom(_ factor: CGFloat) { zoom = max(0.25,min(6,zoom*factor));needsDisplay = true }
    override func magnify(with event: NSEvent) { changeZoom(1+event.magnification) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { changeZoom(1+event.scrollingDeltaY*0.01) }
        else if zoom > 1 { panOffset.x -= event.scrollingDeltaX;panOffset.y -= event.scrollingDeltaY;needsDisplay = true }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL], let url = urls.first { onImportURL?(url);return true }
        if let data = board.data(forType:.png) ?? board.data(forType:.tiff) { onImportData?(data);return true }
        return false
    }
}

enum AnnotationGeometry {
    static func resize(_ annotation:Annotation,from old:CGRect,to rect:CGRect) -> Annotation {
        var changed = annotation
        let sx = rect.width/max(1,old.width),sy = rect.height/max(1,old.height)
        changed.points = annotation.points.map{CGPoint(x:rect.minX+($0.x-old.minX)*sx,y:rect.minY+($0.y-old.minY)*sy)}
        if annotation.kind == .text { changed.fontSize = min(512,max(2,annotation.fontSize*min(sx,sy)));changed.points = [rect.origin] }
        if annotation.kind == .number { changed.fontSize = min(512,max(2,min(rect.width,rect.height)));changed.points = [CGPoint(x:rect.midX,y:rect.midY)] }
        return changed
    }
}

private final class PreviewTicket {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled:Bool { lock.lock();defer{lock.unlock()};return cancelled }
    func cancel() { lock.lock();cancelled = true;lock.unlock() }
}

/// Accessed only by CanvasView.renderQueue; reduced source rasters are reused
/// through a document's entire editing session. Full source stays export-only.
private final class PreviewSourceCache {
    private let original:CGImage
    private var prepared:ImagePreview?
    private var backgroundOriginal:CGImage?
    private var backgroundPrepared:ImagePreview?
    init(source:CGImage,prepared:ImagePreview?) { original = source;self.prepared = prepared }
    func source() throws -> ImagePreview {
        if let prepared { return prepared }
        let preview = try ImageLoader.preview(image:original,maxDimension:1400);prepared = preview;return preview
    }
    func render(state:EditState,background image:CGImage?) throws -> CGImage {
        let proxy = try source()
        let layout = try CanvasRenderer.layout(sourceSize:proxy.sourceSize,state:state)
        let fullScale = state.style.fixedWidth.map{CGFloat($0)/layout.canvasSize.width} ?? CGFloat(state.style.outputScale)
        let rasterScale = min(fullScale,1400/max(layout.canvasSize.width,layout.canvasSize.height))
        let availableX = proxy.pixelSize.width/proxy.sourceSize.width,availableY = proxy.pixelSize.height/proxy.sourceSize.height
        if rasterScale > min(availableX,availableY)+0.000001 {
            // A tight crop needs more detail than the whole-image proxy holds.
            // The original is already decoded; crop that ROI instead of enlarging
            // a thumbnail or resampling the whole large source again.
            return try CanvasRenderer.render(source:original,state:state,backgroundImage:image,previewMaxDimension:1400)
        }
        return try CanvasRenderer.renderPreview(source:proxy,state:state,backgroundPreview:background(image),maximumDimension:1400)
    }
    func background(_ image:CGImage?) throws -> ImagePreview? {
        guard let image else { backgroundOriginal = nil;backgroundPrepared = nil;return nil }
        if backgroundOriginal === image { return backgroundPrepared }
        let preview = try ImageLoader.preview(image:image,maxDimension:1400)
        backgroundOriginal = image;backgroundPrepared = preview;return preview
    }
}
