import AppKit
import VelinshotCore
import Sparkle

enum UpdaterChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VelinshotError.invalidImage("Updater check failed: \(message)") }
            count += 1
        }
        for capturing in [false, true] {
            for importing in [false, true] {
                for editorCount in [0, 1, 3] {
                    for modal in [false, true] {
                        let state = UpdateWorkState(capturing: capturing, preparingImage: importing, openEditors: editorCount, modal: modal)
                        let expected = !capturing && !importing && editorCount == 0 && !modal
                        try check(state.mayRestart == expected, "capture/import/open-editor/modal restart safety")
                    }
                }
            }
        }
        // Non-vector metadata fixture only. It does not provision a real signing key.
        var info: [String: Any] = [
            "SUFeedURL": UpdateConfiguration.feedURL,
            "SUPublicEDKey": Data((1...32).map { UInt8($0) }).base64EncodedString(),
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableSystemProfiling": false, "SUAutomaticallyUpdate": false, "SUAllowsAutomaticUpdates": false,
            "SUEnableAutomaticChecks": false, "SUEnableJavaScript": false, "SUShowReleaseNotes": false
        ]
        try check(UpdateConfiguration.problem(in: info) == nil, "well-formed, fail-closed configuration is accepted")
        let original = info
        info["SUPublicEDKey"] = UpdateConfiguration.fixturePublicKey
        try check(UpdateConfiguration.problem(in: info) != nil, "public RFC signing key is refused in production")
        for feed in ["http://raw.githubusercontent.com/Jacknelson6/Velinshot/updates/appcast.xml", "https://example.com/appcast.xml", UpdateConfiguration.feedURL + "?tracking=1"] {
            info = original; info["SUFeedURL"] = feed
            try check(UpdateConfiguration.problem(in: info) != nil, "untrusted or altered production feed is rejected")
        }
        for publicKey in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 0, count: 32).base64EncodedString()] {
            info = original; info["SUPublicEDKey"] = publicKey
            try check(UpdateConfiguration.problem(in: info) != nil, "missing, malformed, short or zero public key is rejected")
        }
        for flag in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            info = original; info[flag] = false
            try check(UpdateConfiguration.problem(in: info) != nil, "signature enforcement cannot be disabled")
        }
        info = original; info["SUSignedFeedFailureExpirationInterval"] = 1728000
        try check(UpdateConfiguration.problem(in: info) != nil, "feed verification cannot expire into fallback")
        for expiry in [false, 0.0, "0"] as [Any] {
            info = original; info["SUSignedFeedFailureExpirationInterval"] = expiry
            try check(UpdateConfiguration.problem(in: info) != nil, "feed expiry requires an integer, not an equivalent boolean, float or string")
        }
        for flag in ["SUEnableSystemProfiling", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableAutomaticChecks", "SUEnableJavaScript", "SUShowReleaseNotes"] {
            info = original; info[flag] = true
            try check(UpdateConfiguration.problem(in: info) != nil, "profiling and silent installation stay disabled")
            info = original; info.removeValue(forKey: flag)
            try check(UpdateConfiguration.problem(in: info) != nil, "required off-default behavior cannot silently revert to Sparkle defaults")
        }
        info = original; info.removeValue(forKey: "SUPublicEDKey")
        try check(UpdateConfiguration.problem(in: info) != nil, "unprovisioned source build stays unconfigured")
        // No Sparkle start/network check: exercise the actual delegate and termination backstop.
        let nativeController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        var work = UpdateWorkState()
        var notices: [String] = []
        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("VelinshotUpdaterChecks-" + UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: fixtureURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        var fixtureInfo = original
        fixtureInfo["CFBundleIdentifier"] = "com.jacknelson.velinshot.update-checks." + UUID().uuidString
        fixtureInfo["CFBundlePackageType"] = "BNDL"
        try PropertyListSerialization.data(fromPropertyList: fixtureInfo, format: .xml, options: 0).write(to: fixtureURL.appendingPathComponent("Contents/Info.plist"))
        guard let fixtureBundle = Bundle(url: fixtureURL) else { throw VelinshotError.invalidImage("Cannot create updater metadata fixture.") }
        let controller = UpdaterController(bundle: fixtureBundle, notice: { notices.append($0) }, workState: { work })
        let blockedStates = [UpdateWorkState(capturing: true), UpdateWorkState(preparingImage: true), UpdateWorkState(openEditors: 1), UpdateWorkState(modal: true)]
        for blocked in blockedStates {
            work = blocked
            try check(!controller.updaterShouldRelaunchApplication(nativeController.updater), "busy-first actual delegate refuses installation")
            try check(controller.installationPending, "busy-first decision defensively arms termination guard before willInstall")
            try check(!controller.mayTerminateForUpdate() && !controller.mayTerminateForUpdate(), "busy-first repeated termination cannot lose work")
            controller.updater(nativeController.updater, didFinishUpdateCycleFor: .updates, error: nil)
            try check(!controller.installationPending && controller.mayTerminateForUpdate(), "busy-first cycle cleanup restores ordinary quit")
            work = UpdateWorkState()
            try check(controller.updaterShouldRelaunchApplication(nativeController.updater), "idle actual delegate permits user-driven install")
            try check(controller.installationPending, "actual delegate arms the termination backstop")
            work = blocked
            try check(!controller.updaterShouldRelaunchApplication(nativeController.updater), "actual delegate rejects new busy work before install")
            try check(controller.installationPending, "busy denial cannot disarm an already pending cycle")
            try check(!controller.mayTerminateForUpdate(), "first busy termination is denied")
            try check(!controller.mayTerminateForUpdate(), "repeated busy termination stays denied")
            try check(controller.installationPending, "backstop remains armed until the update cycle ends")
            do {
                try controller.updater(nativeController.updater, mayPerform: .updates)
                try check(false, "busy user-initiated update check must throw")
            } catch {
                try check((error as NSError).domain == "com.jacknelson.velinshot.updates", "busy check reports an actionable app error")
            }
            controller.updater(nativeController.updater, didFinishUpdateCycleFor: .updates, error: nil)
            try check(!controller.installationPending && controller.mayTerminateForUpdate(), "cycle cleanup releases only the updater-owned termination guard")
        }
        work = UpdateWorkState()
        _ = controller.updaterShouldRelaunchApplication(nativeController.updater)
        work = UpdateWorkState(openEditors: 1)
        let feedbackBefore = notices.count
        _ = controller.mayTerminateForUpdate(); _ = controller.mayTerminateForUpdate()
        try check(notices.count == feedbackBefore + 1, "a race into busy termination gives feedback once per cycle")
        controller.updater(nativeController.updater, didFinishUpdateCycleFor: .updates, error: nil)
        work = UpdateWorkState(openEditors: 1)
        _ = controller.updaterShouldRelaunchApplication(nativeController.updater)
        var stateNotices = 0
        let observer = NotificationCenter.default.addObserver(forName: UpdaterController.stateChanged, object: controller, queue: nil) { _ in stateNotices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.workStateDidChange()
        try check(controller.settingsDescription.contains("close open screenshots"), "busy work exposes an actionable Settings note")
        work = UpdateWorkState(); controller.workStateDidChange()
        try check(!controller.settingsDescription.contains("close open screenshots"), "finishing work clears the blocked-update note")
        try check(stateNotices == 2, "work state transitions notify open Settings without a timer")
        try check(!notices.isEmpty, "blocked install gives feedback without opening real UI during checks")
        return count
    }
}
