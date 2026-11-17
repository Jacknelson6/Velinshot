import AppKit
import ScreenCaptureKit
import CoreGraphics
import VelinshotCore

enum CaptureFailure: LocalizedError {
    case permission, noDisplay, tooLarge, cancelled, displayChanged
    var errorDescription: String? {
        switch self {
        case .permission: return "macOS has not authorized this copy of Velinshot. If access already looks enabled, remove its entry from Screen & System Audio Recording, add this app again, and enable it. Restart Velinshot after changing access."
        case .noDisplay: return "macOS could not capture every selected display. Reconnect your displays and try again."
        case .tooLarge: return "That capture is too large. Select a smaller area (up to 40 megapixels)."
        case .cancelled: return nil
        case .displayChanged: return "Your display setup changed during capture. Start a new capture to use the current displays."
        }
    }
}

/// A token fences late ScreenCaptureKit results after cancellation or a new capture.
struct CaptureSession {
    enum Stage { case idle, preparing, selecting, finishing }
    private(set) var stage: Stage = .idle
    private(set) var id: UUID?
    mutating func begin() -> UUID? {
        guard stage == .idle else { return nil }
        let token = UUID(); id = token; stage = .preparing
        return token
    }
    mutating func ready(_ token: UUID) -> Bool {
        guard id == token, stage == .preparing else { return false }
        stage = .selecting; return true
    }
    mutating func commit(_ token: UUID) -> Bool {
        guard id == token, stage == .selecting else { return false }
        stage = .finishing; return true
    }
    mutating func end(_ token: UUID) -> Bool {
        guard id == token else { return false }
        id = nil; stage = .idle; return true
    }
}

final class CaptureController {
    enum Mode { case area, display }
    private var session = CaptureSession()
    private var mode: Mode = .area
    private var content: SCShareableContent?
    private var overlays: [CaptureOverlayWindow] = []
    private var previousWindows: [NSWindow] = []
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var operation: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var cursorOwned = false
    private var displays: [CaptureGeometry.Display] = []
    private var primaryMaxY: CGFloat = 0
    private var start: CGPoint?
    private var pointerDown = false
    fileprivate private(set) var pointer = CGPoint.zero
    private var windowMode = false
    private var selectedWindow: SCWindow?
    private var zOrder: [CGWindowID: Int] = [:]
    var isCapturing: Bool { session.id != nil }

    func begin(_ mode: Mode = .area, completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard NSApp.modalWindow == nil else { NSSound.beep(); return }
        guard let token = session.begin() else { return }
        self.mode = mode; self.completion = completion
        start = nil; pointerDown = false; pointer = NSEvent.mouseLocation; selectedWindow = nil; windowMode = false
        let screens = NSScreen.screens
        displays = Self.geometry(for: screens)
        primaryMaxY = screens.first?.frame.maxY ?? 0
        previousWindows = AppSettings.shared.hideDuringCapture ? NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is CaptureOverlayWindow)
        } : []
        previousWindows.forEach { $0.orderOut(nil) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish(.failure(CaptureFailure.displayChanged), token: token)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        operation = Task { @MainActor in
            do {
                guard !screens.isEmpty, displays.count == screens.count else { throw CaptureFailure.noDisplay }
                if !CGPreflightScreenCaptureAccess() {
                    guard CGRequestScreenCaptureAccess() else { throw CaptureFailure.permission }
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard session.id == token, !Task.isCancelled else { return }
                guard displays == Self.geometry(for: NSScreen.screens) else { throw CaptureFailure.displayChanged }
                guard displays.allSatisfy({ screen in content.displays.contains { $0.displayID == screen.id } }) else {
                    throw CaptureFailure.noDisplay
                }
                self.content = content
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                zOrder = Dictionary(uniqueKeysWithValues: windows.enumerated().compactMap { index, info in
                    guard let number = info[kCGWindowNumber as String] as? UInt32 else { return nil }
                    return (number, index)
                })
                guard session.ready(token) else { return }
                showOverlays(screens: screens)
            } catch { finish(.failure(error), token: token) }
        }
    }
    private static func geometry(for screens: [NSScreen]) -> [CaptureGeometry.Display] {
        screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return CaptureGeometry.Display(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }
    private func showOverlays(screens: [NSScreen]) {
        pointer = NSEvent.mouseLocation
        for screen in screens {
            let window = CaptureOverlayWindow(frame: screen.frame, displayName: screen.localizedName, controller: self)
            overlays.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        focusOverlay(at: pointer)
        NSCursor.crosshair.push(); cursorOwned = true
        mouseMoved(to: pointer)
    }
    fileprivate var selection: CGRect? {
        if mode == .display { return displays.first(where: { $0.frame.contains(pointer) })?.frame }
        if windowMode, let selectedWindow { return CaptureGeometry.cocoaRect(selectedWindow.frame, primaryMaxY: primaryMaxY) }
        guard let start else { return nil }
        return CaptureGeometry.selection(from: start, to: pointer)
    }
    fileprivate var isWindowMode: Bool { windowMode }
    fileprivate var isDisplayMode: Bool { mode == .display }
    fileprivate func mouseDown(at point: CGPoint) {
        guard session.stage == .selecting else { return }
        pointerDown = true
        mouseMoved(to: point)
        if mode == .area, !windowMode { start = point }
        update()
    }
    fileprivate func mouseMoved(to point: CGPoint) {
        guard session.stage == .selecting else { return }
        pointer = point
        if start == nil { focusOverlay(at: point) }
        if windowMode, let content {
            let quartz = CaptureGeometry.quartzPoint(point, primaryMaxY: primaryMaxY)
            selectedWindow = content.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20 && $0.frame.contains(quartz)
            }.min(by: { (zOrder[$0.windowID] ?? Int.max) < (zOrder[$1.windowID] ?? Int.max) })
        }
        update()
    }
    private func focusOverlay(at point: CGPoint) {
        guard let overlay = overlays.first(where: { $0.frame.contains(point) }), !overlay.isKeyWindow else { return }
        overlay.makeKey(); overlay.makeFirstResponder(overlay.contentView)
    }
    fileprivate func toggleWindow() {
        guard mode == .area, session.stage == .selecting else { return }
        windowMode.toggle(); start = nil; pointerDown = false; selectedWindow = nil
        mouseMoved(to: pointer)
    }
    fileprivate func mouseUp(at point: CGPoint) {
        guard let token = session.id, session.stage == .selecting, pointerDown else { return }
        pointerDown = false
        mouseMoved(to: point)
        let selected = selectedWindow
        guard let rect = selection, rect.width >= 2, rect.height >= 2, session.commit(token) else { return }
        let captureWindow = windowMode
        hideOverlays()
        operation = Task { @MainActor in
            do {
                let image: CGImage
                if captureWindow, let selected { image = try await capture(window: selected, token: token) }
                else { image = try await capture(rect: rect, token: token) }
                finish(.success(image), token: token)
            } catch { finish(.failure(error), token: token) }
        }
    }
    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        guard isCapturing else { return false }
        if event.keyCode == 53 { cancel(); return true }
        if event.keyCode == 49, session.stage == .selecting, mode == .area { toggleWindow(); return true }
        return false
    }
    fileprivate func cancel() {
        guard let token = session.id else { return }
        finish(.failure(CaptureFailure.cancelled), token: token)
    }
    private func update() { overlays.forEach { $0.contentView?.needsDisplay = true } }
    private func hideOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        if cursorOwned { NSCursor.pop(); cursorOwned = false }
    }
    private func finish(_ result: Result<CGImage, Error>, token: UUID) {
        guard session.end(token) else { return }
        operation?.cancel(); operation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        hideOverlays()
        overlays.forEach { $0.close() }; overlays.removeAll()
        previousWindows.forEach { $0.orderFront(nil) }; previousWindows.removeAll()
        content = nil; displays.removeAll(); start = nil; pointerDown = false; selectedWindow = nil
        let callback = completion; completion = nil
        callback?(result)
    }
    private func capture(window: SCWindow, token: UUID) async throws -> CGImage {
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
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard session.id == token, !Task.isCancelled else { throw CaptureFailure.cancelled }
        return image
    }
    private func capture(rect: CGRect, token: UUID) async throws -> CGImage {
        guard let content else { throw CaptureFailure.noDisplay }
        let plan: CaptureGeometry.Plan
        do { plan = try CaptureGeometry.plan(rect: rect, displays: displays) }
        catch CaptureGeometry.Failure.tooLarge { throw CaptureFailure.tooLarge }
        catch { throw CaptureFailure.noDisplay }
        // A missing display must fail before an allocation or a partial export.
        guard plan.parts.allSatisfy({ part in content.displays.contains { $0.displayID == part.displayID } }) else {
            throw CaptureFailure.noDisplay
        }
        guard let bitmap = CGContext(data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.tooLarge }
        let excluded = AppSettings.shared.hideDuringCapture ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
        for part in plan.parts {
            guard session.id == token, !Task.isCancelled else { throw CaptureFailure.cancelled }
            guard let display = content.displays.first(where: { $0.displayID == part.displayID }) else { throw CaptureFailure.noDisplay }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = part.sourceRect
            config.width = part.width; config.height = part.height
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard session.id == token, !Task.isCancelled else { throw CaptureFailure.cancelled }
            bitmap.draw(image, in: part.destinationRect)
        }
        guard let image = bitmap.makeImage() else { throw CaptureFailure.noDisplay }
        return image
    }
    private func validate(width: Int, height: Int) throws {
        guard width <= 16384, height <= 16384, width * height <= 40_000_000 else { throw CaptureFailure.tooLarge }
    }
}

final class CaptureOverlayWindow: NSWindow {
    init(frame: CGRect, displayName: String, controller: CaptureController) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        acceptsMouseMovedEvents = true
        contentView = CaptureOverlayView(displayFrame: frame, displayName: displayName, controller: controller)
        isReleasedWhenClosed = false
        setFrame(frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureOverlayView: NSView {
    unowned let controller: CaptureController
    private let displayFrame: CGRect
    private let displayName: String
    init(displayFrame: CGRect, displayName: String, controller: CaptureController) {
        self.displayFrame = displayFrame; self.displayName = displayName; self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        setAccessibilityLabel("Capture on \(displayName)")
        setAccessibilityHelp(controller.isDisplayMode ? "Click the display you want to capture. Escape cancels." : "Drag an area on any display. Space switches to window capture. Escape cancels.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    // Every display overlay must receive the initial click, even while another is key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let active = displayFrame.contains(controller.pointer)
        NSColor.black.withAlphaComponent(active ? 0.20 : 0.34).setFill()
        NSBezierPath(rect: bounds).fill()
        if let global = controller.selection, let window {
            let local = window.convertFromScreen(global)
            NSGraphicsContext.current?.cgContext.clear(local)
            Brand.iris.setStroke()
            let path = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1)); path.lineWidth = 2; path.stroke()
            if !controller.isWindowMode, !controller.isDisplayMode {
                drawPill("\(Int(global.width)) × \(Int(global.height)) pt", at: CGPoint(x: local.minX, y: max(62, local.minY - 36)))
            }
        }
        if active, !controller.isWindowMode, !controller.isDisplayMode, let window {
            let point = window.convertPoint(fromScreen: controller.pointer)
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let crosshair = NSBezierPath(); crosshair.lineWidth = 0.5
            crosshair.move(to: CGPoint(x: point.x, y: 0)); crosshair.line(to: CGPoint(x: point.x, y: bounds.height))
            crosshair.move(to: CGPoint(x: 0, y: point.y)); crosshair.line(to: CGPoint(x: bounds.width, y: point.y)); crosshair.stroke()
        }
        drawPill(displayName + (active ? " · Ready to capture" : " · Move here to capture"), at: CGPoint(x: bounds.midX, y: bounds.height - 50), centered: true)
        let help: String
        if controller.isDisplayMode { help = "Click to capture this display · Esc to cancel" }
        else if controller.isWindowMode { help = "Click a window · Space for area · Esc to cancel" }
        else { help = "Drag on any display · Space for window · Esc to cancel" }
        drawPill(help, at: CGPoint(x: bounds.midX, y: 24), centered: true)
    }
    private func drawPill(_ text: String, at point: CGPoint, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let width = min((text as NSString).size(withAttributes: attributes).width + 24, max(32, bounds.width - 32))
        let x = max(16, min(centered ? point.x - width / 2 : point.x, bounds.width - width - 16))
        let rect = CGRect(x: x, y: min(max(16, point.y), max(16, bounds.height - 46)), width: width, height: 30)
        Brand.ink.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(in: rect.insetBy(dx: 12, dy: 7), withAttributes: attributes)
    }
    private func screenPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        controller.mouseDown(at: screenPoint(for: event))
    }
    override func mouseDragged(with event: NSEvent) { controller.mouseMoved(to: screenPoint(for: event)) }
    override func mouseMoved(with event: NSEvent) { controller.mouseMoved(to: screenPoint(for: event)) }
    override func mouseEntered(with event: NSEvent) { controller.mouseMoved(to: screenPoint(for: event)) }
    override func mouseUp(with event: NSEvent) { controller.mouseUp(at: screenPoint(for: event)) }
    override func keyDown(with event: NSEvent) { if !controller.handleKey(event) { super.keyDown(with: event) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
}
