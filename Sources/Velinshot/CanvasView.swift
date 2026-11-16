import AppKit
import VelinshotCore

enum EditorTool: String, CaseIterable {
    case select, pen, arrow, rectangle, ellipse, text, highlighter, blur, redact, number, crop, line
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
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
    var tool: EditorTool = .select { didSet { clearSelection(); window?.invalidateCursorRects(for: self) } }
    var annotationColor = RGBA(hex: "#F05A6E")
    var lineWidth: Double = 6
    var fontSize: Double = 36
    var onCommit: ((EditState, EditState) -> Void)?
    var onError: ((Error) -> Void)?
    var onImportURL: ((URL) -> Void)?
    var onImportData: ((Data) -> Void)?
    var onBackgroundDoubleClick:(() -> Void)?
    var onSelection:((Annotation?) -> Void)?
    var onKey:((NSEvent)->Bool)?
    var onTextEditingChange:((Bool)->Void)?
    private var preview: CGImage?
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

    init(source: CGImage, state: EditState) {
        self.source = source; self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot canvas")
        setAccessibilityValue("\(state.annotations.count) annotations")
        setAccessibilityHelp("Choose a drawing tool, then drag on the screenshot. C copies. S saves. Delete removes a selected annotation.")
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
        let canvas = CGPoint(x: (point.x-display.minX) / display.width * layout.canvasSize.width,
                             y: (point.y-display.minY) / display.height * layout.canvasSize.height)
        if !clamp, !layout.imageRect.contains(canvas) { return nil }
        let x = (canvas.x-layout.imageRect.minX) / layout.imageRect.width * layout.cropRect.width + layout.cropRect.minX
        let y = (canvas.y-layout.imageRect.minY) / layout.imageRect.height * layout.cropRect.height + layout.cropRect.minY
        return CGPoint(x: max(layout.cropRect.minX,min(layout.cropRect.maxX,x)), y: max(layout.cropRect.minY,min(layout.cropRect.maxY,y)))
    }
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        guard let layout else { return .zero }
        let canvas = CGPoint(x: layout.imageRect.minX + (point.x-layout.cropRect.minX)/layout.cropRect.width * layout.imageRect.width,
                             y: layout.imageRect.minY + (point.y-layout.cropRect.minY)/layout.cropRect.height * layout.imageRect.height)
        return CGPoint(x: displayRect.minX+canvas.x/layout.canvasSize.width*displayRect.width,
                       y: displayRect.minY+canvas.y/layout.canvasSize.height*displayRect.height)
    }
    private func viewRect(_ rect: CGRect) -> CGRect {
        let start = viewPoint(rect.origin), end = viewPoint(CGPoint(x: rect.maxX,y: rect.maxY))
        return CGRect(x: start.x, y: start.y, width: end.x-start.x, height: end.y-start.y)
    }
    private func requestRender() {
        generation += 1
        let number = generation
        renderTask?.cancel()
        renderTicket?.cancel()
        let ticket = PreviewTicket();renderTicket = ticket
        let image = source, state = state, background = backgroundImage
        let task = DispatchWorkItem { [weak self] in
            guard !ticket.isCancelled else { return }
            do {
                let result = try CanvasRenderer.render(source: image, state: state, backgroundImage: background, previewMaxDimension: 1400)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == number else { return }
                    self.preview = result; self.needsDisplay = true
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == number else { return }
                    self.onError?(error)
                }
            }
        }
        renderTask = task
        Self.renderQueue.asyncAfter(deadline: .now()+0.012, execute: task)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
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
    override func keyDown(with event:NSEvent) { if onKey?(event) != true { super.keyDown(with:event) } }
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
        if event.clickCount == 2,sourcePoint(viewLocation,clamp:false) == nil { onBackgroundDoubleClick?();return }
        guard let point = sourcePoint(viewLocation,clamp:false) else { selectedIndex = nil; needsDisplay = true; return }
        gestureBefore = state; gestureStart = point; draftIndex = nil;resizeCorner = nil
        if tool == .select {
            let tolerance: CGFloat = 10
            selectedIndex = state.annotations.indices.reversed().first { annotationBounds(state.annotations[$0]).insetBy(dx:-tolerance,dy:-tolerance).contains(point) }
            onSelection?(selectedIndex.map{state.annotations[$0]})
            if event.clickCount == 2,let index = selectedIndex,state.annotations[index].kind == .text { startText(at:state.annotations[index].points[0],annotationIndex:index) }
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
        if tool == .select, let index = selectedIndex, let before = gestureBefore, before.annotations.indices.contains(index) {
            if let corner = resizeCorner {
                let bounds = annotationBounds(before.annotations[index])
                let corners = [bounds.origin,CGPoint(x:bounds.maxX,y:bounds.minY),CGPoint(x:bounds.minX,y:bounds.maxY),CGPoint(x:bounds.maxX,y:bounds.maxY)]
                let anchor = corners[3-corner]
                let resized = CGRect(x:min(anchor.x,point.x),y:min(anchor.y,point.y),width:max(1,abs(point.x-anchor.x)),height:max(1,abs(point.y-anchor.y)))
                state.annotations[index] = AnnotationGeometry.resize(before.annotations[index],from:bounds,to:resized)
            } else { state.annotations[index].points = before.annotations[index].points.map { CGPoint(x:$0.x+point.x-start.x,y:$0.y+point.y-start.y) } }
        } else if tool == .crop {
            cropDraft = CGRect(x:min(start.x,point.x),y:min(start.y,point.y),width:abs(point.x-start.x),height:abs(point.y-start.y)); needsDisplay = true
        } else if let index = draftIndex {
            if event.modifierFlags.contains(.shift) {
                let dx = point.x-start.x,dy = point.y-start.y
                if tool == .rectangle || tool == .ellipse {
                    let side = max(abs(dx),abs(dy));point = CGPoint(x:start.x+(dx<0 ? -side:side),y:start.y+(dy<0 ? -side:side))
                } else if tool == .arrow || tool == .line {
                    let angle = (atan2(dy,dx)/(.pi/4)).rounded()*(.pi/4),length = hypot(dx,dy)
                    point = CGPoint(x:start.x+cos(angle)*length,y:start.y+sin(angle)*length)
                }
            }
            if tool == .pen || tool == .highlighter {
                if state.annotations[index].points.count < 20_000 { state.annotations[index].points.append(point) }
            } else { state.annotations[index].points[state.annotations[index].points.count-1] = point }
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard textField == nil else { return }
        guard tool != .text else { return }
        if tool == .crop, let crop = cropDraft, crop.width >= 4, crop.height >= 4 { state.crop = crop;state.style.autoBalance = false; fit() }
        if let index = draftIndex, tool != .number {
            let points = state.annotations[index].points
            if let first = points.first, let last = points.last, hypot(last.x-first.x,last.y-first.y)<1, tool != .pen {
                state.annotations.remove(at:index)
            }
        }
        completeGesture()
    }
    private func completeGesture() {
        if let before = gestureBefore, before != state { onCommit?(before,state) }
        gestureBefore = nil; gestureStart = nil; draftIndex = nil; cropDraft = nil;resizeCorner = nil; needsDisplay = true
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
        guard let index = selectedIndex, state.annotations.indices.contains(index) else { return }
        let before = state; state.annotations.remove(at:index);clearSelection();onCommit?(before,state)
    }
    func clearSelection() { selectedIndex = nil;onSelection?(nil);needsDisplay = true }
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
