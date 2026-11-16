import AppKit
import ImageIO
import VelinshotCore

final class HistoryController: NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    var onOpen:((CGImage,EditState,HistoryEntry)->Void)?
    private var store:HistoryStore { HistoryStore(directory:AppSettings.shared.historyDirectory) }
    private let table = NSTableView()
    private var entries:[HistoryEntry] = []
    private let note = Brand.label("",size:12)
    private let loader = LatestImageWork<(CGImage,EditState)>()
    init() {
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:620,height:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Screenshot History";window.isReleasedWhenClosed = false
        super.init(window:window)
        guard let root = window.contentView else { return }
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.documentView = table
        let capture = NSTableColumn(identifier:.init("capture"));capture.title = "Capture";capture.width = 340
        let date = NSTableColumn(identifier:.init("date"));date.title = "Taken";date.width = 180
        table.addTableColumn(capture);table.addTableColumn(date);table.delegate = self;table.dataSource = self;table.rowHeight = 54
        table.target = self;table.doubleAction = #selector(openSelected);table.setAccessibilityLabel("Saved screenshots")
        let open = ActionButton(title:"Open selected",symbol:"arrow.up.forward.app") { [weak self] in self?.openSelected() }
        let clear = ActionButton(title:"Clear history…") { [weak self] in self?.clearHistory() }
        let enabled = CheckButton(title:"Keep history",value:AppSettings.shared.historyEnabled){ [weak self] in AppSettings.shared.historyEnabled = $0;self?.reload() }
        let spacer = NSView();let footer = NSStackView(views:[enabled,spacer,clear,open]);footer.spacing = 10
        note.textColor = .secondaryLabelColor;note.maximumNumberOfLines = 2
        for view in [note,scroll,footer] { root.addSubview(view);view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([note.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:18),note.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),note.topAnchor.constraint(equalTo:root.topAnchor,constant:16),note.heightAnchor.constraint(equalToConstant:38),scroll.topAnchor.constraint(equalTo:note.bottomAnchor,constant:10),scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),footer.topAnchor.constraint(equalTo:scroll.bottomAnchor,constant:12),footer.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:18),footer.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),footer.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-16)])
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    override func showWindow(_ sender:Any?) { reload();NSApp.setActivationPolicy(.regular);super.showWindow(sender);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    func reload() {
        loader.cancel()
        do { entries = try store.entries();table.reloadData();note.stringValue = entries.isEmpty ? "No saved captures yet. Turn on history to keep editable screenshots on this Mac." : "\(entries.count) captures stored locally. Double-click to reopen and edit." }
        catch { note.stringValue = "History could not be read: \(error.localizedDescription)" }
    }
    func numberOfRows(in tableView:NSTableView) -> Int { entries.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let entry = entries[row]
        if tableColumn?.identifier.rawValue == "date" {
            let formatter = DateFormatter();formatter.dateStyle = .short;formatter.timeStyle = .short
            return Brand.label(formatter.string(from:entry.createdAt),size:11)
        }
        let icon = NSImageView();icon.imageScaling = .scaleProportionallyUpOrDown
        let url = AppSettings.shared.historyDirectory.appendingPathComponent(entry.imageFile)
        if let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:96] as CFDictionary) { icon.image = NSImage(cgImage:image,size:.zero) }
        icon.widthAnchor.constraint(equalToConstant:66).isActive = true;icon.heightAnchor.constraint(equalToConstant:44).isActive = true
        let text = Brand.label("Screenshot · \(entry.width) × \(entry.height)",size:12)
        let row = NSStackView(views:[icon,text]);row.spacing = 12;row.alignment = .centerY;return row
    }
    @objc private func openSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow],store = store
        note.stringValue = "Opening screenshot…"
        loader.submit(work:{ _ in try store.load(entry) }) { [weak self] result in
            guard let self,store.directory == AppSettings.shared.historyDirectory else { return }
            switch result {
            case .success(let (image,state)):self.onOpen?(image,state,entry);self.note.stringValue = "Screenshot opened"
            case .failure(let error):let alert = NSAlert(error:error);if let window = self.window { alert.beginSheetModal(for:window) }
            }
        }
    }
    private func clearHistory() {
        let alert = NSAlert();alert.messageText = "Clear screenshot history?";alert.informativeText = "This removes saved captures and their editable state from Velinshot on this Mac. Exported files are kept."
        alert.addButton(withTitle:"Clear History");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.clear();reload() } catch { NSAlert(error:error).runModal() }
    }
}
