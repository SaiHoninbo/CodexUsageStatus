import Foundation

/// Text-only actions that seed the Codex composer.
///
/// These are transport-only workflow prompts. The Usage App never performs
/// Git mutations itself; even 提交並推送 is only placed into the Codex
/// composer for Codex to review. Workflow shortcuts intentionally paste
/// without submitting so the user can review or edit the Chinese instruction
/// before sending it.
enum CodexPromptShortcut: String, CaseIterable, Equatable {
    case continueTask = "繼續"
    case fixUntilDone = "修到完成"
    case fullVerification = "完整驗證"
    case commitAndPush = "提交並推送"

    var text: String {
        switch self {
        case .continueTask:
            return "go on"
        case .fixUntilDone:
            return "請依目前最新的 Repo 狀態繼續處理目前工作。自動修復可修復問題、重新執行受影響的驗證，持續完成工作；只有遇到真正的重大阻塞才停止。不要因例行批准或已決定事項停止。"
        case .fullVerification:
            return "請依目前最新的 Repo 狀態驗證實作。執行相關測試、建置、diff 檢查與必要的 runtime 驗證；自動修復可修復失敗並重新執行受影響的檢查。最後用精簡內容回報驗證結果與仍存在的限制。"
        case .commitAndPush:
            return "請檢查目前 Repo、分支、working tree、diff、驗證狀態與敏感內容風險。若目前變更安全且驗證充分，建立適當的 commit 並推送到既有 upstream。若遇到 Repo 身分不符、分支或遠端目標異常、秘密外洩、破壞性 Git 操作或範圍不符等重大風險，請停止並回報。"
        }
    }

    var helpText: String {
        switch self {
        case .continueTask:
            return "go on"
        case .fixUntilDone:
            return "僅貼上中文指令；不會自動送出。自動修復可修復問題並持續執行，直到完成或遇到真正的重大阻塞。"
        case .fullVerification:
            return "僅貼上中文指令；不會自動送出。執行測試、建置、diff 與必要的 runtime verification，並自動修復可修復失敗。"
        case .commitAndPush:
            return "僅貼上中文指令；不會自動送出。將提交與推送決策交給 Codex；Usage App 不會執行 Git。"
        }
    }

    var submitAfterPaste: Bool {
        switch self {
        case .continueTask:
            // The compact Continue action retains its historical one-tap
            // transport semantics.
            return true
        case .fixUntilDone, .fullVerification, .commitAndPush:
            return false
        }
    }
    /// Keep the semantic control name short; the exact payload is exposed as
    /// help text and remains the value sent to Codex.
    var accessibilityLabel: String { rawValue }
}
