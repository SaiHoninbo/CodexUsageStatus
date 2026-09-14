import AppKit
import Foundation

struct AppUpdateRelease: Equatable, Identifiable {
    let version: String
    let tagName: String
    let name: String
    let releaseURL: URL
    let notes: String
    let publishedAt: Date?

    var id: String { version }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case downloading(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case error(String)

    var release: AppUpdateRelease? {
        if case .available(let release) = self { return release }
        if case .downloading(let release) = self { return release }
        if case .installing(let release) = self { return release }
        return nil
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .available, .error:
            return false
        }
    }
}

enum AppUpdateError: LocalizedError {
    case noRelease
    case invalidResponse
    case checkTimedOut
    case checkCancelled
    case httpStatus(Int)
    case assetUnavailable
    case invalidArchive
    case bundleMismatch
    case installFailed

    var errorDescription: String? {
        switch self {
        case .noRelease: return "GitHub 尚未發布正式 Release。"
        case .invalidResponse: return "GitHub 更新資訊格式無法辨識。"
        case .checkTimedOut: return "更新檢查逾時，請確認網路後重試。"
        case .checkCancelled: return "更新檢查已取消。"
        case .httpStatus(let status): return "GitHub 更新服務回應錯誤（HTTP \(status)）。"
        case .assetUnavailable: return "GitHub Release 沒有可用的 CodexUsageStatus.app.zip。"
        case .invalidArchive: return "更新檔案無法驗證，已取消覆蓋。"
        case .bundleMismatch: return "更新檔案不是相容的 Codex Usage Status。"
        case .installFailed: return "更新檔案已下載，但本機覆蓋失敗；目前版本未變更。"
        }
    }
}

enum AppVersionComparator {
    static func normalized(_ value: String) -> [Int] {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = normalized(candidate)
        let rhs = normalized(current)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

enum AppUpdateReleasePolicy {
    static let officialReleasesURL = URL(string: "https://github.com/SaiHoninbo/CodexUsageStatus/releases")!
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/SaiHoninbo/CodexUsageStatus/releases/latest")!
    static let repositoryOwner = "SaiHoninbo"
    static let repositoryName = "CodexUsageStatus"
    static let releaseAssetName = "CodexUsageStatus.app.zip"

    static func safeReleaseURL(_ candidate: URL?) -> URL {
        guard let candidate, isOfficialReleaseURL(candidate) else {
            return officialReleasesURL
        }
        return candidate
    }

    static func isSafeVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil
    }

    static func isOfficialReleaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        guard let decodedPath = url.path.removingPercentEncoding else { return false }
        let components = decodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }),
              components.count >= 3,
              components[0].lowercased() == "saihoninbo",
              components[1].lowercased() == "codexusagestatus",
              components[2].lowercased() == "releases" else { return false }
        return true
    }

    static func assetURL(for release: AppUpdateRelease) -> URL? {
        guard isSafeVersion(release.version),
              release.tagName.range(of: #"^v[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil,
              release.tagName == "v\(release.version)" else { return nil }
        return URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)/releases/download/\(release.tagName)/\(releaseAssetName)")
    }
}

enum AppUpdatePresentationPolicy {
    static let installButtonTitle = "下載並覆蓋"
    static let releaseButtonTitle = "查看 Release"
    /// The replacement helper is bounded independently from AppKit's
    /// termination callback. If termination cannot complete, the running
    /// process gets a recoverable error instead of an endless spinner.
    static let installHandoffTimeout: TimeInterval = 45
}

enum AppUpdateReceiptObservationDecision: Equatable {
    case continueObserving
    case failed(String)
    case succeeded
    case timedOut
}

enum AppUpdateReceiptObservationPolicy {
    static func decision(
        for receipt: AppUpdateReplacementReceipt?,
        receiptData: Data? = nil,
        activeReleaseVersion: String,
        baselineUpdatedAt: Date?,
        baselineReceiptData: Data? = nil,
        now: Date
    ) -> AppUpdateReceiptObservationDecision {
        guard let receipt,
              receipt.releaseVersion == activeReleaseVersion,
              let updatedAt = receipt.updatedAt else {
            return .continueObserving
        }
        if let baselineUpdatedAt {
            let timestampIsNewer = updatedAt > baselineUpdatedAt
            let sameSecondContentChanged = updatedAt == baselineUpdatedAt
                && receiptData != nil
                && receiptData != baselineReceiptData
            if !timestampIsNewer && !sameSecondContentChanged {
                return .continueObserving
            }
        }
        switch receipt.status {
        case .installing:
            return .continueObserving
        case .failed:
            return .failed(receipt.displayMessage)
        case .succeeded:
            return .succeeded
        }
    }
}

/// Small, private-to-the-app hand-off receipt written by the replacement
/// helper. It is deliberately a line-oriented file so the shell helper can
/// update it atomically without depending on a JSON encoder or another
/// process. A failed receipt is surfaced on the next launch, while a recent
/// installing receipt for the current version is treated as a successful
/// relaunch race and allowed to settle to `succeeded`.
struct AppUpdateReplacementReceipt: Equatable {
    enum Status: String, Equatable {
        case installing
        case succeeded
        case failed
    }

    let status: Status
    let step: String
    let message: String
    let releaseVersion: String?
    let updatedAt: Date?

    static func parse(_ data: Data) -> Self? {
        let fields = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1])
            }
        guard let rawStatus = fields["status"], let status = Status(rawValue: rawStatus) else { return nil }
        let updatedAt = fields["updatedAt"].flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
        return Self(
            status: status,
            step: fields["step"] ?? "unknown",
            message: fields["message"] ?? "",
            releaseVersion: fields["releaseVersion"],
            updatedAt: updatedAt
        )
    }

    var displayMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "更新替換流程未完成（\(step)）。" : trimmed
    }
}

enum AppUpdateReplacementReceiptStore {
    static let receiptFileName = "update-replacement-receipt.txt"
    static let logFileName = "update-replacement.log"

    static func defaultReceiptURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
            .appendingPathComponent(receiptFileName)
    }

    static func defaultLogURL(fileManager: FileManager = .default) -> URL {
        defaultReceiptURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(logFileName)
    }
}

/// Keeps automatic GitHub checks responsive to a newly published release
/// without turning every HUD/popover interaction into a network request.
/// Manual checks continue to bypass this gate.
enum AppUpdateCheckPolicy {
    static let automaticInterval: TimeInterval = 15 * 60

    static func shouldStartAutomaticCheck(
        now: Date,
        lastCheckAt: Date?,
        isBusy: Bool
    ) -> Bool {
        guard !isBusy else { return false }
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= automaticInterval
    }
}

@MainActor
final class AppUpdateService: NSObject {
    private struct ReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let body: String?
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case publishedAt = "published_at"
        }
    }

    var onStateChange: ((AppUpdateState) -> Void)?

    private let endpoint = AppUpdateReleasePolicy.latestReleaseAPIURL
    private let repositoryURL = AppUpdateReleasePolicy.officialReleasesURL
    private let session: URLSession
    private let checkTimeout: TimeInterval
    private let replacementReceiptURL: URL
    private(set) var state: AppUpdateState = .idle
    private var checkTask: URLSessionDataTask?
    private var downloadTask: URLSessionDownloadTask?
    private var checkTimeoutTimer: Timer?
    private var checkGeneration: UInt64 = 0
    private var checkCompletion: ((AppUpdateState) -> Void)?
    private let receiptObservationQueue = DispatchQueue(
        label: "com.openai.codex-usage-status.update-receipt-observer",
        qos: .utility
    )
    private var receiptObservationTimer: DispatchSourceTimer?
    private var receiptObservationGeneration: UInt64 = 0

    init(
        session: URLSession = .shared,
        checkTimeout: TimeInterval = 20,
        replacementReceiptURL: URL = AppUpdateReplacementReceiptStore.defaultReceiptURL()
    ) {
        self.session = session
        self.checkTimeout = max(0.1, checkTimeout)
        self.replacementReceiptURL = replacementReceiptURL
        super.init()
    }

    var currentVersion: String { AppVersion.current }

    /// Recover a helper failure (or an interrupted hand-off) from the last
    /// process launch. This keeps the UI truthful even though a successful
    /// update terminates the old app before the helper finishes.
    func start() {
        guard let data = try? Data(contentsOf: replacementReceiptURL),
              let receipt = AppUpdateReplacementReceipt.parse(data) else { return }
        switch receipt.status {
        case .succeeded:
            // The successful receipt is only a hand-off marker. Remove it
            // after the new process has observed it so a later launch cannot
            // mistake an old result for a current failure.
            try? FileManager.default.removeItem(at: replacementReceiptURL)
        case .failed:
            finishInstall(.error("更新失敗：\(receipt.displayMessage)"))
        case .installing:
            // The new process can start just before the helper writes the
            // final receipt. A recent receipt matching the current version is
            // that harmless race; an older or stale receipt means the
            // hand-off did not finish and must be actionable.
            if receipt.releaseVersion == currentVersion,
               let updatedAt = receipt.updatedAt,
               Date().timeIntervalSince(updatedAt) < AppUpdatePresentationPolicy.installHandoffTimeout {
                return
            }
            guard receipt.releaseVersion == currentVersion else {
                finishInstall(.error("更新未完成：\(receipt.displayMessage)"))
                return
            }
            finishInstall(.error("更新未完成：\(receipt.displayMessage)"))
        }
    }

    func check(completion: ((AppUpdateState) -> Void)? = nil) {
        invalidateCheck(notify: false)
        checkGeneration &+= 1
        let generation = checkGeneration
        checkCompletion = completion
        state = .checking
        onStateChange?(.checking)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = checkTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageStatus/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.checkGeneration, self.state == .checking else { return }
                if let error {
                    self.finishCheck(.error("更新檢查失敗：\(error.localizedDescription)"))
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    self.finishCheck(.error(AppUpdateError.noRelease.localizedDescription))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.finishCheck(.error(AppUpdateError.httpStatus(http.statusCode).localizedDescription))
                    return
                }
                guard let data else {
                    self.finishCheck(.error(AppUpdateError.invalidResponse.localizedDescription))
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let payload = try decoder.decode(ReleaseResponse.self, from: data)
                    let version = payload.tagName.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
                    guard AppUpdateReleasePolicy.isSafeVersion(version),
                          AppUpdateReleasePolicy.isOfficialReleaseURL(payload.htmlURL) else {
                        self.finishCheck(.error(AppUpdateError.invalidResponse.localizedDescription))
                        return
                    }
                    let release = AppUpdateRelease(
                        version: version,
                        tagName: payload.tagName,
                        name: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
                        releaseURL: payload.htmlURL,
                        notes: payload.body ?? "",
                        publishedAt: payload.publishedAt
                    )
                    guard AppVersionComparator.isNewer(release.version, than: self.currentVersion) else {
                        self.finishCheck(.upToDate)
                        return
                    }
                    self.finishCheck(.available(release))
                } catch {
                    self.finishCheck(.error("更新資訊無法解析：\(error.localizedDescription)"))
                }
            }
        }
        checkTask = task
        task.resume()

        let timer = Timer(timeInterval: checkTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timeoutCheck(generation: generation)
            }
        }
        checkTimeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(state.release?.releaseURL ?? repositoryURL)
    }

    /// Downloads the fixed official release asset, validates the bundle, and
    /// schedules a one-shot replacement of the currently running app. The
    /// replacement helper waits for this process to terminate, then moves
    /// the old bundle aside before installing the new one, so a failed move
    /// restores the old app instead of deleting it or launching two copies.
    func install(_ release: AppUpdateRelease) {
        guard case .available(let available) = state,
              available.version == release.version,
              !state.isBusy,
              let assetURL = AppUpdateReleasePolicy.assetURL(for: release) else {
            return
        }

        state = .downloading(release)
        onStateChange?(state)

        var request = URLRequest(url: assetURL)
        request.httpMethod = "GET"
        request.timeoutInterval = checkTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageStatus/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        downloadTask = session.downloadTask(with: request) { [weak self] location, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadTask = nil
                guard case .downloading(let activeRelease) = self.state,
                      activeRelease.version == release.version else { return }
                if error != nil,
                   (error as NSError?)?.code != NSURLErrorCancelled {
                    self.finishInstall(.error(AppUpdateError.installFailed.localizedDescription))
                    return
                }
                guard let location,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    self.finishInstall(.error(AppUpdateError.assetUnavailable.localizedDescription))
                    return
                }
                do {
                    let baselineReceiptData = self.readReplacementReceiptData()
                    let baselineUpdatedAt = baselineReceiptData
                        .flatMap(AppUpdateReplacementReceipt.parse)
                        .flatMap(\.updatedAt)
                    let plan = try AppUpdateInstaller.prepare(
                        archiveURL: location,
                        release: activeRelease,
                        currentBundleURL: Bundle.main.bundleURL
                    )
                    self.state = .installing(activeRelease)
                    self.onStateChange?(self.state)
                    try AppUpdateInstaller.schedule(plan: plan)
                    self.startReceiptObservation(
                        for: activeRelease,
                        baselineUpdatedAt: baselineUpdatedAt,
                        baselineReceiptData: baselineReceiptData
                    )
                    NSApp.terminate(nil)
                } catch let error as AppUpdateError {
                    self.finishInstall(.error(error.localizedDescription))
                } catch {
                    self.finishInstall(.error(AppUpdateError.installFailed.localizedDescription))
                }
            }
        }
        downloadTask?.resume()
    }

    private func finishCheck(_ newState: AppUpdateState, completion: ((AppUpdateState) -> Void)? = nil) {
        checkTimeoutTimer?.invalidate()
        checkTimeoutTimer = nil
        checkTask = nil
        state = newState
        onStateChange?(newState)
        let callback = completion ?? checkCompletion
        checkCompletion = nil
        callback?(newState)
    }

    private func timeoutCheck(generation: UInt64) {
        guard generation == checkGeneration, state == .checking else { return }
        checkGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil
        finishCheck(.error(AppUpdateError.checkTimedOut.localizedDescription))
    }

    private func invalidateCheck(notify: Bool) {
        guard state == .checking || checkTask != nil || checkTimeoutTimer != nil else { return }
        checkGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil
        checkTimeoutTimer?.invalidate()
        checkTimeoutTimer = nil
        if notify {
            finishCheck(.error(AppUpdateError.checkCancelled.localizedDescription))
        } else {
            checkCompletion = nil
        }
    }

    private func finishInstall(_ newState: AppUpdateState) {
        stopReceiptObservation()
        state = newState
        onStateChange?(newState)
    }

    private func readReplacementReceipt() -> AppUpdateReplacementReceipt? {
        guard let data = readReplacementReceiptData() else { return nil }
        return AppUpdateReplacementReceipt.parse(data)
    }

    private func readReplacementReceiptData() -> Data? {
        try? Data(contentsOf: replacementReceiptURL)
    }

    private func stopReceiptObservation() {
        receiptObservationGeneration &+= 1
        receiptObservationTimer?.setEventHandler {}
        receiptObservationTimer?.cancel()
        receiptObservationTimer = nil
    }

    private func startReceiptObservation(
        for release: AppUpdateRelease,
        baselineUpdatedAt: Date?,
        baselineReceiptData: Data?
    ) {
        stopReceiptObservation()
        receiptObservationGeneration &+= 1
        let generation = receiptObservationGeneration
        let receiptURL = replacementReceiptURL
        let queue = receiptObservationQueue
        let deadline = Date().addingTimeInterval(AppUpdatePresentationPolicy.installHandoffTimeout)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            let receiptData = try? Data(contentsOf: receiptURL)
            let receipt = receiptData.flatMap(AppUpdateReplacementReceipt.parse)
            let observedDecision = AppUpdateReceiptObservationPolicy.decision(
                for: receipt,
                receiptData: receiptData,
                activeReleaseVersion: release.version,
                baselineUpdatedAt: baselineUpdatedAt,
                baselineReceiptData: baselineReceiptData,
                now: Date()
            )
            let decision: AppUpdateReceiptObservationDecision
            switch observedDecision {
            case .failed, .succeeded:
                // A terminal receipt wins even when it lands on the timeout
                // boundary; the bounded timeout only applies to observation.
                decision = observedDecision
            case .continueObserving:
                decision = Date() >= deadline ? .timedOut : .continueObserving
            case .timedOut:
                decision = .timedOut
            }
            guard decision != .continueObserving else { return }
            Task { @MainActor [weak self] in
                self?.handleReceiptObservation(
                    decision,
                    release: release,
                    generation: generation
                )
            }
        }
        receiptObservationTimer = timer
        timer.resume()
    }

    private func handleReceiptObservation(
        _ decision: AppUpdateReceiptObservationDecision,
        release: AppUpdateRelease,
        generation: UInt64
    ) {
        guard generation == receiptObservationGeneration,
              case .installing(let activeRelease) = state,
              activeRelease.version == release.version else { return }
        switch decision {
        case .continueObserving:
            return
        case .failed(let message):
            finishInstall(.error("更新未完成：\(message)"))
        case .succeeded:
            // A successful receipt can race the old process' termination and
            // the next launch. It must stop observation without turning a
            // completed hand-off into an error.
            stopReceiptObservation()
        case .timedOut:
            finishInstall(.error("更新未完成：替換 helper 未在期限內完成。"))
        }
    }
}

enum AppUpdateInstaller {
    struct Plan {
        let rootURL: URL
        let newBundleURL: URL
        let currentBundleURL: URL
        let backupName: String
        let receiptURL: URL
        let logURL: URL
        let releaseVersion: String
    }

    static func prepare(
        archiveURL: URL,
        release: AppUpdateRelease,
        currentBundleURL: URL
    ) throws -> Plan {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageStatus-update-\(UUID().uuidString)", isDirectory: true)
        let extractionURL = rootURL.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionURL, withIntermediateDirectories: true)

        let entries = try run("/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !entries.isEmpty,
              entries.allSatisfy(isSafeArchiveEntry),
              entries.contains("CodexUsageStatus.app/Contents/Info.plist"),
              entries.contains("CodexUsageStatus.app/Contents/MacOS/CodexUsageStatus") else {
            throw AppUpdateError.invalidArchive
        }

        _ = try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractionURL.path])
        let newBundleURL = extractionURL.appendingPathComponent("CodexUsageStatus.app", isDirectory: true)
        guard let bundle = Bundle(url: newBundleURL),
              bundle.bundleIdentifier == AccessibilityPermissionContinuityPolicy.bundleIdentifier,
              bundle.executableURL?.lastPathComponent == "CodexUsageStatus",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              AppVersionComparator.isNewer(release.version, than: AppVersion.current) else {
            throw AppUpdateError.bundleMismatch
        }
        _ = try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", newBundleURL.path])

        return Plan(
            rootURL: rootURL,
            newBundleURL: newBundleURL,
            currentBundleURL: currentBundleURL,
            backupName: "CodexUsageStatus.backup-\(UUID().uuidString)",
            receiptURL: AppUpdateReplacementReceiptStore.defaultReceiptURL(),
            logURL: AppUpdateReplacementReceiptStore.defaultLogURL(),
            releaseVersion: release.version
        )
    }

    static func schedule(plan: Plan) throws {
        let scriptURL = plan.rootURL.appendingPathComponent("replace-and-relaunch.sh")
        let script = replacementScript(
            oldPath: plan.currentBundleURL.path,
            newPath: plan.newBundleURL.path,
            backupPath: plan.currentBundleURL.deletingLastPathComponent().appendingPathComponent(plan.backupName).path,
            rootPath: plan.rootURL.path,
            receiptPath: plan.receiptURL.path,
            logPath: plan.logURL.path,
            releaseVersion: plan.releaseVersion
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try FileManager.default.createDirectory(
            at: plan.receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: plan.logURL.path) {
            FileManager.default.createFile(atPath: plan.logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let logHandle = try FileHandle(forWritingTo: plan.logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
    }

    /// Generates the one-shot replacement script separately from process
    /// launching so the termination hand-off remains deterministic and
    /// reviewable. The parent PID is the currently running app because the
    /// script is spawned directly by `AppUpdateService.install`.
    static func replacementScript(
        oldPath: String,
        newPath: String,
        backupPath: String,
        rootPath: String,
        receiptPath: String? = nil,
        logPath: String? = nil,
        releaseVersion: String = "unknown"
    ) -> String {
        let resolvedReceiptPath = receiptPath ?? URL(fileURLWithPath: rootPath).appendingPathComponent(AppUpdateReplacementReceiptStore.receiptFileName).path
        let resolvedLogPath = logPath ?? URL(fileURLWithPath: rootPath).appendingPathComponent(AppUpdateReplacementReceiptStore.logFileName).path
        return """
        #!/bin/sh
        set -eu
        OLD=\(shellQuote(oldPath))
        NEW=\(shellQuote(newPath))
        BACKUP=\(shellQuote(backupPath))
        ROOT=\(shellQuote(rootPath))
        RECEIPT=\(shellQuote(resolvedReceiptPath))
        LOG=\(shellQuote(resolvedLogPath))
        RELEASE_VERSION=\(shellQuote(releaseVersion))
        APP_PID=$PPID
        WAIT_DEADLINE=$(($(date +%s) + 30))
        mkdir -p "$(dirname "$RECEIPT")"
        touch "$LOG"
        exec >> "$LOG" 2>&1
        write_receipt() {
            STATUS="$1"
            STEP="$2"
            MESSAGE="$3"
            RECEIPT_TMP="$RECEIPT.tmp.$$"
            {
                printf 'status=%s\\n' "$STATUS"
                printf 'step=%s\\n' "$STEP"
                printf 'message=%s\\n' "$MESSAGE"
                printf 'releaseVersion=%s\\n' "$RELEASE_VERSION"
                printf 'updatedAt=%s\\n' "$(date +%s)"
            } > "$RECEIPT_TMP"
            mv "$RECEIPT_TMP" "$RECEIPT"
        }
        fail() {
            write_receipt failed "$1" "$2"
            exit 1
        }
        restore_old() {
            FAILED_NEW="$ROOT/CodexUsageStatus.failed-$$"
            if [ ! -d "$OLD" ] || [ ! -d "$BACKUP" ]; then return 1; fi
            if ! mv "$OLD" "$FAILED_NEW"; then return 1; fi
            if ! mv "$BACKUP" "$OLD"; then
                mv "$FAILED_NEW" "$OLD" || true
                return 1
            fi
            return 0
        }
        write_receipt installing helper_started "Replacement helper started."
        sleep 1
        if [ ! -d \"$NEW\" ]; then fail new_bundle_missing "The downloaded bundle is missing."; fi
        # NSApp.terminate(nil) is asynchronous: AppDelegate first flushes
        # pending writes and only then replies to AppKit. Wait for the exact
        # old process to disappear before replacing or reopening the bundle;
        # otherwise `open -n` can leave the old and new menu-bar instances
        # alive together. A bounded wait fails closed and leaves the old app
        # untouched if termination cannot be observed.
        write_receipt installing waiting_for_old_process "Waiting for the previous app to exit."
        while kill -0 \"$APP_PID\" 2>/dev/null; do
            if [ \"$(date +%s)\" -ge \"$WAIT_DEADLINE\" ]; then fail old_process_timeout "The previous app did not exit before the replacement deadline."; fi
            sleep 0.2
        done
        write_receipt installing backing_up_old_bundle "Backing up the current app bundle."
        if ! mv \"$OLD\" \"$BACKUP\"; then fail backup_failed "The current app bundle could not be backed up."; fi
        write_receipt installing replacing_bundle "Installing the downloaded app bundle."
        if ! mv \"$NEW\" \"$OLD\"; then
            if mv \"$BACKUP\" \"$OLD\"; then
                fail replacement_failed "The new app bundle could not be installed; the previous version was restored."
            fi
            fail rollback_failed "The new app bundle and its backup could not be restored safely."
        fi
        write_receipt installing relaunching "Launching the updated app."
        if ! /usr/bin/open -n \"$OLD\"; then
            if restore_old; then
                fail relaunch_failed "The updated app could not be launched; the previous version was restored."
            fi
            fail relaunch_rollback_failed "The updated app could not be launched and the previous version could not be restored safely."
        fi
        LAUNCH_DEADLINE=$(($(date +%s) + 15))
        LAUNCHED=0
        while [ "$(date +%s)" -lt "$LAUNCH_DEADLINE" ]; do
            if /bin/ps ax -o command= | /usr/bin/grep -F "$OLD/Contents/MacOS/CodexUsageStatus" | /usr/bin/grep -v grep >/dev/null 2>&1; then
                LAUNCHED=1
                break
            fi
            sleep 0.2
        done
        if [ "$LAUNCHED" -ne 1 ]; then
            if restore_old; then
                fail relaunch_failed "The updated app did not appear after launch was requested; the previous version was restored."
            fi
            fail relaunch_rollback_failed "The updated app did not appear and the previous version could not be restored safely."
        fi
        write_receipt succeeded completed "Update completed successfully."
        (sleep 10; /bin/rm -rf \"$BACKUP\" \"$ROOT\") >/dev/null 2>&1 &
        """
    }

    private static func isSafeArchiveEntry(_ entry: String) -> Bool {
        let normalized = entry.replacingOccurrences(of: "\\\\", with: "/")
        return normalized.hasPrefix("CodexUsageStatus.app/")
            && !normalized.split(separator: "/").contains("..")
            && !normalized.hasPrefix("/")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw AppUpdateError.invalidArchive }
        return String(decoding: data, as: UTF8.self)
    }
}
