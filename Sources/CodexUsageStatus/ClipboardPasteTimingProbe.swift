import Foundation
import OSLog

/// Read-only timing observation for the clipboard action path.
///
/// This probe deliberately records only operation phases and elapsed time. It
/// never records clipboard contents, target window text, or user data, and it
/// does not change dispatch, focus, or pasteboard behavior.
struct ClipboardPasteTimingProbe {
    private static let logger = Logger(
        subsystem: "com.openai.codex-usage-status",
        category: "clipboard-performance"
    )

    let operationID: UUID
    let operation: String
    private let startedAtUptimeNanoseconds: UInt64

    init(operation: String) {
        self.operationID = UUID()
        self.operation = operation
        self.startedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        mark("t0_service_entry")
    }

    func mark(_ point: String, detail: String = "") {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = now >= startedAtUptimeNanoseconds
            ? now - startedAtUptimeNanoseconds
            : 0
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000.0
        Self.logger.debug(
            "clipboard_timing operation=\(operation, privacy: .public) id=\(operationID.uuidString, privacy: .public) point=\(point, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public) detail=\(detail, privacy: .public)"
        )
    }
}
