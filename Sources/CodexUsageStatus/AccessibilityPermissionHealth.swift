import AppKit
import Foundation

enum AccessibilityPermissionState: Equatable {
    case trusted
    case notTrusted
    case unavailable

    var displayName: String {
        switch self {
        case .trusted: return "已允許"
        case .notTrusted: return "尚未允許"
        case .unavailable: return "無法確認"
        }
    }
}

enum AccessibilityPermissionPolicy {
    static func state(axTrusted: Bool, eventPostingAuthorized: Bool) -> AccessibilityPermissionState {
        if axTrusted || eventPostingAuthorized { return .trusted }
        return .notTrusted
    }

    static func current() -> AccessibilityPermissionState {
        state(
            axTrusted: AXIsProcessTrusted(),
            eventPostingAuthorized: CGPreflightPostEventAccess()
        )
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// macOS owns the TCC grant; the app cannot copy or forge that database entry
/// during an update. The continuity contract is therefore to keep the same
/// bundle identity and install path, preserve user settings in the stable
/// defaults domain, and re-read live trust after every launch/foreground
/// transition instead of persisting a stale "granted" bit.
enum AccessibilityPermissionContinuityPolicy {
    static let bundleIdentifier = AppSettingsSchema.stableBundleIdentifier
    static let canonicalInstallPath = "/Applications/CodexUsageStatus.app"

    static func preservesTCCIdentity(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        guard bundleIdentifier == Self.bundleIdentifier,
              let bundleURL else { return false }
        return bundleURL.standardizedFileURL.path == canonicalInstallPath
    }

    static var requiresLiveRefreshAfterLaunch: Bool { true }
}
