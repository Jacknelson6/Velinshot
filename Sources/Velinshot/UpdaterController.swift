import AppKit
import Sparkle
import CoreFoundation

struct UpdateWorkState {
    var capturing = false
    var preparingImage = false
    var openEditors = 0
    var modal = false
    var mayRestart: Bool { !capturing && !preparingImage && openEditors == 0 && !modal }
}

enum UpdateConfiguration {
    static let feedURL = "https://raw.githubusercontent.com/Jacknelson6/Velinshot/updates/appcast.xml"
    static let fixturePublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
    static func problem(in info: [String: Any], trustedFeedURL: String = feedURL) -> String? {
        validate(info, trustedFeedURL: trustedFeedURL, fixture: false)
    }
#if VELINSHOT_UPDATER_FIXTURE
    static func fixtureProblem(in info: [String: Any], trustedFeedURL: String) -> String? {
        validate(info, trustedFeedURL: trustedFeedURL, fixture: true)
    }
#endif
    private static func validate(_ info: [String: Any], trustedFeedURL: String, fixture: Bool) -> String? {
        guard info["SUFeedURL"] as? String == trustedFeedURL else { return "This build has no trusted update feed." }
        guard let encoded = info["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              key.contains(where: { $0 != 0 }) else { return "Updates are not configured in this source build." }
        let testKey = Data(base64Encoded: fixturePublicKey)!
        guard (fixture ? key == testKey : key != testKey) else { return "The public test signing key cannot authorize production updates." }
        guard boolean(info["SURequireSignedFeed"], equals: true),
              boolean(info["SUVerifyUpdateBeforeExtraction"], equals: true),
              let expiry = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: expiry.objCType)), expiry.int64Value == 0 else {
            return "This build does not require authenticated update feeds and archives."
        }
        guard ["SUEnableSystemProfiling", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableAutomaticChecks", "SUEnableJavaScript", "SUShowReleaseNotes"].allSatisfy({ boolean(info[$0], equals: false) }) else {
            return "This build has unsupported automatic installation settings."
        }
        return nil
    }
    private static func boolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }
}

final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let stateChanged = Notification.Name("VelinshotUpdateStateChanged")
    private let workState: () -> UpdateWorkState
    private let bundle: Bundle
    private let notice: ((String) -> Void)?
    private var trustedFeedURL = UpdateConfiguration.feedURL
    private var controller: SPUStandardUpdaterController?
    private var checkingObservation: NSKeyValueObservation?
    private var preferenceObservation: NSKeyValueObservation?
    private(set) var installationPending = false
    private var terminationFeedbackShown = false
    private(set) var statusMessage: String?
    var configured: Bool { configurationProblem == nil }
    var canCheckForUpdates: Bool { configured && controller?.updater.canCheckForUpdates == true && workState().mayRestart }

    init(bundle: Bundle = .main, notice: ((String) -> Void)? = nil, workState: @escaping () -> UpdateWorkState) {
        self.bundle = bundle; self.workState = workState; self.notice = notice
        super.init()
    }
    private var configurationProblem: String? {
#if VELINSHOT_UPDATER_FIXTURE
        if fixtureMode { return UpdateConfiguration.fixtureProblem(in: bundle.infoDictionary ?? [:], trustedFeedURL: trustedFeedURL) }
#endif
        return UpdateConfiguration.problem(in: bundle.infoDictionary ?? [:], trustedFeedURL: trustedFeedURL)
    }
#if VELINSHOT_UPDATER_FIXTURE
    var onFixtureEvent: ((String, String?) -> Void)?
    private var fixtureMode = false
    convenience init(fixtureBundle: Bundle, notice: @escaping (String) -> Void, workState: @escaping () -> UpdateWorkState) {
        let feed = fixtureBundle.infoDictionary?["SUFeedURL"] as? String ?? ""
        let url = URL(string: feed)
        precondition(fixtureBundle.bundleURL == Bundle.main.bundleURL && fixtureBundle.bundleIdentifier?.hasPrefix("com.jacknelson.velinshot.update-fixture.") == true)
        let staging = url?.path.hasPrefix("/Jacknelson6/Velinshot/updater-fixture-") == true || url?.path.hasPrefix("/Jacknelson6/Velinshot/releases/download/updater-fixture-") == true
        precondition(url?.scheme == "https" && ["github.com", "raw.githubusercontent.com"].contains(url?.host ?? "") && staging && url?.user == nil && url?.password == nil && url?.query == nil && url?.fragment == nil)
        self.init(bundle: fixtureBundle, notice: notice, workState: workState)
        trustedFeedURL = feed
        fixtureMode = true
    }
#endif
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard configured else { return }
            controller?.updater.automaticallyChecksForUpdates = newValue
            announceChange()
        }
    }
    var settingsDescription: String {
        if let problem = configurationProblem { return problem }
        if !workState().mayRestart { return Self.finishWorkMessage }
        return statusMessage ?? "Update checks contact GitHub. Screenshots stay on this Mac."
    }
    func start() {
        precondition(Thread.isMainThread)
        guard controller == nil else { return }
        guard let problem = configurationProblem else {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            self.controller = controller
            checkingObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in self?.announceChange() }
            preferenceObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in self?.announceChange() }
            controller.startUpdater()
            return
        }
        statusMessage = problem
        announceChange()
    }
    func checkForUpdates(_ sender: Any?) {
        precondition(Thread.isMainThread)
        guard configured else { showMessage(settingsDescription); return }
        guard workState().mayRestart else { showMessage(Self.finishWorkMessage); return }
        start()
        guard controller?.updater.canCheckForUpdates == true else { return }
        statusMessage = nil
        controller?.checkForUpdates(sender)
        reportFixtureEvent("check")
    }
    func workStateDidChange() {
        if workState().mayRestart && [Self.finishWorkMessage, Self.pendingWorkMessage].contains(statusMessage ?? "") { statusMessage = nil }
        announceChange()
    }
    func mayTerminateForUpdate() -> Bool {
        guard installationPending else { return true }
        let state = workState()
        let safe = state.mayRestart
        if !safe {
            statusMessage = Self.pendingWorkMessage; announceChange(); reportFixtureEvent("terminationDenied")
            if !state.capturing && !state.modal && !terminationFeedbackShown {
                terminationFeedbackShown = true; showMessage(Self.pendingWorkMessage)
            }
        }
        return safe
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard workState().mayRestart else {
            throw NSError(domain: "com.jacknelson.velinshot.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: Self.finishWorkMessage])
        }
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        armInstallationCycle()
        let state = workState()
        guard state.mayRestart else {
            statusMessage = Self.finishWorkMessage; announceChange()
            reportFixtureEvent("relaunchDenied")
            if !state.capturing && !state.modal && !terminationFeedbackShown { terminationFeedbackShown = true; showMessage(Self.finishWorkMessage) }
            return false
        }
        reportFixtureEvent("relaunchAllowed")
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { armInstallationCycle(); reportFixtureEvent("willInstall") }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        installationPending = false
        terminationFeedbackShown = false
        if let error { statusMessage = error.localizedDescription }
        reportFixtureEvent("cycleFinished", error: error?.localizedDescription ?? "none")
        announceChange()
    }
    private static let finishWorkMessage = "Finish the capture or import and close open screenshots and dialogs, then check for updates again."
    private static let pendingWorkMessage = "Finish the capture or import and close open screenshots and dialogs before Velinshot can quit for this update."
    private func armInstallationCycle() {
        if !installationPending { terminationFeedbackShown = false }
        installationPending = true
    }
    private func showMessage(_ message: String) {
        statusMessage = message; announceChange()
        if let notice { notice(message); return }
        let alert = NSAlert(); alert.messageText = "Velinshot updates"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private func reportFixtureEvent(_ event: String, error: String? = nil) {
#if VELINSHOT_UPDATER_FIXTURE
        onFixtureEvent?(event, error)
#endif
    }
    private func announceChange() { NotificationCenter.default.post(name: Self.stateChanged, object: self) }
}
