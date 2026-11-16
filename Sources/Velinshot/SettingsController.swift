import AppKit
import ServiceManagement

final class SettingsController: NSWindowController,NSTextFieldDelegate {
    private let shortcuts: GlobalShortcuts
    private var errorLabel = Brand.label("",size:11)
    private var permissionLabel = Brand.label("",size:11)
    private var captureRecorder: ShortcutRecorder!
    private var copyRecorder: ShortcutRecorder!
    private var loginButton: NSButton!
    var onClose: (() -> Void)?
    init(shortcuts:GlobalShortcuts) {
        self.shortcuts = shortcuts
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:520,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Velinshot Settings";window.isReleasedWhenClosed = false
        super.init(window:window)
        build()
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    override func showWindow(_ sender:Any?) {
        refresh();NSApp.setActivationPolicy(.regular);super.showWindow(sender);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func refresh() {
        errorLabel.stringValue = [shortcuts.captureError,shortcuts.quickCopyError].compactMap{$0}.joined(separator:"\n")
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        captureRecorder?.shortcut = AppSettings.shared.captureShortcut;copyRecorder?.shortcut = AppSettings.shared.quickCopyShortcut
        permissionLabel.stringValue = CGPreflightScreenCaptureAccess() ? "Screen capture access is enabled." : "Screen capture access is required before capturing. Image editing works without it."
        loginButton?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private func build() {
        guard let root = window?.contentView else { return }
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.drawsBackground = false
        root.addSubview(scroll);scroll.pin(to:root)
        let document = FlippedView();document.translatesAutoresizingMaskIntoConstraints = false;scroll.documentView = document
        document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor).isActive = true
        let stack = NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 12
        document.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:document.topAnchor,constant:24),stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:26),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-26),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24)])
        func add(_ view:NSView) { stack.addArrangedSubview(view);view.translatesAutoresizingMaskIntoConstraints = false;view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        add(Brand.label("Make it feel like yours.",size:22,weight:.semibold))
        add(Brand.label("Fast capture, quiet defaults, everything on your Mac.",size:12))
        add(section("Keyboard shortcuts"))
        captureRecorder = ShortcutRecorder(shortcut:AppSettings.shared.captureShortcut) { [weak self] value in AppSettings.shared.captureShortcut = value;self?.refresh() }
        copyRecorder = ShortcutRecorder(shortcut:AppSettings.shared.quickCopyShortcut) { [weak self] value in AppSettings.shared.quickCopyShortcut = value;self?.refresh() }
        for recorder in [captureRecorder!,copyRecorder!] {
            recorder.onRecordingChange = { [weak self] recording in
                if recording { self?.shortcuts.suspend() } else { self?.shortcuts.resume();self?.refresh() }
            }
        }
        add(row("Capture and edit",control:captureRecorder));add(row("Capture and copy",control:copyRecorder))
        errorLabel.textColor = .systemOrange;errorLabel.maximumNumberOfLines = 4;errorLabel.lineBreakMode = .byWordWrapping;add(errorLabel)
        let retry = ActionButton(title:"Retry shortcuts") { [weak self] in self?.shortcuts.refresh();self?.refresh() }
        let fallback = ActionButton(title:"Use ⌘⇧2 for capture") { [weak self] in AppSettings.shared.captureShortcut = .fallback;self?.refresh() }
        let restore = ActionButton(title:"Use ⌘4") { [weak self] in AppSettings.shared.captureShortcut = .capture;self?.refresh() }
        add(NSStackView(views:[retry,restore,fallback]))
        add(section("Screen capture"))
        permissionLabel.maximumNumberOfLines = 3;permissionLabel.lineBreakMode = .byWordWrapping;permissionLabel.textColor = .secondaryLabelColor;add(permissionLabel)
        let permission = ActionButton(title:"Request capture access…") { [weak self] in
            _ = CGRequestScreenCaptureAccess()
            self?.refresh()
        }
        let openSettings = ActionButton(title:"Open Screen Recording settings") {
            if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        }
        add(NSStackView(views:[permission,openSettings]))
        add(section("Workflow"))
        add(check("Close screenshot after copying",value:AppSettings.shared.closeAfterCopy){AppSettings.shared.closeAfterCopy = $0})
        add(check("Hide Velinshot windows while capturing",value:AppSettings.shared.hideDuringCapture){AppSettings.shared.hideDuringCapture = $0})
        add(check("Hide Dock icon when the last window closes",value:AppSettings.shared.hideDockWhenClosed){AppSettings.shared.hideDockWhenClosed = $0})
        add(check("Play a sound after copying or saving",value:AppSettings.shared.sound){AppSettings.shared.sound = $0})
        add(check("Show welcome window when opening the app",value:AppSettings.shared.showWelcome){AppSettings.shared.showWelcome = $0})
        loginButton = check("Launch at login",value:SMAppService.mainApp.status == .enabled) { [weak self] enabled in
            Task { @MainActor in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try await SMAppService.mainApp.unregister() }
                } catch { self?.show(error) }
                self?.refresh()
            }
        }
        add(loginButton)
        add(section("Files & history"))
        add(check("Compress to JPEG by default",value:AppSettings.shared.jpegByDefault){AppSettings.shared.jpegByDefault = $0})
        add(check("Keep editable screenshot history on this Mac",value:AppSettings.shared.historyEnabled){AppSettings.shared.historyEnabled = $0})
        let historyNote = Brand.label("History is off by default. When enabled, keep at most 50 captures or 250 MB. Clear it from the History window.",size:11)
        historyNote.maximumNumberOfLines = 3;historyNote.lineBreakMode = .byWordWrapping;historyNote.textColor = .secondaryLabelColor;add(historyNote)
        let name = NSTextField(string:AppSettings.shared.filename);name.target = self;name.action = #selector(filenameChanged);name.delegate = self;name.identifier = .init("filename-prefix");name.setAccessibilityLabel("Default screenshot filename");add(row("Filename prefix",control:name))
        let directory = ActionButton(title:"Choose default save folder…",symbol:"folder") { [weak self] in
            let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.directoryURL = AppSettings.shared.directory
            if panel.runModal() == .OK,let url = panel.url { AppSettings.shared.directory = url;self?.refresh() }
        };add(directory)
        let historyDirectory = ActionButton(title:"Choose history folder…",symbol:"clock.arrow.circlepath") { [weak self] in
            let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false
            panel.message = "Velinshot creates its own Velinshot History folder inside your selection. Existing history stays in its current folder."
            panel.directoryURL = AppSettings.shared.historyDirectory.deletingLastPathComponent()
            if panel.runModal() == .OK,let url = panel.url {
                AppSettings.shared.historyDirectory = url.appendingPathComponent("Velinshot History",isDirectory:true)
                self?.refresh()
            }
        };add(historyDirectory)
        let note = Brand.label("Free. No accounts, uploads, analytics or watermark. Capture permissions are controlled by macOS.",size:11)
        note.maximumNumberOfLines = 3;note.lineBreakMode = .byWordWrapping;note.textColor = .secondaryLabelColor;add(note)
    }
    private func section(_ title:String) -> NSView {
        let label = Brand.label(title,size:13,weight:.semibold)
        let view = NSView();view.addSubview(label);label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.heightAnchor.constraint(equalToConstant:30),label.leadingAnchor.constraint(equalTo:view.leadingAnchor),label.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        return view
    }
    private func row(_ title:String,control:NSView) -> NSView {
        let label = Brand.label(title);let space = NSView();let row = NSStackView(views:[label,space,control]);row.alignment = .centerY
        control.widthAnchor.constraint(equalToConstant:210).isActive = true
        return row
    }
    private func check(_ title:String,value:Bool,onChange:@escaping(Bool)->Void) -> NSButton {
        let button = CheckButton(title:title,value:value,onChange:onChange);button.font = .systemFont(ofSize:12);return button
    }
    @objc private func filenameChanged(_ sender:NSTextField) { AppSettings.shared.filename = sender.stringValue }
    func controlTextDidChange(_ notification:Notification) { if let field = notification.object as? NSTextField,field.identifier?.rawValue == "filename-prefix" { AppSettings.shared.filename = field.stringValue } }
    private func show(_ error:Error) { let alert = NSAlert(error:error);if let window { alert.beginSheetModal(for:window) } }
}

final class CheckButton: NSButton {
    let onChange:(Bool)->Void
    init(title:String,value:Bool,onChange:@escaping(Bool)->Void) {
        self.onChange = onChange
        super.init(frame:.zero);self.title = title;setButtonType(.switch);state = value ? .on : .off;target = self;action = #selector(toggle)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func toggle() { onChange(state == .on) }
}

final class ShortcutRecorder: NSButton {
    var shortcut:AppShortcut { didSet { if !recording { title = shortcut.display } } }
    private var monitor:Any?
    private var windowObserver:NSObjectProtocol?
    private var recording = false
    private let onChange:(AppShortcut)->Void
    var onRecordingChange:((Bool)->Void)?
    init(shortcut:AppShortcut,onChange:@escaping(AppShortcut)->Void) {
        self.shortcut = shortcut;self.onChange = onChange
        super.init(frame:.zero);title = shortcut.display;bezelStyle = .rounded;target = self;action = #selector(record)
        setAccessibilityLabel("Record keyboard shortcut")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) };if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    @objc private func record() {
        if recording { stop();return }
        recording = true;title = "Press shortcut… Esc to cancel"
        onRecordingChange?(true)
        windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in self?.stop() }
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop();return nil }
            guard let value = AppShortcut(event:event) else { self.title = "Include ⌘ or ⌃";return nil }
            self.shortcut = value;self.stop();self.onChange(value);return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) };monitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) };windowObserver = nil
        let wasRecording = recording
        recording = false;title = shortcut.display
        if wasRecording { onRecordingChange?(false) }
    }
    override func viewWillMove(toWindow newWindow:NSWindow?) { if newWindow == nil { stop() };super.viewWillMove(toWindow:newWindow) }
}
