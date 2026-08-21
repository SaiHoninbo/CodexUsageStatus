import AppKit
import CryptoKit
import Foundation

struct AppUpdateRelease: Equatable, Identifiable {
    let version: String
    let tagName: String
    let name: String
    let releaseURL: URL
    let downloadURL: URL?
    let expectedSHA256: String?
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
    case downloaded(AppUpdateRelease, URL)
    case error(String)

    var release: AppUpdateRelease? {
        switch self {
        case .available(let release), .downloading(let release), .downloaded(let release, _):
            return release
        default:
            return nil
        }
    }
}

enum AppUpdateError: LocalizedError {
    case noRelease
    case invalidResponse
    case checkTimedOut
    case checkCancelled
    case httpStatus(Int)
    case missingDownload
    case downloadFailed
    case invalidArchive
    case checksumMismatch
    case signatureInvalid
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .noRelease: return "GitHub 尚未發布正式 Release。"
        case .invalidResponse: return "GitHub 更新資訊格式無法辨識。"
        case .checkTimedOut: return "更新檢查逾時，請確認網路後重試。"
        case .checkCancelled: return "更新檢查已取消。"
        case .httpStatus(let status): return "GitHub 更新服務回應錯誤（HTTP \(status)）。"
        case .missingDownload: return "此 Release 沒有 CodexUsageStatus.app.zip。"
        case .downloadFailed: return "更新檔下載失敗。"
        case .invalidArchive: return "下載的更新檔不是有效的 App bundle。"
        case .checksumMismatch: return "更新檔 SHA-256 驗證失敗，已停止套用。"
        case .signatureInvalid: return "更新 App 的 strict code signature 驗證失敗。"
        case .fileSystem(let message): return message
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

@MainActor
final class AppUpdateService: NSObject {
    private struct ReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let body: String?
        let publishedAt: Date?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    private let endpoint = URL(string: "https://api.github.com/repos/SaiHoninbo/CodexUsageStatus/releases/latest")!
    private let repositoryURL = URL(string: "https://github.com/SaiHoninbo/CodexUsageStatus/releases")!
    private let session: URLSession
    private let fileManager = FileManager.default
    private let updatesDirectory: URL
    private let checkTimeout: TimeInterval
    private(set) var state: AppUpdateState = .idle
    private var checkTask: URLSessionDataTask?
    private var checkTimeoutTimer: Timer?
    private var checkGeneration: UInt64 = 0
    private var checkCompletion: ((AppUpdateState) -> Void)?
    private var downloadTask: URLSessionDownloadTask?

    init(session: URLSession = .shared, checkTimeout: TimeInterval = 20) {
        self.session = session
        self.checkTimeout = max(0.1, checkTimeout)
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        updatesDirectory = applicationSupport
            .appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        super.init()
    }

    var currentVersion: String {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return bundleVersion?.isEmpty == false ? bundleVersion! : "2.4.25"
    }

    func check(completion: ((AppUpdateState) -> Void)? = nil) {
        // A manual retry can arrive while the automatic startup check is
        // still in flight.  The old implementation silently returned here,
        // leaving the HUD attached to a request that the user could not
        // restart.  Invalidate the old generation and start one authoritative
        // request instead; the old URLSession callback is discarded below.
        invalidateCheck(notify: false)
        checkGeneration &+= 1
        let generation = checkGeneration
        checkCompletion = completion
        state = .checking
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
                    let zip = payload.assets.first { $0.name == "CodexUsageStatus.app.zip" }
                    let release = AppUpdateRelease(
                        version: payload.tagName.replacingOccurrences(of: "^v", with: "", options: .regularExpression),
                        tagName: payload.tagName,
                        name: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
                        releaseURL: payload.htmlURL,
                        downloadURL: zip?.browserDownloadURL,
                        expectedSHA256: Self.sha256(from: zip?.digest),
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

        // URLSession's timeout is not sufficient on its own: a stalled
        // callback can leave the UI in `.checking`.  A RunLoop timer gives us
        // an explicit terminal path even when URLSession never calls back.
        let timer = Timer(timeInterval: checkTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timeoutCheck(generation: generation)
            }
        }
        checkTimeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelCheck(completion: ((AppUpdateState) -> Void)? = nil) {
        guard state == .checking else {
            completion?(state)
            return
        }

        // Invalidate the generation before cancelling URLSession.  The
        // cancelled task may still deliver its completion callback on a
        // later turn of the main actor; that callback must not restore the
        // old `.checking` state or overwrite a subsequent check.
        checkGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil

        // Complete through the same path as a normal response so every
        // caller (including the HUD and popover) receives the terminal
        // state immediately and can leave the spinner without waiting for
        // URLSession to acknowledge cancellation.
        finishCheck(.error(AppUpdateError.checkCancelled.localizedDescription), completion: completion)
    }

    func download(completion: ((AppUpdateState) -> Void)? = nil) {
        guard case .available(let release) = state, let downloadURL = release.downloadURL else {
            finish(.error(AppUpdateError.missingDownload.localizedDescription), completion: completion)
            return
        }
        guard downloadTask == nil else { return }
        do {
            try fileManager.createDirectory(at: updatesDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            finish(.error("無法建立更新暫存目錄：\(error.localizedDescription)"), completion: completion)
            return
        }

        state = .downloading(release)
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 120
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageStatus/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadTask = nil
                if let error {
                    self.finish(.error("更新檔下載失敗：\(error.localizedDescription)"), completion: completion)
                    return
                }
                guard let temporaryURL,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    self.finish(.error(AppUpdateError.downloadFailed.localizedDescription), completion: completion)
                    return
                }
                do {
                    let archive = self.updatesDirectory.appendingPathComponent("CodexUsageStatus-\(release.version).app.zip")
                    try? self.fileManager.removeItem(at: archive)
                    try self.fileManager.moveItem(at: temporaryURL, to: archive)
                    if let expected = release.expectedSHA256 {
                        guard Self.sha256(of: archive) == expected.lowercased() else {
                            throw AppUpdateError.checksumMismatch
                        }
                    }
                    let app = try self.extractAndVerify(archive: archive, version: release.version)
                    self.finish(.downloaded(release, app), completion: completion)
                } catch {
                    self.finish(.error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription), completion: completion)
                }
            }
        }
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading(let release) = state { state = .available(release) }
    }

    func revealDownloadedApp() {
        guard case .downloaded(_, let appURL) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    func openReleasePage() {
        NSWorkspace.shared.open(state.release?.releaseURL ?? repositoryURL)
    }

    private func extractAndVerify(archive: URL, version: String) throws -> URL {
        let directory = updatesDirectory.appendingPathComponent("CodexUsageStatus-\(version)", isDirectory: true)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateError.invalidArchive }

        let appURL = directory.appendingPathComponent("CodexUsageStatus.app", isDirectory: true)
        guard fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw AppUpdateError.invalidArchive
        }
        let signature = Process()
        signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signature.arguments = ["--verify", "--deep", "--strict", appURL.path]
        signature.standardOutput = Pipe()
        signature.standardError = Pipe()
        try signature.run()
        signature.waitUntilExit()
        guard signature.terminationStatus == 0 else { throw AppUpdateError.signatureInvalid }
        try (directory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        return appURL
    }

    private func finish(_ newState: AppUpdateState, completion: ((AppUpdateState) -> Void)?) {
        state = newState
        completion?(newState)
    }

    private func finishCheck(_ newState: AppUpdateState, completion: ((AppUpdateState) -> Void)? = nil) {
        checkTimeoutTimer?.invalidate()
        checkTimeoutTimer = nil
        checkTask = nil
        state = newState
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

    private static func sha256(from digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased().replacingOccurrences(of: "^sha256:", with: "", options: .regularExpression)
        return value.count == 64 ? value : nil
    }

    private static func sha256(of url: URL) -> String {
        guard let stream = InputStream(url: url) else { return "" }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            hasher.update(data: Data(buffer[0..<read]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
