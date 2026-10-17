import AppKit
import Foundation

/// User-triggered Codex composer actions that can reuse the donor's guarded
/// clipboard and accessibility transport from another Core consumer.
public enum CodexUsageHUDAction: String, CaseIterable, Equatable, Sendable {
    case paste
    case pasteAndSubmit
    case continueExecution
    case fixUntilDone
    case fullVerification

    public var title: String {
        switch self {
        case .paste: "貼上"
        case .pasteAndSubmit: "貼上並送出"
        case .continueExecution: "繼續執行"
        case .fixUntilDone: "修到完成"
        case .fullVerification: "完整驗證"
        }
    }

    public var systemImage: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .pasteAndSubmit: "paperplane.fill"
        case .continueExecution: "arrow.clockwise"
        case .fixUntilDone: "hammer.fill"
        case .fullVerification: "checkmark.seal.fill"
        }
    }
}

@MainActor
public enum CodexUsageHUDActionRouter {
    /// Reuses the existing donor transport. The underlying paste service
    /// rechecks the exact PID, frontmost state, Accessibility authorization,
    /// pasteboard ownership, and submit policy before posting input.
    public static func perform(
        _ action: CodexUsageHUDAction,
        processID: pid_t?,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        switch action {
        case .paste:
            ClipboardPasteService.pasteToCodex(processID: processID, completion: completion)
        case .pasteAndSubmit:
            ClipboardPasteService.pasteAndSubmitToCodex(processID: processID, completion: completion)
        case .continueExecution:
            ClipboardPasteService.pasteTemporaryTextToCodex(.continueTask, processID: processID, completion: completion)
        case .fixUntilDone:
            ClipboardPasteService.pasteTemporaryTextToCodex(.fixUntilDone, processID: processID, completion: completion)
        case .fullVerification:
            ClipboardPasteService.pasteTemporaryTextToCodex(.fullVerification, processID: processID, completion: completion)
        }
    }
}
