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
    case error(String)

    var release: AppUpdateRelease? {
        switch self {
        case .available(let release):
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

    var errorDescription: String? {
        switch self {
        case .noRelease: return "GitHub 尚未發布正式 Release。"
        case .invalidResponse: return "GitHub 更新資訊格式無法辨識。"
        case .checkTimedOut: return "更新檢查逾時，請確認網路後重試。"
        case .checkCancelled: return "更新檢查已取消。"
        case .httpStatus(let status): return "GitHub 更新服務回應錯誤（HTTP \(status)）。"
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
        // Reject dot-segments before comparing the repository prefix. URL
        // consumers may canonicalize `releases/../evil` outside the trusted
        // release area even though its raw path starts with that prefix.
        guard !components.contains(where: { $0 == "." || $0 == ".." }),
              components.count >= 3,
              components[0].lowercased() == "saihoninbo",
              components[1].lowercased() == "codexusagestatus",
              components[2].lowercased() == "releases" else { return false }
        return true
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

    private let endpoint = URL(string: "https://api.github.com/repos/SaiHoninbo/CodexUsageStatus/releases/latest")!
    private let repositoryURL = URL(string: "https://github.com/SaiHoninbo/CodexUsageStatus/releases")!
    private let session: URLSession
    private let checkTimeout: TimeInterval
    private(set) var state: AppUpdateState = .idle
    private var checkTask: URLSessionDataTask?
    private var checkTimeoutTimer: Timer?
    private var checkGeneration: UInt64 = 0
    private var checkCompletion: ((AppUpdateState) -> Void)?

    init(session: URLSession = .shared, checkTimeout: TimeInterval = 20) {
        self.session = session
        self.checkTimeout = max(0.1, checkTimeout)
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

    func openReleasePage() {
        NSWorkspace.shared.open(state.release?.releaseURL ?? repositoryURL)
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

}
