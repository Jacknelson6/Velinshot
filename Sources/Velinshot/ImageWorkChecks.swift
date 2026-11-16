import AppKit
import VelinshotCore

enum ImageWorkChecks {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition:Bool,_ message:String) throws {
            guard condition else { throw VelinshotError.invalidImage("Image-work check failed: \(message)") };checks += 1
        }
        var workers:[()->Void] = [],deliveries:[()->Void] = [],installed:[Int] = [],errors = 0
        let work = LatestImageWork<Int>(schedule:{workers.append($0)},deliver:{deliveries.append($0)})
        func receive(_ result:Result<Int,Error>) { switch result { case .success(let value):installed.append(value);case .failure:errors += 1 } }
        work.submit(work:{_ in 1},completion:receive)
        workers.removeFirst()() // A finishes decode; its main-queue delivery is pending.
        work.submit(work:{_ in 2},completion:receive)
        deliveries.removeFirst()()
        try check(installed.isEmpty,"A cannot install after B supersedes it")
        workers.removeFirst()();deliveries.removeFirst()()
        try check(installed == [2] && !work.isBusy,"B installs once and clears busy state")

        work.submit(work:{_ in 3},completion:receive);workers.removeFirst()();work.cancel();deliveries.removeFirst()()
        try check(installed == [2],"cancel during completed decode suppresses delivery")
        var staleRan = false
        work.submit(work:{_ in staleRan = true;return 4},completion:receive)
        work.submit(work:{_ in 5},completion:receive)
        workers.removeFirst()();workers.removeFirst()();deliveries.removeFirst()()
        try check(!staleRan && installed == [2,5],"superseded queued work avoids decoding entirely")

        work.submit(work:{_ in throw VelinshotError.invalidImage("Synthetic stale error")},completion:receive);workers.removeFirst()()
        work.submit(work:{_ in 6},completion:receive);workers.removeFirst()()
        deliveries.removeLast()();deliveries.removeFirst()()
        try check(installed == [2,5,6] && errors == 0,"stale error cannot replace a newer capture or show an alert")
        var cancelledInside = false
        work.submit(work:{ ticket in work.cancel();cancelledInside = true;try ticket.checkpoint();return 7 },completion:receive)
        workers.removeFirst()();deliveries.removeFirst()()
        try check(cancelledInside && installed == [2,5,6] && errors == 0,"cancel at an in-flight checkpoint never installs its output")

        var busyDuringBatch:[Bool] = []
        var batchDecoded:[Int] = []
        work.submitBatch([{_ in batchDecoded.append(8);return 8},{_ in batchDecoded.append(9);return 9}]) { result in receive(result);busyDuringBatch.append(work.isBusy) }
        workers.removeFirst()()
        try check(batchDecoded == [8] && workers.isEmpty,"a batch cannot decode ahead of main-thread presentation")
        deliveries.removeFirst()();workers.removeFirst()();deliveries.removeFirst()()
        try check(Array(installed.suffix(2)) == [8,9],"multiple selected files retain order in one serial batch")
        try check(busyDuringBatch == [true,false],"batch remains busy until its last atomic install")

        let source = try DemoFixture.make()
        var rejectedMainThread = false
        do { _ = try DocumentPreparation.prepare(.image(source),style:CanvasStyle(),title:"Mis-scheduled fixture",ticket:ImageWorkTicket()) }
        catch { rejectedMainThread = true }
        try check(rejectedMainThread,"a mis-scheduled load reports an error instead of terminating the app")
        final class PreparationBox { var result:Result<PreparedDocument,Error>? }
        let box = PreparationBox(),finished = DispatchSemaphore(value:0)
        ImageWork.queue.async {
            box.result = Result { try DocumentPreparation.prepare(.image(source),style:CanvasStyle(autoBalance:false),title:"Worker fixture",ticket:ImageWorkTicket()) }
            finished.signal()
        }
        guard finished.wait(timeout:.now()+10) == .success,let result = box.result else { throw VelinshotError.invalidImage("Source worker did not finish its bounded check.") }
        let prepared = try result.get()
        try check(prepared.source === source,"capture preparation retains original pixels without an encode/decode cycle")
        try check(prepared.preview.sourceSize == CGSize(width:source.width,height:source.height),"prepared proxy keeps original source coordinates")
        try check(max(prepared.preview.pixelSize.width,prepared.preview.pixelSize.height)<=1400,"prepared preview is bounded")
        try check(prepared.analysis.bounds == nil && prepared.state.crop == nil,"disabled automatic balance avoids unnecessary full-resolution analysis")
        return checks
    }
}
