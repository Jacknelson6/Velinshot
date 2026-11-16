import AppKit
import Carbon
import VelinshotCore

struct AppShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    static let capture = AppShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey), key: "4")
    static let quickCopy = AppShortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | optionKey | controlKey), key: "5")
    static let fallback = AppShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), key: "2")
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key.uppercased()
    }
    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                  key: event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
    }
}

final class AppSettings {
    static let shared = AppSettings()
    static let changed = Notification.Name("VelinshotSettingsChanged")
    private let defaults: UserDefaults
    init(defaults:UserDefaults = .standard) { self.defaults = defaults }
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private func directoryURL(_ key:String,fallback:URL) -> URL {
        guard let stored = defaults.url(forKey:key),stored.isFileURL else { return fallback }
        return URL(fileURLWithPath:stored.standardizedFileURL.path,isDirectory:true)
    }
    var closeAfterCopy: Bool { get { bool("closeAfterCopy", default: true) } set { set(newValue, "closeAfterCopy") } }
    var hideDuringCapture: Bool { get { bool("hideDuringCapture", default: true) } set { set(newValue, "hideDuringCapture") } }
    var hideDockWhenClosed: Bool { get { bool("hideDockWhenClosed", default: true) } set { set(newValue, "hideDockWhenClosed") } }
    var sound: Bool { get { bool("sound", default: false) } set { set(newValue, "sound") } }
    var historyEnabled: Bool { get { bool("historyEnabled", default: false) } set { set(newValue, "historyEnabled") } }
    var jpegByDefault: Bool { get { bool("jpegByDefault", default: true) } set { set(newValue, "jpegByDefault") } }
    var showWelcome: Bool { get { bool("showWelcome", default: true) } set { set(newValue, "showWelcome") } }
    var filename: String { get { defaults.string(forKey: "filename") ?? "Screenshot" } set { set(newValue, "filename") } }
    var directory: URL {
        get { directoryURL("saveDirectory",fallback:FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask)[0]) }
        set {
            defaults.set(newValue,forKey:"saveDirectory")
            NotificationCenter.default.post(name:Self.changed,object:self)
        }
    }
    var historyDirectory:URL {
        get { directoryURL("historyDirectory",fallback:Self.supportDirectory.appendingPathComponent("History",isDirectory:true)) }
        set {
            defaults.set(newValue,forKey:"historyDirectory")
            NotificationCenter.default.post(name:Self.changed,object:self)
        }
    }
    var quality: Double { get { defaults.object(forKey: "quality") == nil ? 0.92 : defaults.double(forKey: "quality") } set { set(min(1, max(0.1, newValue)), "quality") } }
    private func shortcut(_ key: String, fallback: AppShortcut) -> AppShortcut {
        guard let data = defaults.data(forKey: key), let result = try? JSONDecoder().decode(AppShortcut.self, from: data) else { return fallback }
        return result
    }
    var captureShortcut: AppShortcut {
        get { shortcut("captureShortcut", fallback: .capture) }
        set { set(try? JSONEncoder().encode(newValue), "captureShortcut") }
    }
    var quickCopyShortcut: AppShortcut {
        get { shortcut("quickCopyShortcut", fallback: .quickCopy) }
        set { set(try? JSONEncoder().encode(newValue), "quickCopyShortcut") }
    }
    var style: CanvasStyle {
        get {
            guard let data = defaults.data(forKey: "canvasStyle"), let style = try? JSONDecoder().decode(CanvasStyle.self, from: data) else { return CanvasStyle() }
            return style
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "canvasStyle") }
    }
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Velinshot", isDirectory: true)
    }
}

final class GlobalShortcuts {
    private var handler: EventHandlerRef?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var suspended = false
    var onCapture: (() -> Void)?
    var onQuickCopy: (() -> Void)?
    private(set) var captureError: String?
    private(set) var quickCopyError: String?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let manager = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                if identifier.id == 1 { manager.onCapture?() }
                if identifier.id == 2 { manager.onQuickCopy?() }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func refresh() {
        registered.values.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        guard !suspended else { return }
        captureError = register(AppSettings.shared.captureShortcut, id: 1)
        quickCopyError = register(AppSettings.shared.quickCopyShortcut, id: 2)
    }
    func suspend() { suspended = true;refresh() }
    func resume() { suspended = false;refresh() }
    private func register(_ shortcut: AppShortcut, id: UInt32) -> String? {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if Self.protectsXnapper(shortcut,runningBundleIDs:running) {
            return "Xnapper is running and may own \(shortcut.display). Quit Xnapper or record another shortcut, then retry. ⌘⇧2 is a useful alternative."
        }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: 0x564C5348, id: id), GetApplicationEventTarget(), 0, &reference)
        if result == noErr, let reference { registered[id] = reference; return nil }
        return "\(shortcut.display) is unavailable. Another app or macOS may be using it. Quit Xnapper to use ⌘4, record another shortcut, or try ⌘⇧2."
    }
    static func protectsXnapper(_ shortcut:AppShortcut,runningBundleIDs:[String]) -> Bool {
        runningBundleIDs.contains("com.devuap.beautyshotapp") && [AppShortcut.capture,.quickCopy].contains{$0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers}
    }
    deinit {
        registered.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
