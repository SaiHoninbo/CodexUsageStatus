import Foundation

/// Pure guards for the temporary prompt clipboard flow.  AppKit performs the
/// actual paste, while these predicates keep change-count and content checks
/// deterministic in the core test harness.
enum ClipboardTemporaryOperationPolicy {
    static func canStart(isOperationInFlight: Bool) -> Bool {
        !isOperationInFlight
    }

    static func preparedTextWriteIsValid(
        expectedText: String,
        observedText: String?,
        beforeChangeCount: Int,
        afterChangeCount: Int
    ) -> Bool {
        observedText == expectedText && afterChangeCount >= beforeChangeCount
    }

    static func canRestore(
        expectedText: String,
        observedText: String?,
        preparedChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        observedText == expectedText && currentChangeCount == preparedChangeCount
    }
}
