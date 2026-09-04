import Foundation

/// Stable identifiers for the HUD's native context menu.
///
/// Keeping the action vocabulary independent of SwiftUI makes the menu easy
/// to verify without launching an AppKit panel and prevents right-click from
/// accidentally acquiring side effects of its own.
enum HUDContextMenuAction: String, CaseIterable {
    case refresh
    case showDetails
    case openCodex
    case resetPosition
    case hudScale
    case paste
    case pasteAndSubmit
    case currentAccount
    case allAccounts
    case manageAccounts
    case notifications
    case quotaRefreshInterval
    case accountRefreshInterval
    case tokenActivityRefreshInterval
    case credentialWatchInterval
    case checkForUpdates
    case openReleasePage
    case quit
}

enum HUDContextMenuSection: String, CaseIterable {
    case status
    case codex
    case appearance
    case clipboard
    case accounts
    case notificationsAndSync
    case app
}

enum HUDContextMenuPolicy {
    static let sections: [[HUDContextMenuAction]] = [
        [.refresh, .showDetails],
        [.openCodex, .resetPosition, .hudScale],
        [.paste, .pasteAndSubmit],
        [.currentAccount, .allAccounts, .manageAccounts],
        [
            .notifications,
            .quotaRefreshInterval,
            .accountRefreshInterval,
            .tokenActivityRefreshInterval,
            .credentialWatchInterval,
            .checkForUpdates,
            .openReleasePage
        ],
        [.quit]
    ]

    static func pasteActionsEnabled(isCodexFocused: Bool) -> Bool {
        isCodexFocused
    }
}
