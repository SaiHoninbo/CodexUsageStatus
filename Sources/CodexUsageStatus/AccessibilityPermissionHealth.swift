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
