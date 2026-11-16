import AppKit
import VelinshotCore

enum ImageWork {
    /// One source preparation at a time, including large capture/analysis jobs.
    static let queue = DispatchQueue(label:"app.velinshot.image-work",qos:.userInitiated)
}

final class ImageWorkTicket:@unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled:Bool { lock.lock();defer{lock.unlock()};return cancelled }
    func cancel() { lock.lock();cancelled = true;lock.unlock() }
    func checkpoint() throws { if isCancelled { throw CancellationError() } }
}

/// Scheduling is injectable so race checks can run deterministically without sleeps.
/// Submit/cancel/install are all main-thread operations; workers never touch views.
final class LatestImageWork<Output> {
    typealias Work = (ImageWorkTicket)throws->Output
    private let schedule:(@escaping()->Void)->Void
    private let deliver:(@escaping()->Void)->Void
    private var current:ImageWorkTicket?
    var isBusy:Bool { current != nil }
    init(schedule:@escaping(@escaping()->Void)->Void = { ImageWork.queue.async(execute:$0) },deliver:@escaping(@escaping()->Void)->Void = { DispatchQueue.main.async(execute:$0) }) {
        self.schedule = schedule;self.deliver = deliver
    }
    deinit { current?.cancel() }
    func cancel() { precondition(Thread.isMainThread);current?.cancel();current = nil }
    func submit(work:@escaping Work,completion:@escaping(Result<Output,Error>)->Void) { submitBatch([work],completion:completion) }
    func submitBatch(_ work:[Work],completion:@escaping(Result<Output,Error>)->Void) {
        precondition(Thread.isMainThread)
        cancel();guard !work.isEmpty else { return }
        let ticket = ImageWorkTicket();current = ticket
        perform(work,at:0,ticket:ticket,completion:completion)
    }
    private func perform(_ work:[Work],at index:Int,ticket:ImageWorkTicket,completion:@escaping(Result<Output,Error>)->Void) {
        schedule { [weak self,deliver] in
            guard !ticket.isCancelled else { return }
            let result:Result<Output,Error> = autoreleasepool { Result { try ticket.checkpoint();let output = try work[index](ticket);try ticket.checkpoint();return output } }
            deliver { [weak self] in
                guard let self,self.current === ticket,!ticket.isCancelled else { return }
                // Check and install share this main-queue step, with no async hop.
                let isLast = index == work.count-1
                if isLast { self.current = nil }
                completion(result)
                // Main-thread presentation provides backpressure. A save/error
                // panel cannot leave the worker decoding a whole batch unseen.
                if !isLast,self.current === ticket,!ticket.isCancelled { self.perform(work,at:index+1,ticket:ticket,completion:completion) }
            }
        }
    }
}

enum ImageInput {
    case file(URL),encoded(Data),image(CGImage)
}

struct PreparedDocument {
    let source:CGImage
    let preview:ImagePreview
    let state:EditState
    let title:String
    let quickCopyOutput:CGImage?
    let analysis:DocumentAnalysis
}

enum DocumentPreparation {
    static func prepare(_ input:ImageInput,style:CanvasStyle,state:EditState? = nil,title:String,quickCopy:Bool = false,ticket:ImageWorkTicket) throws -> PreparedDocument {
        guard !Thread.isMainThread else { throw VelinshotError.invalidImage("Image preparation needs the background worker. Try opening the image again.") }
        try ticket.checkpoint()
        let source:CGImage
        switch input {
        case .file(let url):source = try ImageLoader.open(url:url).fullResolution()
        case .encoded(let data):source = try ImageLoader.open(data:data).fullResolution()
        case .image(let image):source = image
        }
        try ticket.checkpoint()
        // Exact analysis finishes before the first editable geometry is installed.
        let prepared = autoreleasepool { state.map{($0,DocumentAnalysis())} ?? NewDocument.prepare(source:source,style:style) }
        let preparedState = prepared.0
        try ticket.checkpoint()
        let preview = try ImageLoader.preview(image:source,maxDimension:1400)
        try ticket.checkpoint()
        let output = quickCopy ? try CanvasRenderer.render(source:source,state:preparedState,backgroundImage:AppDelegate.backgroundImage(for:preparedState.style.backgroundAssetID)) : nil
        try ticket.checkpoint()
        return PreparedDocument(source:source,preview:preview,state:preparedState,title:title,quickCopyOutput:output,analysis:prepared.1)
    }
}

final class LoadingController:NSWindowController {
    var onCancel:(()->Void)?
    init(title:String) {
        let window = NSPanel(contentRect:CGRect(x:0,y:0,width:350,height:132),styleMask:[.titled],backing:.buffered,defer:false)
        window.titleVisibility = .hidden;window.titlebarAppearsTransparent = true;window.isReleasedWhenClosed = false
        super.init(window:window)
        let headline = Brand.label("Opening your image",size:15,weight:.semibold)
        let detail = Brand.label(title,size:11);detail.textColor = .secondaryLabelColor;detail.lineBreakMode = .byTruncatingMiddle
        let cancel = ActionButton(title:"Cancel") { [weak self] in self?.onCancel?() };cancel.keyEquivalent = "\u{1b}"
        let labels = NSStackView(views:[headline,detail]);labels.orientation = .vertical;labels.alignment = .leading;labels.spacing = 7
        let icon = NSImageView(image:Brand.symbol("photo",size:26)!);icon.contentTintColor = StudioPalette.accent
        let row = NSStackView(views:[icon,labels,NSView(),cancel]);row.spacing = 16;row.alignment = .centerY
        if let root = window.contentView { root.addSubview(row);row.pin(to:root,inset:24) }
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
}
