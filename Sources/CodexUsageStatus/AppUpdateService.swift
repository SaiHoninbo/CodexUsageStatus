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
    private(set) var state: AppUpdateState = .idle
    private var checkTask: URLSessionDataTask?
    private var downloadTask: URLSessionDownloadTask?
    private var checkTimeoutTimer: Timer?
    private var checkGeneration: UInt64 = 0
    private var checkCompletion: ((AppUpdateState) -> Void)?

    init(session: URLSession = .shared, checkTimeout: TimeInterval = 20) {
        self.session = session
        self.checkTimeout = max(0.1, checkTimeout)
        super.init()
    }

    var currentVersion: String { AppVersion.current }

    /// GitHub Release checks have no separate updater startup phase. The
    /// hook preserves UsageViewModel's deferred startup sequencing.
    func start() {}

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
    /// replacement helper moves the old bundle aside before installing the
    /// new one, so a failed move restores the old app instead of deleting it.
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
                    let plan = try AppUpdateInstaller.prepare(
                        archiveURL: location,
                        release: activeRelease,
                        currentBundleURL: Bundle.main.bundleURL
                    )
                    self.state = .installing(activeRelease)
                    self.onStateChange?(self.state)
                    try AppUpdateInstaller.schedule(plan: plan)
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
        state = newState
        onStateChange?(newState)
    }
}

private enum AppUpdateInstaller {
    struct Plan {
        let rootURL: URL
        let newBundleURL: URL
        let currentBundleURL: URL
        let backupName: String
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
              bundle.bundleIdentifier == "com.openai.codex-usage-status",
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
            backupName: "CodexUsageStatus.backup-\(UUID().uuidString)"
        )
    }

    static func schedule(plan: Plan) throws {
        let scriptURL = plan.rootURL.appendingPathComponent("replace-and-relaunch.sh")
        let script = """
        #!/bin/sh
        set -eu
        OLD=\(shellQuote(plan.currentBundleURL.path))
        NEW=\(shellQuote(plan.newBundleURL.path))
        BACKUP=\(shellQuote(plan.currentBundleURL.deletingLastPathComponent().appendingPathComponent(plan.backupName).path))
        ROOT=\(shellQuote(plan.rootURL.path))
        sleep 1
        if [ ! -d \"$NEW\" ]; then exit 1; fi
        mv \"$OLD\" \"$BACKUP\"
        if ! mv \"$NEW\" \"$OLD\"; then
            mv \"$BACKUP\" \"$OLD\" || true
            exit 1
        fi
        /usr/bin/open -n \"$OLD\" || true
        (sleep 10; /bin/rm -rf \"$BACKUP\" \"$ROOT\") >/dev/null 2>&1 &
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
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
