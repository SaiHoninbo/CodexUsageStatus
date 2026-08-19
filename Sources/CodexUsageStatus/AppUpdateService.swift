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
    private(set) var state: AppUpdateState = .idle
    private var downloadTask: URLSessionDownloadTask?

    init(session: URLSession = .shared) {
        self.session = session
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        updatesDirectory = applicationSupport
            .appendingPathComponent("com.openai.codex-usage-status", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        super.init()
    }

    var currentVersion: String {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return bundleVersion?.isEmpty == false ? bundleVersion! : "2.4.11"
    }

    func check(completion: ((AppUpdateState) -> Void)? = nil) {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageStatus/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.finish(.error("更新檢查失敗：\(error.localizedDescription)"), completion: completion)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    self.finish(.error(AppUpdateError.noRelease.localizedDescription), completion: completion)
                    return
                }
                guard let data else {
                    self.finish(.error(AppUpdateError.invalidResponse.localizedDescription), completion: completion)
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
                        self.finish(.upToDate, completion: completion)
                        return
                    }
                    self.finish(.available(release), completion: completion)
                } catch {
                    self.finish(.error("更新資訊無法解析：\(error.localizedDescription)"), completion: completion)
                }
            }
        }.resume()
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
