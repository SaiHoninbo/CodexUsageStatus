import OSLog

/// Privacy-safe interaction trace for diagnosing perceived Popover latency.
/// Only static control identifiers are emitted; no account, prompt, token, or
/// credential data enters the log.
enum PopoverInteractionTrace {
    private static let logger = Logger(subsystem: "com.openai.codex-usage-status", category: "popover-interaction")

    static func pressed(_ control: String) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t0_mouse_down")
    }

    static func accepted(_ control: String) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t1_action_accepted")
    }

    static func started(_ control: String) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t2_handler_started")
    }

    /// The feedback overlay is rendered on the next main-loop turn so this
    /// marker measures the first visible response rather than merely the
    /// Button action callback. It carries only static control IDs.
    static func firstVisible(_ control: String) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t3_first_visible_response")
    }

    /// Content-specific marker used when the acknowledgement is not the
    /// meaningful response—for example a tab body, disclosure section, or
    /// account-management destination becoming visible.
    static func firstContentVisible(_ control: String) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t3_first_content_visible")
    }

    static func effectDispatched(_ control: String) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t4_effect_dispatched")
    }

    static func effectCompleted(_ control: String, success: Bool) {
        logger.info("popover_interaction control=\(control, privacy: .public) phase=t5_effect_completed success=\(success, privacy: .public)")
    }
}
