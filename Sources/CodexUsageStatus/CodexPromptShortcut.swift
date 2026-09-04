import Foundation

/// Text-only actions that seed the Codex composer.
///
/// Git prompt shortcuts were retired with the direct Git client.  The HUD now
/// exposes only the safe, general-purpose execute prompt; it never performs
/// Git mutations itself.
enum CodexPromptShortcut: String, CaseIterable, Equatable {
    case execute = "執行"

    var text: String { rawValue }
    var submitAfterPaste: Bool { self == .execute }
    var accessibilityLabel: String { text }
}
