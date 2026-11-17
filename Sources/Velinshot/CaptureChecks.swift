import AppKit
import VelinshotCore

enum CaptureChecks {
    /// Hidden native overlays and session state only. Never requests screen access.
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VelinshotError.invalidImage("Capture check failed: \(message)") }
            count += 1
        }
        // The old overlay inherited this false default, swallowing the first click on another screen.
        try check(!NSView().acceptsFirstMouse(for: nil), "diagnostic confirms native first-click activation default")
        let controller = CaptureController()
        for frame in [CGRect(x: 0, y: 0, width: 800, height: 600),
                      CGRect(x: -1440, y: 120, width: 1440, height: 900),
                      CGRect(x: 0, y: 1107, width: 1440, height: 900)] {
            let window = CaptureOverlayWindow(frame: frame, displayName: "Synthetic display", controller: controller)
            defer { window.close() }
            guard let view = window.contentView as? CaptureOverlayView else { throw VelinshotError.renderingFailed }
            try check(window.frame == frame, "overlay keeps exact global frame at \(frame.origin)")
            try check(!window.isVisible && !window.isKeyWindow, "geometry validation never fronts an overlay")
            try check(view.acceptsFirstMouse(for: nil), "inactive display overlay receives the first selection click")
            try check(view.acceptsFirstResponder && window.canBecomeKey, "each display can receive Escape and Space")
            try check(window.sharingType == .none, "capture overlay is excluded from window sharing")
            let local = CGPoint(x: 120, y: 80)
            let global = window.convertPoint(toScreen: local)
            try check(global == CGPoint(x: frame.minX + 120, y: frame.minY + 80), "pointer events map through the originating overlay, including negative origins")
            try check(window.convertPoint(fromScreen: global) == local, "pointer coordinate conversion round trips")
        }
        var session = CaptureSession()
        guard let preparing = session.begin() else { throw VelinshotError.renderingFailed }
        try check(session.begin() == nil, "second start is rejected while permission/content is pending")
        try check(!session.commit(preparing), "capture cannot finish before selection starts")
        try check(session.end(preparing), "pending preparation can cancel")
        try check(!session.ready(preparing) && !session.end(preparing), "late preparation cannot resurrect overlays or deliver twice")
        guard let selecting = session.begin() else { throw VelinshotError.renderingFailed }
        try check(session.ready(selecting), "ready capture enters selection")
        try check(session.stage == .selecting && session.begin() == nil, "display capture waits in selection and rejects another start")
        try check(!session.end(preparing), "an old completion cannot end the new selection")
        try check(session.commit(selecting), "selection starts one in-flight capture")
        try check(!session.commit(selecting) && session.begin() == nil, "duplicate mouse-up cannot start a second capture")
        try check(session.end(selecting), "in-flight capture can finish or cancel")
        try check(!session.end(selecting) && session.stage == .idle, "completion and cursor cleanup have one owner")
        guard let disconnected = session.begin() else { throw VelinshotError.renderingFailed }
        try check(session.ready(disconnected) && session.end(disconnected), "display change can cancel selection")
        try check(!session.commit(disconnected), "disconnected selection cannot export partial pixels")
        return count
    }
}
