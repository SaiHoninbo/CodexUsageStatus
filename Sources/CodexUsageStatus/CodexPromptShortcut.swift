import Foundation

/// Text-only actions that seed the Codex composer.  They intentionally have
/// no Git operation callback; Git mutations remain behind the Git workspace.
enum CodexPromptShortcut: String, CaseIterable, Equatable {
    case commit = "Commit"
    case push = "Push"
    case commitPush = "Commit Push"

    var text: String { rawValue }
    var submitAfterPaste: Bool { self == .commitPush }
    var accessibilityLabel: String { text }
}
