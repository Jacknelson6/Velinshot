import AppKit
import UniformTypeIdentifiers
import VelinshotCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private struct ClosedScreenshot {
        let image:CGImage
        let state:EditState
        let title:String
        let historyEntry:HistoryEntry?
        let historyDirectory:URL
    }
    private let capture = CaptureController()
    private let shortcuts = GlobalShortcuts()
    private var editors:[EditorController] = []
    private var statusItem:NSStatusItem?
    private var welcome:NSWindowController?
    private lazy var settings:SettingsController = {
        let controller = SettingsController(shortcuts:shortcuts)
        controller.onRefresh = { [weak self] in self?.refreshWelcomeShortcuts() }
        return controller
    }()
    private lazy var history:HistoryController = {
        let controller = HistoryController()
        controller.onOpen = { [weak self] image,state,entry in self?.present(image,state:state,historyEntry:entry) }
        return controller
    }()
    private var settingsObserver:NSObjectProtocol?
    private var closeObserver:NSObjectProtocol?
    private var pendingURLs:[URL] = []
    private let importer = LatestImageWork<PreparedDocument>()
    private var loadingTask:DispatchWorkItem?
    private var loadingWindow:LoadingController?
    private var lastClosed:ClosedScreenshot?
    private var lastHistoryDirectory = AppSettings.shared.historyDirectory
    private var welcomeCapture:NSButton?
    private var welcomeShortcutNote:NSButton?
    private var activeEditor:EditorController? { editors.first(where:{$0.window?.isKeyWindow == true}) ?? editors.last }

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.appearance = nil
        buildMenus()
        shortcuts.onCapture = { [weak self] in self?.takeCapture() }
        shortcuts.onQuickCopy = { [weak self] in self?.takeCapture(quickCopy:true) }
        shortcuts.refresh()
        settingsObserver = NotificationCenter.default.addObserver(forName:AppSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.settingsDidChange() }
        closeObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main) { [weak self] _ in DispatchQueue.main.async { self?.updateDockPolicy() } }
        if CommandLine.arguments.contains("--demo") {
            do { present(try DemoFixture.make(),state:DemoFixture.style(),title:"Studio notes · Demo") } catch { showError(error) }
        } else if !pendingURLs.isEmpty { openURLs(pendingURLs);pendingURLs.removeAll() }
        else if AppSettings.shared.showWelcome { showWelcome() }
        else { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        if !flag { if let editor = activeEditor { editor.showWindow(nil) } else { showWelcome() } }
        return true
    }
    func application(_ application:NSApplication,open urls:[URL]) {
        if statusItem == nil { pendingURLs.append(contentsOf:urls) } else { openURLs(urls) }
    }
    func applicationWillTerminate(_ notification:Notification) {
        importer.cancel();finishLoading()
        editors.forEach{$0.persistHistory()}
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
    private func buildMenus() {
        let bar = NSMenu()
        let app = NSMenu();let appItem = NSMenuItem();appItem.submenu = app;bar.addItem(appItem)
        add("About Velinshot",to:app,action:#selector(about));app.addItem(.separator())
        add("Settings…",to:app,key:",",action:#selector(showSettings));add("Check for Updates…",to:app,action:#selector(checkUpdates));app.addItem(.separator())
        add("Hide Velinshot",to:app,key:"h",action:#selector(NSApplication.hide(_:)),target:NSApp)
        add("Quit Velinshot",to:app,key:"q",action:#selector(NSApplication.terminate(_:)),target:NSApp)
        let file = NSMenu(title:"File");let fileItem = NSMenuItem(title:"File",action:nil,keyEquivalent:"");fileItem.submenu = file;bar.addItem(fileItem)
        add("New Capture",to:file,action:#selector(newCapture));add("Capture Display",to:file,action:#selector(captureDisplay));add("Capture and Copy",to:file,action:#selector(quickCapture));file.addItem(.separator())
        add("Open Image…",to:file,key:"o",action:#selector(openImage));let paste = add("Open from Clipboard",to:file,key:"v",action:#selector(openClipboard));paste.keyEquivalentModifierMask = [.command,.shift]
        add("Screenshot History…",to:file,action:#selector(showHistory));let reopen = add("Reopen Closed Screenshot",to:file,key:"t",action:#selector(reopenClosed));reopen.keyEquivalentModifierMask = [.command,.shift];file.addItem(.separator())
        add("Save…",to:file,key:"s",action:#selector(save));add("Save Original…",to:file,action:#selector(saveOriginal));add("Copy Original",to:file,action:#selector(copyOriginal));add("Share Screenshot…",to:file,action:#selector(share));file.addItem(.separator());add("Close",to:file,key:"w",action:#selector(NSWindow.performClose(_:)),target:nil)
        let edit = NSMenu(title:"Edit");let editItem = NSMenuItem(title:"Edit",action:nil,keyEquivalent:"");editItem.submenu = edit;bar.addItem(editItem)
        add("Undo",to:edit,key:"z",action:#selector(undo(_:)),target:nil)
        let redo = add("Redo",to:edit,key:"z",action:#selector(redo(_:)),target:nil);redo.keyEquivalentModifierMask = [.command,.shift]
        edit.addItem(.separator());add("Cut",to:edit,key:"x",action:#selector(NSText.cut(_:)),target:nil);add("Copy",to:edit,key:"c",action:#selector(NSText.copy(_:)),target:nil);add("Paste",to:edit,key:"v",action:#selector(NSText.paste(_:)),target:nil);add("Select All",to:edit,key:"a",action:#selector(NSText.selectAll(_:)),target:nil)
        edit.addItem(.separator());add("Select and Copy Image Text…",to:edit,action:#selector(recognizeText))
        let window = NSMenu(title:"Window");let windowItem = NSMenuItem(title:"Window",action:nil,keyEquivalent:"");windowItem.submenu = window;bar.addItem(windowItem)
        add("Minimize",to:window,key:"m",action:#selector(NSWindow.performMiniaturize(_:)),target:nil);add("Bring All to Front",to:window,action:#selector(NSApplication.arrangeInFront(_:)),target:NSApp)
        NSApp.windowsMenu = window
        let help = NSMenu(title:"Help");let helpItem = NSMenuItem(title:"Help",action:nil,keyEquivalent:"");helpItem.submenu = help;bar.addItem(helpItem)
        add("Keyboard Shortcuts",to:help,action:#selector(shortcutHelp));add("Open Demo Image",to:help,action:#selector(openDemo));NSApp.helpMenu = help
        NSApp.mainMenu = bar
        let status = NSMenu()
        add("Capture and Edit",to:status,action:#selector(newCapture));add("Capture Display",to:status,action:#selector(captureDisplay));add("Capture and Copy",to:status,action:#selector(quickCapture));status.addItem(.separator())
        add("Open Image…",to:status,action:#selector(openImage));add("Open from Clipboard",to:status,action:#selector(openClipboard));add("Reopen Closed Screenshot",to:status,action:#selector(reopenClosed));add("History…",to:status,action:#selector(showHistory));status.addItem(.separator());add("Settings…",to:status,action:#selector(showSettings));add("Quit Velinshot",to:status,action:#selector(NSApplication.terminate(_:)),target:NSApp)
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem?.button?.image = Brand.symbol("viewfinder",size:17);statusItem?.button?.image?.isTemplate = true;statusItem?.button?.toolTip = "Velinshot · Beautiful screenshots, native speed"
        statusItem?.menu = status
    }
    @discardableResult private func add(_ title:String,to menu:NSMenu,key:String = "",action:Selector,target:AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title:title,action:action,keyEquivalent:key)
        if target == nil,[#selector(NSText.cut(_:)),#selector(NSText.copy(_:)),#selector(NSText.paste(_:)),#selector(NSText.selectAll(_:)),#selector(undo(_:)),#selector(redo(_:)),#selector(NSWindow.performClose(_:)),#selector(NSWindow.performMiniaturize(_:))].contains(action) { item.target = nil }
        else { item.target = target ?? self }
        menu.addItem(item);return item
    }
    private func showWelcome() {
        refreshWelcomeShortcuts()
        if let welcome { NSApp.setActivationPolicy(.regular);welcome.showWindow(nil);welcome.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return }
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:560,height:430),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Velinshot";window.isReleasedWhenClosed = false
        let root = NSView();window.contentView = root
        let logo = NSImageView(image:NSImage(named:NSImage.Name("AppIcon")) ?? Brand.symbol("viewfinder",size:64)!)
        logo.translatesAutoresizingMaskIntoConstraints = false;logo.widthAnchor.constraint(equalToConstant:92).isActive = true;logo.heightAnchor.constraint(equalToConstant:92).isActive = true
        let headline = Brand.label("A good screenshot. In a moment.",size:25,weight:.semibold)
        let subline = Brand.label("Capture, frame, mark it up. Copy and carry on.",size:13);subline.textColor = .secondaryLabelColor
        let capture = ActionButton(title:"Capture  \(AppSettings.shared.captureShortcut.display)",symbol:"viewfinder") { [weak self] in self?.takeCapture() };capture.bezelColor = Brand.iris;capture.contentTintColor = .white
        welcomeCapture = capture
        let open = ActionButton(title:"Open Image…",symbol:"folder") { [weak self] in self?.openImage() }
        let buttons = NSStackView(views:[capture,open]);buttons.spacing = 12
        let paste = ActionButton(title:"Open from Clipboard") { [weak self] in self?.openClipboard() };paste.isBordered = false
        let settings = ActionButton(title:shortcuts.captureError == nil ? "Settings" : "Could not register \(AppSettings.shared.captureShortcut.display). Open Settings.") { [weak self] in self?.showSettings() };settings.isBordered = false;settings.contentTintColor = shortcuts.captureError == nil ? .secondaryLabelColor : .systemOrange
        welcomeShortcutNote = settings
        let stack = NSStackView(views:[logo,headline,subline,buttons,paste,settings]);stack.orientation = .vertical;stack.spacing = 16;stack.alignment = .centerX
        root.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:root.centerXAnchor),stack.centerYAnchor.constraint(equalTo:root.centerYAnchor),stack.leadingAnchor.constraint(greaterThanOrEqualTo:root.leadingAnchor,constant:24)])
        window.center();welcome = NSWindowController(window:window);showWelcome()
    }
    private func takeCapture(quickCopy:Bool = false,display:Bool = false) {
        if NSApp.modalWindow == nil,!capture.isCapturing { importer.cancel();finishLoading() }
        capture.begin(display ? .display : .area) { [weak self] result in
            switch result {
            case .success(let image):
                self?.prepareImages([(.image(image),nil,"Screenshot")],quickCopy:quickCopy)
            case .failure(let error):
                if let failure = error as? CaptureFailure,case .cancelled = failure { return }
                self?.showCaptureError(error)
            }
        }
    }
    private func present(_ image:CGImage,state:EditState? = nil,title:String = "Screenshot",historyEntry:HistoryEntry? = nil,preparedPreview:ImagePreview? = nil,preparedAnalysis:DocumentAnalysis = DocumentAnalysis()) {
        guard let preparedPreview else { prepareImages([(.image(image),state,title)],historyEntry:historyEntry);return }

        welcome?.window?.orderOut(nil)
        let editor = EditorController(source:image,state:state,title:title,preparedPreview:preparedPreview,preparedAnalysis:preparedAnalysis)
        editor.historyEntry = historyEntry
        editor.onClose = { [weak self,weak editor] in
            if let editor { self?.lastClosed = ClosedScreenshot(image:editor.source,state:editor.state,title:editor.window?.title ?? "Screenshot",historyEntry:editor.historyEntry,historyDirectory:AppSettings.shared.historyDirectory) }
            self?.editors.removeAll{$0 === editor}
            DispatchQueue.main.async { [weak self] in self?.updateDockPolicy() }
        }
        editor.onCapture = { [weak self] in self?.takeCapture() }
        editor.onOpen = { [weak self] in self?.openImage() }
        editor.onPaste = { [weak self] in self?.openClipboard() }
        editor.onSettings = { [weak self] in self?.showSettings() }
        editor.onHistory = { [weak self] in self?.showHistory() }
        editor.onImportURL = { [weak self] in self?.openURL($0) }
        editor.onImportData = { [weak self] data in self?.prepareImages([(.encoded(data),nil,"Screenshot")]) }
        editors.append(editor);editor.showWindow(nil);editor.persistHistory()
    }
    private func updateDockPolicy() {
        if AppSettings.shared.hideDockWhenClosed,!NSApp.windows.contains(where:{$0.isVisible}) { NSApp.setActivationPolicy(.accessory) }
    }
    private func settingsDidChange() {
        let directory = AppSettings.shared.historyDirectory
        if directory != lastHistoryDirectory {
            editors.forEach{$0.historyEntry = nil}
            lastHistoryDirectory = directory
            history.reload()
        }
        shortcuts.refresh();settings.refresh();refreshWelcomeShortcuts()
    }
    private func refreshWelcomeShortcuts() {
        welcomeCapture?.title = "Capture  \(AppSettings.shared.captureShortcut.display)"
        welcomeShortcutNote?.title = shortcuts.captureError == nil ? "Settings" : "Could not register \(AppSettings.shared.captureShortcut.display). Open Settings."
        welcomeShortcutNote?.contentTintColor = shortcuts.captureError == nil ? .secondaryLabelColor : .systemOrange
    }
    static func backgroundImage(for id:String?) -> CGImage? {
        guard let id,UUID(uuidString:id) != nil else { return nil }
        return try? ImageLoader.load(url:AppSettings.supportDirectory.appendingPathComponent("Backgrounds",isDirectory:true).appendingPathComponent(id+".png"))
    }
    private func openURL(_ url:URL) { openURLs([url]) }
    private func openURLs(_ urls:[URL]) { prepareImages(urls.map{(.file($0),nil,$0.lastPathComponent)}) }
    private func prepareImages(_ requests:[(ImageInput,EditState?,String)],historyEntry:HistoryEntry? = nil,quickCopy:Bool = false) {
        guard !requests.isEmpty else { return }
        finishLoading()
        let style = AppSettings.shared.style,historyDirectory = AppSettings.shared.historyDirectory
        importer.submitBatch(requests.map { input,state,title in { ticket in
            try DocumentPreparation.prepare(input,style:style,state:state,title:title,quickCopy:quickCopy,ticket:ticket)
        } }) { [weak self] result in
            guard let self else { return }
            if !self.importer.isBusy { self.finishLoading() }
            switch result {
            case .success(let prepared):
                if quickCopy { self.copyPrepared(prepared) }
                else {
                    let entry = historyDirectory == AppSettings.shared.historyDirectory ? historyEntry : nil
                    self.present(prepared.source,state:prepared.state,title:prepared.title,historyEntry:entry,preparedPreview:prepared.preview,preparedAnalysis:prepared.analysis)
                }
            case .failure(let error):self.showError(error)
            }
        }
        // A one-shot delayed surface avoids flashing a window for small files.
        let task = DispatchWorkItem { [weak self] in
            guard let self,self.importer.isBusy else { return }
            let controller = LoadingController(title:requests.count == 1 ? requests[0].2 : "\(requests.count) images")
            controller.onCancel = { [weak self] in self?.importer.cancel();self?.finishLoading() }
            self.loadingWindow = controller;controller.showWindow(nil)
        }
        loadingTask = task;DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:task)
    }
    private func finishLoading() { loadingTask?.cancel();loadingTask = nil;loadingWindow?.close();loadingWindow = nil }
    private func copyPrepared(_ prepared:PreparedDocument) {
        guard let output = prepared.quickCopyOutput else { return }
        let board = NSPasteboard.general;board.clearContents()
        guard board.writeObjects([NSImage(cgImage:output,size:CGSize(width:output.width,height:output.height))]) else { showError(VelinshotError.invalidImage("Clipboard is busy. Try again."));return }
        var entry:HistoryEntry?,historyError:Error?
        if AppSettings.shared.historyEnabled {
            do { entry = try HistoryStore(directory:AppSettings.shared.historyDirectory).save(image:prepared.source,state:prepared.state) }
            catch { historyError = error }
        }
        lastClosed = ClosedScreenshot(image:prepared.source,state:prepared.state,title:prepared.title,historyEntry:entry,historyDirectory:AppSettings.shared.historyDirectory)
        if AppSettings.shared.sound { NSSound(named:"Pop")?.play() }
        if let historyError {
            let alert = NSAlert();alert.messageText = "Copied, but history was not saved";alert.informativeText = historyError.localizedDescription+" Choose another history folder in Settings. You can still reopen the screenshot from File → Reopen Closed Screenshot.";alert.runModal()
        }
    }
    @objc func newCapture() { takeCapture() }
    @objc func quickCapture() { takeCapture(quickCopy:true) }
    @objc func captureDisplay() { takeCapture(display:true) }
    @objc func openImage() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.image];panel.canChooseDirectories = false;panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { openURLs(panel.urls) }
    }
    @objc func openClipboard() {
        let board = NSPasteboard.general
        if let data = board.data(forType:.png) ?? board.data(forType:.tiff) { prepareImages([(.encoded(data),nil,"Screenshot")]);return }
        if let urls = board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],let url = urls.first { openURL(url);return }
        let alert = NSAlert();alert.messageText = "No image on the clipboard";alert.informativeText = "Copy an image first, or choose Open Image to edit a file.";alert.runModal()
    }
    @objc func showSettings() { settings.showWindow(nil) }
    @objc func showHistory() { history.showWindow(nil) }
    @objc func save() { activeEditor?.saveImage() }
    @objc func saveOriginal() { activeEditor?.saveImage(original:true) }
    @objc func copyOriginal() { activeEditor?.copyImage(original:true) }
    @objc func share() { if let editor = activeEditor,let root = editor.window?.contentView { editor.shareScreenshot(root) } }
    @objc func recognizeText() { activeEditor?.recognizeText() }
    @objc func reopenClosed() {
        guard let lastClosed else { return }
        let entry = lastClosed.historyDirectory == AppSettings.shared.historyDirectory ? lastClosed.historyEntry : nil
        present(lastClosed.image,state:lastClosed.state,title:lastClosed.title,historyEntry:entry)
    }
    @objc func copy(_ sender:Any?) { activeEditor?.copyImage() }
    @objc func undo(_ sender:Any?) { activeEditor?.undoEdit() }
    @objc func redo(_ sender:Any?) { activeEditor?.redoEdit() }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reopenClosed):return lastClosed != nil
        case #selector(save),#selector(saveOriginal),#selector(copyOriginal),#selector(share),#selector(recognizeText):return activeEditor != nil
        case #selector(undo(_:)):return activeEditor?.canUndo ?? false
        case #selector(redo(_:)):return activeEditor?.canRedo ?? false
        case #selector(newCapture),#selector(captureDisplay),#selector(quickCapture):return !capture.isCapturing
        default:return true
        }
    }
    @objc func openDemo() { do { present(try DemoFixture.make(),state:DemoFixture.style(),title:"Studio notes · Demo") } catch { showError(error) } }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Velinshot",.applicationVersion:"1.0.0",.version:"1",.credits:NSAttributedString(string:"Beautiful screenshots. Native speed. Free forever.\nBuilt with Swift and macOS. MIT licensed.\ngithub.com/Jacknelson6/Velinshot")])
    }
    @objc func shortcutHelp() {
        let alert = NSAlert();alert.messageText = "A shorter way to share."
        alert.informativeText = "Capture: \(AppSettings.shared.captureShortcut.display)\nCapture selection: drag an area; Space for a window; Esc cancels\nCopy: C or ⌘C\nSave with destination picker: S or ⌘S\nUndo / redo: ⌘Z / ⇧⌘Z\nDraw D · Arrow A · Box R · Ellipse E · Text T\nHighlight H · Blur B · Redact K · Number N · Crop X\nSelect V · Line L · Delete removes selected mark\nFit ⌘0 · Zoom ⌘+ / ⌘−\n\nLetter shortcuts stay out of the way while typing text."
        alert.runModal()
    }
    @objc private func checkUpdates() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard let url = URL(string:"https://api.github.com/repos/Jacknelson6/Velinshot/releases/latest") else { return }
        var request = URLRequest(url:url);request.timeoutInterval = 15;request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        URLSession.shared.dataTask(with:request) { data,response,error in
            let payload = data.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
            let latest = (payload?["tag_name"] as? String)?.trimmingCharacters(in:CharacterSet(charactersIn:"v"))
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error { alert.messageText = "Could not check for updates";alert.informativeText = error.localizedDescription }
                else if let latest,latest.compare(current,options:.numeric) == .orderedDescending { alert.messageText = "Velinshot \(latest) is available";alert.informativeText = "Download the new version from the GitHub repository. Your current version is \(current)." }
                else if latest != nil { alert.messageText = "You’re up to date";alert.informativeText = "Velinshot \(current) is the latest published release." }
                else { alert.messageText = "No published release was found";alert.informativeText = "Try again later or check the GitHub repository." }
                alert.runModal()
            }
        }.resume()
    }
    private func showCaptureError(_ error:Error) {
        let alert = NSAlert();alert.messageText = "Capture needs your attention";alert.informativeText = error.localizedDescription
        if let failure = error as? CaptureFailure,case .permission = failure {
            alert.addButton(withTitle:"Open macOS Settings");alert.addButton(withTitle:"Show This App");alert.addButton(withTitle:"Later")
            NSApp.activate(ignoringOtherApps:true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            default: break
            }
            return
        }
        alert.addButton(withTitle:"Open Settings");alert.addButton(withTitle:"Later")
        NSApp.activate(ignoringOtherApps:true)
        if alert.runModal() == .alertFirstButtonReturn { showSettings() }
    }
    private func showError(_ error:Error) { NSApp.activate(ignoringOtherApps:true);NSAlert(error:error).runModal() }
}
