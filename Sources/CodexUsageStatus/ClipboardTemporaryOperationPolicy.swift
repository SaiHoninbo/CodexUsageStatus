import Foundation

enum ClipboardPasteDispatchDecision: Equatable {
    case immediateFrontmost
    case delayedActivationFallback
}

enum ClipboardPasteDispatchPolicy {
    static func decision(targetIsVerifiedFrontmost: Bool) -> ClipboardPasteDispatchDecision {
        targetIsVerifiedFrontmost ? .immediateFrontmost : .delayedActivationFallback
    }
}

enum ClipboardPasteSettlePolicy {
    static let shortTextSettle: TimeInterval = 0.03
    static let safeRichContentSettle: TimeInterval = 0.18
    private static let plainTextRepresentationTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.plain-text",
        "NSStringPboardType"
    ]

    static func normalSubmitSettle(itemTypeIdentifiers: [[String]]) -> TimeInterval {
        isPlainTextOnly(itemTypeIdentifiers: itemTypeIdentifiers)
            ? shortTextSettle
            : safeRichContentSettle
    }

    static func temporarySubmitSettle(for shortcut: CodexPromptShortcut) -> TimeInterval {
        shortcut == .continueTask ? shortTextSettle : safeRichContentSettle
    }

    static func isPlainTextOnly(itemTypeIdentifiers: [[String]]) -> Bool {
        guard itemTypeIdentifiers.count == 1,
              let itemTypes = itemTypeIdentifiers.first,
              !itemTypes.isEmpty else {
            return false
        }
        return itemTypes.contains(where: plainTextRepresentationTypes.contains)
            && itemTypes.allSatisfy(plainTextRepresentationTypes.contains)
    }
}

struct ClipboardActivationProcessIdentity: Equatable {
    let processID: Int32
    let launchDate: Date?
    let bundleURL: URL?

    func exactlyMatches(_ other: Self) -> Bool {
        guard let launchDate, let bundleURL,
              let otherLaunchDate = other.launchDate,
              let otherBundleURL = other.bundleURL else {
            return false
        }
        return processID == other.processID
            && launchDate == otherLaunchDate
            && bundleURL == otherBundleURL
    }
}

enum ClipboardActivationEventDisposition: Equatable {
    case accepted
    case ignoredIdentityMismatch
    case ignoredNotFrontmost
    case alreadyResolved
}

/// Per-attempt state for event-driven activation. A notification is only a
/// wake-up hint: exact process identity and current frontmost state are both
/// required before the operation may continue.
struct ClipboardActivationWaitState {
    let targetIdentity: ClipboardActivationProcessIdentity
    private(set) var isResolved = false

    mutating func receiveActivationEvent(
        identity: ClipboardActivationProcessIdentity?,
        targetIsFrontmost: Bool
    ) -> ClipboardActivationEventDisposition {
        guard !isResolved else { return .alreadyResolved }
        guard let identity, targetIdentity.exactlyMatches(identity) else {
            return .ignoredIdentityMismatch
        }
        guard targetIsFrontmost else { return .ignoredNotFrontmost }
        isResolved = true
        return .accepted
    }

    mutating func timeOut(targetIsFrontmost: Bool) -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        return targetIsFrontmost
    }
}

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
