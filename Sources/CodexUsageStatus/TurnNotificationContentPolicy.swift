import Foundation

enum TurnNotificationCadencePolicy {
    /// The display timer may re-evaluate only active Turns (for the existing
    /// long-running notification policy). Terminal notifications are emitted
    /// by the terminal event itself and must never be replayed by the timer.
    static func shouldEvaluateDisplayTimer(state: TurnActivityState) -> Bool {
        state == .active
    }
}

/// Pure, metadata-only presentation policy for completed Turn notifications.
///
/// This type deliberately has no UserNotifications dependency and never reads
/// rollout or conversation content.  Keeping title/body construction here
/// makes the privacy boundary and value semantics directly testable by the
/// core-test harness.
struct TurnNotificationContentPolicy {
    static let maximumProgramNameLength = 96

    static func title(state: TurnActivityState, programName: String?) -> String {
        guard let programName = normalizedProgramName(programName) else {
            return "Codex Turn \(state.displayName)"
        }
        switch state {
        case .completed: return "程序完成：\(programName)"
        case .failed: return "程序失敗：\(programName)"
        case .interrupted: return "程序中斷：\(programName)"
        default: return "Codex Turn \(state.displayName)"
        }
    }

    static func body(
        elapsedSeconds: Int64?,
        tokenTotal: Int64?,
        content: String? = nil,
        errorMessage: String? = nil,
        contentEnabled: Bool
    ) -> String {
        var parts: [String] = []
        if let elapsedSeconds {
            parts.append("耗時 \(elapsedSeconds) 秒")
        }
        if let tokenTotal {
            parts.append("消耗 \(formatTokenTotal(tokenTotal)) tokens")
        }
        if contentEnabled, let content, !content.isEmpty {
            parts.append(content)
        }
        if let errorMessage, !errorMessage.isEmpty {
            // Raw App Server errors can contain private context.  The default
            // notification stays metadata-only unless the user explicitly
            // opts into notification content.
            parts.append(contentEnabled ? errorMessage : "伺服器回報錯誤")
        }
        return parts.joined(separator: " · ")
    }

    static func normalizedProgramName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maximumProgramNameLength else { return normalized }
        return String(normalized.prefix(maximumProgramNameLength)) + "…"
    }

    /// Formats token totals with stable comma grouping independent of the
    /// user's locale so notification content remains deterministic.
    static func formatTokenTotal(_ value: Int64) -> String {
        let raw = String(value)
        let isNegative = raw.first == "-"
        let digits = isNegative ? String(raw.dropFirst()) : raw
        var grouped = ""
        grouped.reserveCapacity(digits.count + digits.count / 3)
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(character)
        }
        return isNegative ? "-\(grouped)" : grouped
    }
}
