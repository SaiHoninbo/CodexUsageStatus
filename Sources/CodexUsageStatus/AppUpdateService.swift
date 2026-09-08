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
    case downloading(progress: Double?)
    case verifying(AppUpdateRelease?)
    case installing(AppUpdateRelease?)
    case relaunching(AppUpdateRelease?)
    case error(String)

    var release: AppUpdateRelease? {
        switch self {
        case .available(let release): return release
        case .verifying(let release), .installing(let release), .relaunching(let release): return release
        default: return nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing, .relaunching: return true
        default: return false
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

enum AppUpdateCheckIntent: Equatable {
    case informationProbe
    case foregroundUpdateFlow
}

enum AppUpdateRequest: Equatable {
    case startup
    case periodic
    case manualCheck
    case installation
}

enum AppUpdateIntentPolicy {
    static func intent(for request: AppUpdateRequest) -> AppUpdateCheckIntent {
        switch request {
        case .startup, .periodic, .manualCheck:
            return .informationProbe
        case .installation:
            return .foregroundUpdateFlow
        }
    }
}

enum SparkleReleaseConfigurationPolicy {
    static let publicKeyInfoPlistKey = "SUPublicEDKey"

    /// Checks the transport shape only. Sparkle performs the cryptographic
    /// verification against the signed appcast at runtime.
    static func isValidPublicEDKey(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil
    }

    static func permitsPackaging(releaseMode: Bool, publicEDKey: String?) -> Bool {
        !releaseMode || isValidPublicEDKey(publicEDKey)
    }
}

enum AppUpdatePresentationPolicy {
    static let installationButtonTitle = "開始更新"

    static func canCancel(_ state: AppUpdateState) -> Bool {
        // The product uses Sparkle's informational probe for checks. That
        // API does not expose an app-owned cancellation handle; cancellation
        // during Sparkle's foreground download/install flow belongs to its
        // standard user driver. Do not render a misleading button here.
        return false
    }
}

#if canImport(Sparkle)
@MainActor
final class AppUpdateService: NSObject {
    private(set) var state: AppUpdateState = .idle
    var onStateChange: ((AppUpdateState) -> Void)?
    private var completion: ((AppUpdateState) -> Void)?
    private let sparkleEngine: SparkleUpdateEngine

    var currentVersion: String { AppVersion.current }

    override init() {
        sparkleEngine = SparkleUpdateEngine()
        super.init()
        sparkleEngine.onStateChange = { [weak self] state in self?.finish(state) }
    }

    func start() {
        sparkleEngine.start()
    }

    func check(completion: ((AppUpdateState) -> Void)? = nil) {
        self.completion = completion
        state = .checking
        onStateChange?(.checking)
        sparkleEngine.probeForUpdateInformation()
    }

    func beginInstall() {
        // Sparkle's standard user driver presents the authenticated update
        // flow after this user-initiated check finds a valid appcast item.
        finish(.checking)
        sparkleEngine.beginForegroundUpdateFlow()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(
            state.release?.releaseURL
                ?? AppUpdateReleasePolicy.officialReleasesURL
        )
    }

    private func finish(_ newState: AppUpdateState, completion: ((AppUpdateState) -> Void)? = nil) {
        state = newState
        onStateChange?(newState)
        let callback = completion ?? self.completion
        self.completion = nil
        callback?(newState)
    }
}
#endif
