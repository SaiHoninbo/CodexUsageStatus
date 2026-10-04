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

enum CodexPromptInputAction: Equatable {
    case workflowShortcut(CodexPromptShortcut)
    case userClipboardPaste
    case userClipboardPasteAndSubmit
}

enum WorkflowPromptAXInsertionFailureReason: String, Equatable {
    case targetUnavailable = "target_unavailable"
    case wrongApplication = "wrong_application"
    case targetNotFrontmost = "target_not_frontmost"
    case accessibilityUntrusted = "ax_untrusted"
    case focusedElementUnavailable = "focused_element_unavailable"
    case targetPIDMismatch = "target_pid_mismatch"
    case focusedElementChanged = "focused_element_changed"
    case selectedTextNotSettable = "selected_text_not_settable"
    case insertionFailed = "ax_set_failed"
}

struct WorkflowPromptAXInsertionEligibility: Equatable {
    let targetIsAvailable: Bool
    let targetPIDMatchesRequest: Bool
    let targetIsCodex: Bool
    let targetIsFrontmost: Bool
    let accessibilityTrusted: Bool
    let focusedElementResolved: Bool
    let focusedElementPIDMatchesTarget: Bool
    let selectedTextAttributeSettable: Bool
}

enum WorkflowPromptAXInsertionDecision: Equatable {
    case attemptAXInsertion
    case clipboardFallback(WorkflowPromptAXInsertionFailureReason)
}

/// Pure policy for the experimental app-generated workflow prompt AX path.
/// AX insertion remains disabled until there is a semantic confirmation
/// contract; an AX set-attribute acknowledgement alone is not sufficient.
/// Normal user-clipboard actions never opt into AX insertion.
enum WorkflowPromptAXInsertionPolicy {
    static func usesAXFastPath(for _: CodexPromptInputAction) -> Bool {
        false
    }

    static func decision(
        for eligibility: WorkflowPromptAXInsertionEligibility
    ) -> WorkflowPromptAXInsertionDecision {
        guard eligibility.targetIsAvailable else {
            return .clipboardFallback(.targetUnavailable)
        }
        guard eligibility.targetPIDMatchesRequest else {
            return .clipboardFallback(.targetUnavailable)
        }
        guard eligibility.targetIsCodex else {
            return .clipboardFallback(.wrongApplication)
        }
        guard eligibility.targetIsFrontmost else {
            return .clipboardFallback(.targetNotFrontmost)
        }
        guard eligibility.accessibilityTrusted else {
            return .clipboardFallback(.accessibilityUntrusted)
        }
        guard eligibility.focusedElementResolved else {
            return .clipboardFallback(.focusedElementUnavailable)
        }
        guard eligibility.focusedElementPIDMatchesTarget else {
            return .clipboardFallback(.targetPIDMismatch)
        }
        guard eligibility.selectedTextAttributeSettable else {
            return .clipboardFallback(.selectedTextNotSettable)
        }
        return .attemptAXInsertion
    }

    static func shouldUseClipboardFallback(
        afterAXInsertionSucceeded: Bool,
        semanticInsertionConfirmed: Bool
    ) -> Bool {
        !afterAXInsertionSucceeded || !semanticInsertionConfirmed
    }

    static func shouldSubmit(
        shortcut: CodexPromptShortcut,
        axInsertionSucceeded: Bool
    ) -> Bool {
        axInsertionSucceeded && shortcut.submitPolicy == .singleReturn
    }

    static func mayPostReturn(
        shortcut: CodexPromptShortcut,
        axInsertionSucceeded: Bool,
        focusedElementMatchesInsertion: Bool
    ) -> Bool {
        shouldSubmit(shortcut: shortcut, axInsertionSucceeded: axInsertionSucceeded)
            && focusedElementMatchesInsertion
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

enum ContinuePromptTransportPolicy {
    static func usesDirectUnicodeText(for shortcut: CodexPromptShortcut) -> Bool {
        shortcut == .continueTask
    }

    static func unicodeUnits(for text: String) -> [UniChar]? {
        guard !text.isEmpty else { return nil }
        return Array(text.utf16)
    }
}
