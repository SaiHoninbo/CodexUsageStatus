import Foundation

/// Text-only actions that seed the Codex composer.
///
/// These are transport-only workflow prompts. The Usage App never performs
/// Git mutations itself; even Commit + Push is sent to Codex for Codex to
/// review and decide.
enum CodexPromptShortcut: String, CaseIterable, Equatable {
    case continueTask = "繼續"
    case fixUntilDone = "修到完成"
    case fullVerification = "完整驗證"
    case commitAndPush = "Commit + Push"

    var text: String {
        switch self {
        case .continueTask:
            return "go on"
        case .fixUntilDone:
            return "Continue the current task using the latest repo reality. Fix repairable issues automatically, rerun affected verification, and keep going until the task is complete or a true material blocker is found. Do not stop for routine approvals or previously decided matters."
        case .fullVerification:
            return "Verify the current implementation against the latest repo reality. Run the relevant tests, build, diff checks, and necessary runtime verification. Auto-repair repairable failures and rerun affected checks. Finish with a concise verification result and remaining declared limits."
        case .commitAndPush:
            return "Review the current repository, branch, working tree, diff, verification status, and sensitive-content risk. If the current change is safe and sufficiently verified, create an appropriate commit and push it to the existing upstream. Stop only for a true material risk such as repository identity mismatch, unexpected branch or remote target, secret exposure, destructive Git, or material scope mismatch."
        }
    }

    var helpText: String {
        switch self {
        case .continueTask:
            return "go on"
        case .fixUntilDone:
            return "自動修復可修復問題並持續執行，直到完成或遇到真正的重大阻塞。"
        case .fullVerification:
            return "執行測試、建置、diff 與必要的 runtime verification，並自動修復可修復失敗。"
        case .commitAndPush:
            return "將提交與推送決策交給 Codex；Usage App 不會執行 Git。"
        }
    }

    var submitAfterPaste: Bool { true }
    /// Keep the semantic control name short; the exact payload is exposed as
    /// help text and remains the value sent to Codex.
    var accessibilityLabel: String { rawValue }
}
