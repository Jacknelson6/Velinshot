import AppKit
import Foundation

let app = NSApplication.shared
if CommandLine.arguments.contains("--render-studio") || CommandLine.arguments.contains("--smoke-check") {
    app.setActivationPolicy(.prohibited)
    app.finishLaunching()
}
if let index = CommandLine.arguments.firstIndex(of:"--render-studio"),CommandLine.arguments.indices.contains(index+1) {
    do { try StudioSnapshots.run(directory:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true));exit(0) }
    catch { fputs("Studio view export failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--smoke-check"),CommandLine.arguments.indices.contains(index+1) {
    do { try DemoFixture.smokeCheck(directory:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true));exit(0) }
    catch { fputs("Smoke check failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
