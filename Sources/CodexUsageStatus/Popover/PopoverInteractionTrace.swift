import OSLog

/// Privacy-safe interaction trace for diagnosing perceived Popover latency.
/// Only static control identifiers are emitted; no account, prompt, token, or
/// credential data enters the log.
enum PopoverInteractionTrace {
    private static let logger = Logger(subsystem: "com.openai.codex-usage-status", category: "popover-interaction")

    static func accepted(_ control: String) {
        logger.debug("popover action accepted: \(control, privacy: .public)")
    }

    static func started(_ control: String) {
        logger.debug("popover action started: \(control, privacy: .public)")
    }
}
