import AppKit
import Sparkle

#if VELINSHOT_UPDATER_FIXTURE_NEW
let compiledFixtureVersion = "2"
#else
let compiledFixtureVersion = "1"
#endif

final class FixtureWindowDelegate: NSObject, NSWindowDelegate {
    let closed: () -> Void
    init(closed: @escaping () -> Void) { self.closed = closed }
    func windowWillClose(_ notification: Notification) { closed() }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var updater: UpdaterController!
    private var window: NSWindow!
    private var screenshot: NSWindow?
    private var screenshotDelegate: FixtureWindowDelegate?
    private var captureBusy = false
    private var importBusy = false
    private var captureMenu: NSMenuItem?
    private var importMenu: NSMenuItem?
    private var actions: [() -> Void] = []
    private let status = NSTextField(labelWithString: "Synthetic fixture. No production app, screenshots or preferences are used.")
    private var workState: UpdateWorkState { UpdateWorkState(capturing: captureBusy, preparingImage: importBusy, openEditors: screenshot == nil ? 0 : 1, modal: NSApp.modalWindow != nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = UpdaterController(fixtureBundle: .main, notice: { [weak self] message in
            self?.status.stringValue = message; self?.record("notice", ["message": message])
        }, workState: { [weak self] in self?.workState ?? UpdateWorkState(modal: true) })
        updater.onFixtureEvent = { [weak self] event, error in self?.record(event, ["error": error ?? "none"]) }
        updater.start()
        let menu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu; menu.addItem(appItem)
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "u"); check.target = self; appMenu.addItem(check)
        appMenu.addItem(.separator())
        let show = NSMenuItem(title: "Show Fixture Window", action: #selector(showFixtureWindow), keyEquivalent: ""); show.target = self; appMenu.addItem(show)
        let showUpdate = NSMenuItem(title: "Show Software Update", action: #selector(showSoftwareUpdate), keyEquivalent: ""); showUpdate.target = self; appMenu.addItem(showUpdate)
        let screenshot = NSMenuItem(title: "Open Synthetic Screenshot", action: #selector(openScreenshot), keyEquivalent: ""); screenshot.target = self; appMenu.addItem(screenshot)
        let capture = NSMenuItem(title: "Toggle Capture Busy", action: #selector(toggleCaptureBusy), keyEquivalent: ""); capture.target = self; appMenu.addItem(capture); captureMenu = capture
        let importing = NSMenuItem(title: "Toggle Import Busy", action: #selector(toggleImportBusy), keyEquivalent: ""); importing.target = self; appMenu.addItem(importing); importMenu = importing
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApp; appMenu.addItem(quit); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Velinshot updater fixture " + compiledFixtureVersion; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Updater fixture version " + compiledFixtureVersion); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let buttons = [button("Check for Updates", { [weak self] in self?.checkUpdates() }),
                       button("Open synthetic screenshot", { [weak self] in self?.openScreenshot() }),
                       button("Toggle capture busy", { [weak self] in self?.toggleCaptureBusy() }),
                       button("Toggle import busy", { [weak self] in self?.toggleImportBusy() })]
        let stack = NSStackView(views: [title, status] + buttons); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(stack)
        if let root = window.contentView { NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24)]) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        record("launch", ["compiledVersion": compiledFixtureVersion, "bundleVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "missing", "path": Bundle.main.bundleURL.path])
    }
    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(invoke(_:))); button.bezelStyle = .rounded
        button.tag = actions.count; actions.append(action); return button
    }
    @objc private func invoke(_ sender: NSButton) { actions[sender.tag]() }
    @objc private func checkUpdates() { record("check"); updater.checkForUpdates(nil) }
    @objc private func showFixtureWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); record("showFixtureWindow") }
    @objc private func showSoftwareUpdate() {
        guard let updateWindow = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0 !== screenshot && $0.title == "Software Update" }) else {
            record("softwareUpdateWindowUnavailable"); return
        }
        updateWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); record("showSoftwareUpdate")
    }
    @objc private func toggleCaptureBusy() { captureBusy.toggle(); changedState() }
    @objc private func toggleImportBusy() { importBusy.toggle(); changedState() }
    @objc private func openScreenshot() {
        if let screenshot { screenshot.makeKeyAndOrderFront(nil); return }
        let imageWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        imageWindow.title = "Unsaved synthetic screenshot"; imageWindow.isReleasedWhenClosed = false
        let text = NSTextField(string: "Fixture annotation stays open during an update attempt."); text.frame = NSRect(x: 20, y: 95, width: 340, height: 44); text.isEditable = true
        imageWindow.contentView?.addSubview(text)
        screenshotDelegate = FixtureWindowDelegate { [weak self] in self?.screenshot = nil; self?.changedState() }
        imageWindow.delegate = screenshotDelegate; screenshot = imageWindow; imageWindow.center(); imageWindow.makeKeyAndOrderFront(nil); changedState()
    }
    private func changedState() {
        status.stringValue = "Capture: \(captureBusy). Import: \(importBusy). Open screenshot: \(screenshot != nil)."
        captureMenu?.state = captureBusy ? .on : .off; importMenu?.state = importBusy ? .on : .off
        record("state", ["capture": captureBusy, "import": importBusy, "editor": screenshot != nil])
        updater.workStateDidChange()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater.mayTerminateForUpdate() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { record("terminate") }
    private func record(_ event: String, _ details: [String: Any] = [:]) {
        guard let run = Bundle.main.infoDictionary?["VelinshotFixtureRunID"] as? String else { return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("VelinshotUpdaterFixture-" + run + ".jsonl")
        let payload = details.merging(["event": event, "pid": ProcessInfo.processInfo.processIdentifier, "time": Date().timeIntervalSince1970]) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: destination) else { return }
        defer { try? file.close() }; try? file.seekToEnd(); try? file.write(contentsOf: data + Data([10]))
    }
}

let fixtureApplication = NSApplication.shared
let fixtureDelegate = FixtureDelegate()
fixtureApplication.delegate = fixtureDelegate
fixtureApplication.setActivationPolicy(.regular)
fixtureApplication.run()
