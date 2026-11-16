import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureFailure: LocalizedError {
    case permission, noDisplay, tooLarge, cancelled
    var errorDescription: String? {
        switch self {
        case .permission: return "macOS has not authorized this copy of Velinshot. If access already looks enabled, remove its entry from Screen & System Audio Recording, add this app again, and enable it. Restart Velinshot after changing access."
        case .noDisplay: return "No display was available to capture. Connect a display and try again."
        case .tooLarge: return "That capture is too large. Select a smaller area (up to 40 megapixels)."
        case .cancelled: return nil
        }
    }
}

final class CaptureController {
    enum Mode { case area, display }
    private var content: SCShareableContent?
    private var overlays: [CaptureOverlayWindow] = []
    private var previousWindows: [NSWindow] = []
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var windowMode = false
    private var selectedWindow: SCWindow?
    private var zOrder: [CGWindowID: Int] = [:]
    private(set) var isCapturing = false

    func begin(_ mode: Mode = .area, completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard NSApp.modalWindow == nil else { NSSound.beep();return }
        guard !isCapturing else { return }
        isCapturing = true
        self.completion = completion
        previousWindows = AppSettings.shared.hideDuringCapture ? NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is CaptureOverlayWindow) } : []
        previousWindows.forEach { $0.orderOut(nil) }
        Task { @MainActor in
            do {
                if !CGPreflightScreenCaptureAccess() {
                    guard CGRequestScreenCaptureAccess() else { throw CaptureFailure.permission }
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                self.content = content
                guard !content.displays.isEmpty else { throw CaptureFailure.noDisplay }
                if mode == .display {
                    let pointer = NSEvent.mouseLocation
                    let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
                    let frame = screen?.frame ?? NSScreen.screens[0].frame
                    let image = try await capture(rect: frame)
                    finish(.success(image)); return
                }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                zOrder = Dictionary(uniqueKeysWithValues: windows.enumerated().compactMap { index, info in
                    guard let number = info[kCGWindowNumber as String] as? UInt32 else { return nil }
                    return (number, index)
                })
                showOverlays()
            } catch { finish(.failure(error)) }
        }
    }
    private func showOverlays() {
        start = nil; current = nil; selectedWindow = nil; windowMode = false
        for screen in NSScreen.screens {
            let window = CaptureOverlayWindow(screen: screen, controller: self)
            overlays.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let focused = overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { focused.makeKey() }
        NSCursor.crosshair.push()
    }
    fileprivate var selection: CGRect? {
        if windowMode, let selectedWindow { return cocoaRect(selectedWindow.frame) }
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x-start.x), height: abs(current.y-start.y))
    }
    fileprivate var isWindowMode: Bool { windowMode }
    fileprivate func mouseDown() {
        if !windowMode { start = NSEvent.mouseLocation; current = start }
        update()
    }
    fileprivate func mouseMoved() {
        current = NSEvent.mouseLocation
        if windowMode, let content {
            let pointer = quartzPoint(NSEvent.mouseLocation)
            selectedWindow = content.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20 && $0.frame.contains(pointer)
            }.min(by: { (zOrder[$0.windowID] ?? Int.max) < (zOrder[$1.windowID] ?? Int.max) })
        }
        update()
    }
    fileprivate func toggleWindow() {
        windowMode.toggle(); start = nil; current = nil
        mouseMoved()
    }
    fileprivate func mouseUp() {
        let window = selectedWindow
        guard let rect = selection, rect.width >= 2, rect.height >= 2 else { return }
        overlays.forEach { $0.orderOut(nil) }
        NSCursor.pop()
        Task { @MainActor in
            do {
                let image: CGImage
                if windowMode, let window { image = try await capture(window: window) }
                else { image = try await capture(rect: rect) }
                finish(.success(image))
            } catch { finish(.failure(error)) }
        }
    }
    fileprivate func cancel() {
        if !overlays.isEmpty { NSCursor.pop() }
        finish(.failure(CaptureFailure.cancelled))
    }
    private func update() { overlays.forEach { $0.contentView?.needsDisplay = true } }
    private func finish(_ result: Result<CGImage, Error>) {
        overlays.forEach { $0.close() }; overlays.removeAll()
        previousWindows.forEach { $0.orderFront(nil) }; previousWindows.removeAll()
        content = nil; isCapturing = false
        let callback = completion; completion = nil
        callback?(result)
    }
    private func quartzPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }
    private func cocoaRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }
    private func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        try validate(width: config.width, height: config.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    private func capture(rect: CGRect) async throws -> CGImage {
        guard let content else { throw CaptureFailure.noDisplay }
        let screens = NSScreen.screens
        let scale = screens.filter { $0.frame.intersects(rect) }.map(\.backingScaleFactor).max() ?? 1
        let width = max(1, Int((rect.width * scale).rounded()))
        let height = max(1, Int((rect.height * scale).rounded()))
        try validate(width: width, height: height)
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.tooLarge }
        for screen in screens {
            let part = screen.frame.intersection(rect)
            guard !part.isNull, part.width >= 1, part.height >= 1,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let excluded = AppSettings.shared.hideDuringCapture ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: part.minX-screen.frame.minX, y: screen.frame.maxY-part.maxY, width: part.width, height: part.height)
            config.width = max(1, Int((part.width * scale).rounded()))
            config.height = max(1, Int((part.height * scale).rounded()))
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            bitmap.draw(image, in: CGRect(x: (part.minX-rect.minX)*scale, y: (part.minY-rect.minY)*scale,
                                         width: part.width*scale, height: part.height*scale))
        }
        guard let image = bitmap.makeImage() else { throw CaptureFailure.noDisplay }
        return image
    }
    private func validate(width: Int, height: Int) throws {
        guard width <= 16384, height <= 16384, width * height <= 40_000_000 else { throw CaptureFailure.tooLarge }
    }
}

private final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen, controller: CaptureController) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        acceptsMouseMovedEvents = true
        contentView = CaptureOverlayView(controller: controller)
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class CaptureOverlayView: NSView {
    unowned let controller: CaptureController
    init(controller: CaptureController) { self.controller = controller; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(rect: bounds).fill()
        if let global = controller.selection, let window {
            let local = window.convertFromScreen(global)
            NSGraphicsContext.current?.cgContext.clear(local)
            Brand.iris.setStroke()
            let path = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 2; path.stroke()
            if !controller.isWindowMode {
                let dimensions = "\(Int(global.width)) × \(Int(global.height)) pt"
                drawPill(dimensions, at: CGPoint(x: max(16,min(local.minX,bounds.width-180)), y: max(62,local.minY-34)))
            }
        }
        drawPill(controller.isWindowMode ? "Click a window · Space for area · Esc to cancel" : "Drag an area · Space for window · Esc to cancel",
                 at: CGPoint(x: max(20, bounds.midX-195), y: 24))
    }
    private func drawPill(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(origin: point, size: CGSize(width: size.width+24, height: 30))
        Brand.ink.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: CGPoint(x: point.x+12,y: point.y+8), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); controller.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller.mouseMoved() }
    override func mouseMoved(with event: NSEvent) { controller.mouseMoved() }
    override func mouseUp(with event: NSEvent) { controller.mouseUp() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller.cancel() }
        else if event.keyCode == 49 { controller.toggleWindow() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways,.mouseMoved,.inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
}
