import Foundation

/// Text-only actions that seed the Codex composer.  They intentionally have
/// no Git operation callback; Git mutations remain behind the Git workspace.
enum CodexPromptShortcut: String, CaseIterable, Equatable {
    case commit = "Commit"
    case push = "Push"
    case commitPush = "Commit Push"
    case execute = "執行"

    var text: String { rawValue }
    var submitAfterPaste: Bool { self == .commitPush || self == .execute }
    var accessibilityLabel: String { text }
}
