import AppKit
import UniformTypeIdentifiers
import VelinshotCore

final class DragExportButton:StudioButton,NSDraggingSource {
    var imageProvider:(() throws -> CGImage)?
    var onError:((Error)->Void)?
    private var didDrag = false
    init() {
        super.init(frame:.zero)
        title = "Drag";image = Brand.symbol("hand.point.up",size:17);isBordered = false;font = .systemFont(ofSize:12,weight:.medium)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant:82).isActive = true;heightAnchor.constraint(equalToConstant:34).isActive = true
        toolTip = "Drag a finished PNG to Finder or another app";setAccessibilityLabel("Drag finished screenshot")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
    override func mouseDown(with event:NSEvent) { didDrag = false }
    override func mouseDragged(with event:NSEvent) {
        guard !didDrag,let imageProvider else { return }
        do {
            let image = try imageProvider()
            let data = try ImageExporter.data(image:image,format:.png)
            let promise = ScreenshotPromise(data:data)
            let item = NSDraggingItem(pasteboardWriter:promise)
            let width:CGFloat = 150;let height = width*CGFloat(image.height)/CGFloat(image.width)
            let location = convert(event.locationInWindow,from:nil)
            item.setDraggingFrame(CGRect(x:location.x-width/2,y:location.y-height/2,width:width,height:height),contents:NSImage(cgImage:image,size:.zero))
            didDrag = true;beginDraggingSession(with:[item],event:event,source:self)
        } catch { onError?(error) }
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
}

final class ScreenshotPromiseWriter:NSObject,NSFilePromiseProviderDelegate {
    private let writeQueue:OperationQueue = {
        let queue = OperationQueue();queue.name = "app.velinshot.drag-export";queue.maxConcurrentOperationCount = 1;return queue
    }()
    private let filename = "Screenshot-\(UUID().uuidString.prefix(8)).png"
    func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,fileNameForType fileType:String) -> String { filename }
    func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping(Error?)->Void) {
        guard let provider = filePromiseProvider as? ScreenshotPromise else { completionHandler(VelinshotError.encodingFailed);return }
        do { try provider.png.write(to:url,options:.withoutOverwriting);completionHandler(nil) }
        catch { completionHandler(error) }
    }
    func operationQueue(for filePromiseProvider:NSFilePromiseProvider) -> OperationQueue { writeQueue }
}

final class ScreenshotPromise:NSFilePromiseProvider {
    let png:Data
    let writer:ScreenshotPromiseWriter
    init(data:Data) {
        png = data;writer = ScreenshotPromiseWriter()
        super.init()
        fileType = UTType.png.identifier;delegate = writer
    }
    override func writableTypes(for pasteboard:NSPasteboard) -> [NSPasteboard.PasteboardType] { super.writableTypes(for:pasteboard)+[.png] }
    override func pasteboardPropertyList(forType type:NSPasteboard.PasteboardType) -> Any? { type == .png ? png : super.pasteboardPropertyList(forType:type) }
}
