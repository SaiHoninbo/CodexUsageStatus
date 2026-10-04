import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum ClipboardPasteService {
    private static var lastPermissionPromptAt: Date?
    private static var activeTemporaryOperationToken: UUID?
    private static var completedTemporaryOperationTokens = Set<UUID>()

    @MainActor
    private final class TargetActivationWaiter {
        private let target: NSRunningApplication
        private let timeout: TimeInterval
        private let timing: ClipboardPasteTimingProbe
        private let completion: (Bool) -> Void
        private var state: ClipboardActivationWaitState
        private var observer: NSObjectProtocol?
        private var timeoutWorkItem: DispatchWorkItem?
        private var isFinished = false

        init(
            target: NSRunningApplication,
            timeout: TimeInterval,
            timing: ClipboardPasteTimingProbe,
            completion: @escaping (Bool) -> Void
        ) {
            self.target = target
            self.timeout = timeout
            self.timing = timing
            self.completion = completion
            self.state = ClipboardActivationWaitState(
                targetIdentity: Self.identity(for: target)
            )
        }

        func start() {
            let notificationCenter = NSWorkspace.shared.notificationCenter
            observer = notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [self] notification in
                let application = notification.object as? NSRunningApplication
                Task { @MainActor [self] in
                    self.receiveActivation(of: application)
                }
            }

            target.activate(options: [.activateAllWindows])
            if ClipboardPasteService.isTargetFrontmost(target) {
                finish(success: true)
                return
            }

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleTimeout()
                }
            }
            self.timeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        }

        private func receiveActivation(of application: NSRunningApplication?) {
            guard !isFinished else { return }
            let eventIdentity = application.flatMap { application in
                ClipboardPasteService.isCodexApplication(application)
                    ? Self.identity(for: application)
                    : nil
            }
            let disposition = state.receiveActivationEvent(
                identity: eventIdentity,
                targetIsFrontmost: ClipboardPasteService.isTargetFrontmost(target)
            )
            switch disposition {
            case .accepted:
                timing.mark("activation_event_accepted", detail: "exact_target_frontmost")
                finish(success: true)
            case .ignoredIdentityMismatch:
                timing.mark("activation_event_ignored", detail: "identity_mismatch")
            case .ignoredNotFrontmost:
                timing.mark("activation_event_ignored", detail: "target_not_frontmost")
            case .alreadyResolved:
                break
            }
        }

        private func handleTimeout() {
            guard !isFinished else { return }
            let targetIsFrontmost = ClipboardPasteService.isTargetFrontmost(target)
            let shouldProceed = state.timeOut(targetIsFrontmost: targetIsFrontmost)
            timing.mark(
                shouldProceed ? "activation_timeout_frontmost" : "activation_timeout",
                detail: "timeout_ms=\(Int((timeout * 1_000).rounded()))"
            )
            finish(success: shouldProceed)
        }

        private func finish(success: Bool) {
            guard !isFinished else { return }
            isFinished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            if let observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                self.observer = nil
            }
            let finalFrontmost = success && ClipboardPasteService.isTargetFrontmost(target)
            if success && !finalFrontmost {
                timing.mark("activation_final_frontmost_check_failed")
            }
            completion(finalFrontmost)
        }

        private static func identity(for application: NSRunningApplication) -> ClipboardActivationProcessIdentity {
            ClipboardActivationProcessIdentity(
                processID: application.processIdentifier,
                launchDate: application.launchDate,
                bundleURL: application.bundleURL
            )
        }
    }

    /// Exposed for the HUD and core tests.  The lock is process-wide because
    /// NSPasteboard.general is shared by every HUD instance and menu action.
    static var isTemporaryOperationInFlight: Bool {
        activeTemporaryOperationToken != nil
    }

    static func pasteToCodex(
        processID: pid_t?,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        performPaste(
            processID: processID,
            submitAfterPaste: false,
            operation: "paste",
            completion: completion
        )
    }

    /// Pastes the current clipboard into Codex and submits it with one Return
    /// key event. The optional completion is called exactly once for the
    /// submit flow, after Return succeeds or the guarded flow aborts.
    static func pasteAndSubmitToCodex(
        processID: pid_t?,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        performPaste(
            processID: processID,
            submitAfterPaste: true,
            operation: "paste-and-submit",
            completion: completion
        )
    }

    /// Seeds the Codex composer with a temporary prompt without changing the
    /// semantics of the normal user-clipboard paste APIs above.  A complete
    /// pasteboard snapshot is restored only while this operation still owns
    /// the prepared text and no external clipboard change was observed.
    static func pasteTemporaryTextToCodex(
        _ shortcut: CodexPromptShortcut,
        processID: pid_t?,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        let timing = ClipboardPasteTimingProbe(operation: "temporary-\(shortcut.rawValue)")
        guard ClipboardTemporaryOperationPolicy.canStart(
            isOperationInFlight: activeTemporaryOperationToken != nil
        ) else {
            timing.mark("aborted", detail: "operation_already_in_flight")
            completion(false)
            return
        }

        if ContinuePromptTransportPolicy.usesDirectUnicodeText(for: shortcut) {
            guard let target = processID.flatMap(NSRunningApplication.init),
                  isCodexApplication(target),
                  isTargetFrontmost(target) else {
                timing.mark("aborted", detail: "continue_target_not_verified_frontmost")
                completion(false)
                return
            }
            performContinueDirectUnicodeText(
                shortcut.text,
                target: target,
                timing: timing,
                completion: completion
            )
            return
        }

        guard let target = processID.flatMap(NSRunningApplication.init)
                ?? NSWorkspace.shared.runningApplications.first(where: isCodexApplication),
              isCodexApplication(target) else {
            timing.mark("aborted", detail: "codex_target_unavailable")
            completion(false)
            return
        }

        if WorkflowPromptAXInsertionPolicy.usesAXFastPath(
            for: .workflowShortcut(shortcut)
        ) {
            let axAttempt = attemptWorkflowAXInsertion(
                shortcut,
                into: target,
                requestedProcessID: processID,
                timing: timing
            )
            if WorkflowPromptAXInsertionPolicy.shouldUseClipboardFallback(
                afterAXInsertionSucceeded: axAttempt.succeeded,
                // The AX API result confirms only that the attribute write was
                // accepted. No composer semantic-confirmation contract exists.
                semanticInsertionConfirmed: false
            ) {
                timing.mark(
                    "clipboard_fallback_begin",
                    detail: "reason=\(axAttempt.failureReason?.rawValue ?? "unknown") target_match=\(axAttempt.targetMatched)"
                )
            } else {
                if WorkflowPromptAXInsertionPolicy.shouldSubmit(
                    shortcut: shortcut,
                    axInsertionSucceeded: true
                ) {
                    guard let insertedElement = axAttempt.insertedElement else {
                        timing.mark(
                            "ax_return_aborted",
                            detail: "reason=inserted_element_unavailable target_match=false"
                        )
                        completion(false)
                        return
                    }
                    submitAXInsertedContinue(
                        shortcut,
                        to: target,
                        insertedElement: insertedElement,
                        timing: timing,
                        completion: completion
                    )
                } else {
                    timing.mark("completion_callback", detail: "ax_insert_succeeded")
                    completion(true)
                }
                return
            }
        }

        guard isEventPostingAuthorized() else {
            timing.mark("aborted", detail: "accessibility_not_trusted")
            promptForAccessibilityPermissionIfNeeded()
            completion(false)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshotCaptureStartedAt = DispatchTime.now().uptimeNanoseconds
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else {
            timing.markDuration(
                "snapshot_capture_failed",
                startedAtUptimeNanoseconds: snapshotCaptureStartedAt
            )
            completion(false)
            return
        }
        timing.markDuration(
            "snapshot_capture_complete",
            startedAtUptimeNanoseconds: snapshotCaptureStartedAt
        )
        let initialChangeCount = pasteboard.changeCount

        let token = UUID()
        activeTemporaryOperationToken = token
        let prepareAndPaste = {
            guard isTemporaryOperationOwned(by: token),
                  isTargetFrontmost(target),
                  pasteboard.changeCount == initialChangeCount else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: nil,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: false
                )
                return
            }

            let prepareStartedAt = DispatchTime.now().uptimeNanoseconds
            let beforeChangeCount = pasteboard.changeCount
            let clearedChangeCount = pasteboard.clearContents()
            guard pasteboard.pasteboardItems?.isEmpty ?? true else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: clearedChangeCount,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: false
                )
                return
            }
            guard pasteboard.setString(shortcut.text, forType: .string) else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: pasteboard.changeCount,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: false
                )
                return
            }

            let preparedChangeCount = pasteboard.changeCount
            guard preparedTextWriteIsValid(
                expectedText: shortcut.text,
                observedText: pasteboard.string(forType: .string),
                beforeChangeCount: beforeChangeCount,
                afterChangeCount: preparedChangeCount
            ),
            preparedChangeCount == clearedChangeCount
                || preparedChangeCount == clearedChangeCount + 1 else {
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: false
                )
                return
            }

            timing.markDuration(
                "temporary_text_prepared",
                startedAtUptimeNanoseconds: prepareStartedAt
            )

            guard isEventPostingAuthorized(),
                  isTargetFrontmost(target),
                  pasteboard.changeCount == preparedChangeCount,
                  pasteboard.string(forType: .string) == shortcut.text else {
                timing.mark("cmdv_post_failed", detail: "temporary")
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: false
                )
                return
            }

            let cmdvPostStartedAt = DispatchTime.now().uptimeNanoseconds
            guard postKey(keyCode: 9, flags: .maskCommand) else {
                timing.mark("cmdv_post_failed", detail: "temporary")
                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: false
                )
                return
            }
            timing.markDuration("cmdv_posted", startedAtUptimeNanoseconds: cmdvPostStartedAt)
            timing.mark("t2_cmdv_posted", detail: "temporary")

            if shortcut.submitPolicy == .pasteOnly {
                // Allow the asynchronous Cmd-V event to be consumed before
                // restoring the user's full clipboard snapshot.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    finishTemporaryOperation(
                        token: token,
                        snapshot: snapshot,
                        preparedChangeCount: preparedChangeCount,
                        expectedText: shortcut.text,
                        timing: timing,
                        completion: completion,
                        success: true
                    )
                }
                return
            }

            // `.singleReturn` reaches this branch and posts exactly one Return
            // below. Posting that key event is not proof Codex accepted a new
            // continuation turn; that requires native runtime evidence.
            let submitSettle = ClipboardPasteSettlePolicy.temporarySubmitSettle(for: shortcut)
            timing.mark(
                "submit_settle_policy_resolved",
                detail: "kind=temporary_text delay_ms=\(Int((submitSettle * 1_000).rounded()))"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + submitSettle) {
                guard isTemporaryOperationOwned(by: token),
                      isEventPostingAuthorized(),
                      !target.isTerminated,
                      isTargetFrontmost(target),
                      pasteboard.changeCount == preparedChangeCount,
                      pasteboard.string(forType: .string) == shortcut.text else {
                    finishTemporaryOperation(
                        token: token,
                        snapshot: snapshot,
                        preparedChangeCount: preparedChangeCount,
                        expectedText: shortcut.text,
                        timing: timing,
                        completion: completion,
                        success: false
                    )
                    return
                }

                let returnPostStartedAt = DispatchTime.now().uptimeNanoseconds
                guard postKey(keyCode: 36) else {
                    timing.mark("return_post_failed", detail: "temporary")
                    finishTemporaryOperation(
                        token: token,
                        snapshot: snapshot,
                        preparedChangeCount: preparedChangeCount,
                        expectedText: shortcut.text,
                        timing: timing,
                        completion: completion,
                        success: false
                    )
                    return
                }
                timing.markDuration(
                    "return_posted",
                    startedAtUptimeNanoseconds: returnPostStartedAt,
                    detail: "temporary"
                )

                finishTemporaryOperation(
                    token: token,
                    snapshot: snapshot,
                    preparedChangeCount: preparedChangeCount,
                    expectedText: shortcut.text,
                    timing: timing,
                    completion: completion,
                    success: true
                )
            }
        }

        let targetWasFrontmost = isTargetFrontmost(target)
        let dispatchDecision = ClipboardPasteDispatchPolicy.decision(
            targetIsVerifiedFrontmost: targetWasFrontmost
        )
        timing.mark(
            "t1_policy_resolved",
            detail: "frontmost=\(targetWasFrontmost) decision=\(String(describing: dispatchDecision))"
        )
        if dispatchDecision == .immediateFrontmost {
            // Preserve the already-published in-flight UI state for one
            // render turn before the fast clipboard dispatch can complete. If
            // focus changes during that turn, keep the existing activation
            // fallback instead of failing a valid user action silently.
            DispatchQueue.main.async {
                if isTargetFrontmost(target) {
                    prepareAndPaste()
                } else {
                    timing.mark("fallback_activation_requested", detail: "frontmost_changed_before_dispatch")
                    waitForTargetActivation(target, timeout: 0.20, timing: timing) { _ in
                        prepareAndPaste()
                    }
                }
            }
        } else {
            timing.mark("fallback_activation_requested", detail: "initial_policy")
            waitForTargetActivation(target, timeout: 0.20, timing: timing) { _ in
                prepareAndPaste()
            }
        }
    }

    private struct AXWorkflowInsertionAttempt {
        let succeeded: Bool
        let failureReason: WorkflowPromptAXInsertionFailureReason?
        let targetMatched: Bool
        let insertedElement: AXUIElement?
    }

    private static func attemptWorkflowAXInsertion(
        _ shortcut: CodexPromptShortcut,
        into target: NSRunningApplication,
        requestedProcessID: pid_t?,
        timing: ClipboardPasteTimingProbe
    ) -> AXWorkflowInsertionAttempt {
        let attemptStartedAt = DispatchTime.now().uptimeNanoseconds
        let processIdentityMatches = isCurrentTargetProcess(target)
        let requestedProcessMatches = requestedProcessID == nil
            || requestedProcessID == target.processIdentifier
        let targetIsCodex = isCodexApplication(target)
        let initiallyFrontmost = isTargetFrontmost(target)
        let initialTargetMatch = processIdentityMatches
            && requestedProcessMatches
            && targetIsCodex
            && initiallyFrontmost
        timing.mark("ax_fast_path_begin", detail: "target_match=\(initialTargetMatch)")

        func failed(
            _ reason: WorkflowPromptAXInsertionFailureReason,
            axErrorCode: Int32? = nil,
            targetMatched: Bool = false,
            focusedResolutionAlreadyLogged: Bool = false
        ) -> AXWorkflowInsertionAttempt {
            if !focusedResolutionAlreadyLogged {
                timing.mark(
                    "ax_focused_element_resolved",
                    detail: "resolved=false reason=\(reason.rawValue) target_match=\(targetMatched)"
                )
            }
            let errorDetail = axErrorCode.map { " ax_error_code=\($0)" } ?? ""
            timing.markDuration(
                "ax_insert_failed",
                startedAtUptimeNanoseconds: attemptStartedAt,
                detail: "reason=\(reason.rawValue)\(errorDetail) target_match=\(targetMatched)"
            )
            return AXWorkflowInsertionAttempt(
                succeeded: false,
                failureReason: reason,
                targetMatched: targetMatched,
                insertedElement: nil
            )
        }

        guard processIdentityMatches else {
            return failed(.targetUnavailable)
        }
        guard requestedProcessMatches else {
            return failed(.targetUnavailable)
        }
        guard targetIsCodex else {
            return failed(.wrongApplication)
        }
        guard initiallyFrontmost else {
            return failed(.targetNotFrontmost)
        }
        guard AXIsProcessTrusted() else {
            return failed(.accessibilityUntrusted)
        }

        let focusedResolutionStartedAt = DispatchTime.now().uptimeNanoseconds
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        var focusedElementValue: CFTypeRef?
        let focusedElementError = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementError == .success else {
            timing.markDuration(
                "ax_focused_element_resolved",
                startedAtUptimeNanoseconds: focusedResolutionStartedAt,
                detail: "resolved=false reason=\(WorkflowPromptAXInsertionFailureReason.focusedElementUnavailable.rawValue) target_match=false"
            )
            return failed(
                .focusedElementUnavailable,
                axErrorCode: Int32(focusedElementError.rawValue),
                focusedResolutionAlreadyLogged: true
            )
        }
        guard let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            timing.markDuration(
                "ax_focused_element_resolved",
                startedAtUptimeNanoseconds: focusedResolutionStartedAt,
                detail: "resolved=false reason=\(WorkflowPromptAXInsertionFailureReason.focusedElementUnavailable.rawValue) target_match=false"
            )
            return failed(
                .focusedElementUnavailable,
                focusedResolutionAlreadyLogged: true
            )
        }
        let focusedElement = unsafeBitCast(focusedElementValue, to: AXUIElement.self)

        var focusedElementPID: pid_t = 0
        let focusedElementPIDError = AXUIElementGetPid(focusedElement, &focusedElementPID)
        let focusedElementMatchesTarget = focusedElementPIDError == .success
            && focusedElementPID == target.processIdentifier
        timing.markDuration(
            "ax_focused_element_resolved",
            startedAtUptimeNanoseconds: focusedResolutionStartedAt,
            detail: "resolved=true target_match=\(focusedElementMatchesTarget)"
        )
        guard focusedElementPIDError == .success else {
            return failed(
                .focusedElementUnavailable,
                axErrorCode: Int32(focusedElementPIDError.rawValue),
                targetMatched: false,
                focusedResolutionAlreadyLogged: true
            )
        }
        guard focusedElementMatchesTarget else {
            return failed(
                .targetPIDMismatch,
                targetMatched: false,
                focusedResolutionAlreadyLogged: true
            )
        }

        var selectedTextSettable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        )
        let eligibility = WorkflowPromptAXInsertionEligibility(
            targetIsAvailable: isCurrentTargetProcess(target),
            targetPIDMatchesRequest: requestedProcessID == nil
                || requestedProcessID == target.processIdentifier,
            targetIsCodex: isCodexApplication(target),
            targetIsFrontmost: isTargetFrontmost(target),
            accessibilityTrusted: AXIsProcessTrusted(),
            focusedElementResolved: true,
            focusedElementPIDMatchesTarget: focusedElementMatchesTarget,
            selectedTextAttributeSettable: settableError == .success && selectedTextSettable.boolValue
        )
        switch WorkflowPromptAXInsertionPolicy.decision(for: eligibility) {
        case .attemptAXInsertion:
            break
        case .clipboardFallback(let reason):
            let reportedReason: WorkflowPromptAXInsertionFailureReason
            if reason == .selectedTextNotSettable, settableError != .success {
                reportedReason = .selectedTextNotSettable
            } else {
                reportedReason = reason
            }
            return failed(
                reportedReason,
                axErrorCode: settableError == .success ? nil : Int32(settableError.rawValue),
                targetMatched: focusedElementMatchesTarget,
                focusedResolutionAlreadyLogged: true
            )
        }

        // Revalidate the exact running Codex identity and focus immediately
        // before writing. No composer text is read at any point.
        guard isCurrentTargetProcess(target) else {
            return failed(
                .targetUnavailable,
                targetMatched: focusedElementMatchesTarget,
                focusedResolutionAlreadyLogged: true
            )
        }
        guard isTargetFrontmost(target) else {
            return failed(
                .targetNotFrontmost,
                targetMatched: focusedElementMatchesTarget,
                focusedResolutionAlreadyLogged: true
            )
        }
        guard AXIsProcessTrusted() else {
            return failed(
                .accessibilityUntrusted,
                targetMatched: focusedElementMatchesTarget,
                focusedResolutionAlreadyLogged: true
            )
        }

        let insertionError = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            shortcut.text as CFString
        )
        guard insertionError == .success else {
            return failed(
                .insertionFailed,
                axErrorCode: Int32(insertionError.rawValue),
                targetMatched: focusedElementMatchesTarget,
                focusedResolutionAlreadyLogged: true
            )
        }

        timing.markDuration(
            "ax_insert_succeeded",
            startedAtUptimeNanoseconds: attemptStartedAt,
            detail: "target_match=true"
        )
        return AXWorkflowInsertionAttempt(
            succeeded: true,
            failureReason: nil,
            targetMatched: true,
            insertedElement: focusedElement
        )
    }

    private static func submitAXInsertedContinue(
        _ shortcut: CodexPromptShortcut,
        to target: NSRunningApplication,
        insertedElement: AXUIElement,
        timing: ClipboardPasteTimingProbe,
        completion: @escaping (Bool) -> Void
    ) {
        let token = UUID()
        activeTemporaryOperationToken = token
        let settle = ClipboardPasteSettlePolicy.temporarySubmitSettle(for: shortcut)
        timing.mark(
            "submit_settle_policy_resolved",
            detail: "kind=ax_workflow_text delay_ms=\(Int((settle * 1_000).rounded()))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard activeTemporaryOperationToken == token else {
                timing.mark("ax_return_aborted", detail: "reason=operation_no_longer_owned target_match=false")
                completion(false)
                return
            }

            let processMatches = isCurrentTargetProcess(target)
            let frontmostMatches = isTargetFrontmost(target)
            let accessibilityTrusted = AXIsProcessTrusted()
            let eventPostingAuthorized = isEventPostingAuthorized()
            let focusedTarget = focusedElementCanReceiveWorkflowText(
                for: target,
                matching: insertedElement
            )
            guard WorkflowPromptAXInsertionPolicy.mayPostReturn(
                    shortcut: shortcut,
                    axInsertionSucceeded: true,
                    focusedElementMatchesInsertion: focusedTarget.matches
                  ),
                  processMatches,
                  frontmostMatches,
                  accessibilityTrusted,
                  focusedTarget.selectedTextSettable,
                  eventPostingAuthorized else {
                let reason: String
                if !processMatches {
                    reason = "target_process_changed"
                } else if !frontmostMatches {
                    reason = "target_not_frontmost"
                } else if !accessibilityTrusted {
                    reason = "ax_untrusted"
                } else if !focusedTarget.matches {
                    reason = focusedTarget.reason.rawValue
                } else if !focusedTarget.selectedTextSettable {
                    reason = WorkflowPromptAXInsertionFailureReason.selectedTextNotSettable.rawValue
                } else {
                    reason = "event_posting_unavailable"
                }
                activeTemporaryOperationToken = nil
                timing.mark(
                    "ax_return_aborted",
                    detail: "reason=\(reason) target_match=\(focusedTarget.matches)"
                )
                completion(false)
                return
            }

            guard postKey(keyCode: 36) else {
                activeTemporaryOperationToken = nil
                timing.mark("ax_return_post_failed", detail: "target_match=true")
                completion(false)
                return
            }
            activeTemporaryOperationToken = nil
            timing.mark("ax_return_posted", detail: "target_match=true")
            timing.mark("completion_callback", detail: "ax_insert_then_return")
            completion(true)
        }
    }

    private struct FocusedWorkflowTextTarget {
        let matches: Bool
        let selectedTextSettable: Bool
        let reason: WorkflowPromptAXInsertionFailureReason
    }

    private static func focusedElementCanReceiveWorkflowText(
        for target: NSRunningApplication,
        matching insertedElement: AXUIElement
    ) -> FocusedWorkflowTextTarget {
        guard AXIsProcessTrusted() else {
            return FocusedWorkflowTextTarget(
                matches: false,
                selectedTextSettable: false,
                reason: .accessibilityUntrusted
            )
        }
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        var focusedElementValue: CFTypeRef?
        let focusedElementError = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementError == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return FocusedWorkflowTextTarget(
                matches: false,
                selectedTextSettable: false,
                reason: .focusedElementUnavailable
            )
        }
        let focusedElement = unsafeBitCast(focusedElementValue, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        let pidError = AXUIElementGetPid(focusedElement, &focusedPID)
        let matches = pidError == .success && focusedPID == target.processIdentifier
        guard matches else {
            return FocusedWorkflowTextTarget(
                matches: false,
                selectedTextSettable: false,
                reason: .targetPIDMismatch
            )
        }
        // AXUIElementRef supports CFEqual; fail closed if focus moved after
        // insertion, even when the newly focused control belongs to Codex.
        guard CFEqual(focusedElement, insertedElement) else {
            return FocusedWorkflowTextTarget(
                matches: false,
                selectedTextSettable: false,
                reason: .focusedElementChanged
            )
        }
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        return FocusedWorkflowTextTarget(
            matches: true,
            selectedTextSettable: settableError == .success && settable.boolValue,
            reason: .selectedTextNotSettable
        )
    }

    private static func isCurrentTargetProcess(_ target: NSRunningApplication) -> Bool {
        guard !target.isTerminated,
              let expectedLaunchDate = target.launchDate,
              let expectedBundleURL = target.bundleURL?.standardizedFileURL,
              let current = NSRunningApplication(processIdentifier: target.processIdentifier),
              !current.isTerminated,
              current.launchDate == expectedLaunchDate,
              current.bundleURL?.standardizedFileURL == expectedBundleURL else {
            return false
        }
        return isCodexApplication(current)
    }

    /// `setString` is allowed to leave NSPasteboard.changeCount unchanged on
    /// macOS.  Exact readback is the semantic guard; the counter only needs
    /// to be monotonic so an unrelated write can never look like our prepare.
    static func preparedTextWriteIsValid(
        expectedText: String,
        observedText: String?,
        beforeChangeCount: Int,
        afterChangeCount: Int
    ) -> Bool {
        ClipboardTemporaryOperationPolicy.preparedTextWriteIsValid(
            expectedText: expectedText,
            observedText: observedText,
            beforeChangeCount: beforeChangeCount,
            afterChangeCount: afterChangeCount
        )
    }

    private static func isTemporaryOperationOwned(by token: UUID) -> Bool {
        activeTemporaryOperationToken == token
    }

    @discardableResult
    private static func finishTemporaryOperation(
        token: UUID,
        snapshot: PasteboardSnapshot,
        preparedChangeCount: Int?,
        expectedText: String,
        timing: ClipboardPasteTimingProbe,
        completion: @escaping (Bool) -> Void,
        success: Bool
    ) -> Bool {
        guard activeTemporaryOperationToken == token else {
            if completedTemporaryOperationTokens.insert(token).inserted {
                completion(false)
            }
            return false
        }

        var finalSuccess = success
        if let preparedChangeCount {
            let pasteboard = NSPasteboard.general
            let unchanged = pasteboard.changeCount == preparedChangeCount
            if unchanged {
                // On a failure after clearContents (including setString
                // returning false or a readback mismatch), restore whenever
                // the clipboard is still ours.  On success require the exact
                // expected text before restoring.
                let mayRestore = !success || ClipboardTemporaryOperationPolicy.canRestore(
                    expectedText: expectedText,
                    observedText: pasteboard.string(forType: .string),
                    preparedChangeCount: preparedChangeCount,
                    currentChangeCount: pasteboard.changeCount
                )
                if mayRestore {
                    let restoreStartedAt = DispatchTime.now().uptimeNanoseconds
                    let restored = snapshot.restore(to: pasteboard)
                    timing.markDuration(
                        "clipboard_restored",
                        startedAtUptimeNanoseconds: restoreStartedAt,
                        detail: "success=\(restored)"
                    )
                    finalSuccess = restored && finalSuccess
                } else {
                    timing.mark("clipboard_restore_skipped", detail: "ownership_changed")
                    finalSuccess = false
                }
            } else {
                // The user changed the clipboard after preparation.  Do not
                // overwrite their newer content with our old snapshot.
                timing.mark("clipboard_restore_skipped", detail: "external_change")
                finalSuccess = false
            }
        } else {
            timing.mark("clipboard_restore_skipped", detail: "text_not_prepared")
        }
        completedTemporaryOperationTokens.insert(token)
        if completedTemporaryOperationTokens.count > 64 {
            completedTemporaryOperationTokens.removeAll(keepingCapacity: true)
        }
        activeTemporaryOperationToken = nil
        completion(finalSuccess)
        return finalSuccess
    }

    private struct PasteboardSnapshot {
        struct Item {
            let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
        }

        let items: [Item]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
            guard let pasteboardItems = pasteboard.pasteboardItems else {
                return PasteboardSnapshot(items: [])
            }

            var items: [Item] = []
            items.reserveCapacity(pasteboardItems.count)
            for pasteboardItem in pasteboardItems {
                var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                representations.reserveCapacity(pasteboardItem.types.count)
                for type in pasteboardItem.types {
                    guard let data = pasteboardItem.data(forType: type) else {
                        return nil
                    }
                    representations.append((type: type, data: data))
                }
                guard !representations.isEmpty else { return nil }
                items.append(Item(representations: representations))
            }
            return PasteboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) -> Bool {
            pasteboard.clearContents()
            let restoredItems: [NSPasteboardItem] = items.map { item in
                let pasteboardItem = NSPasteboardItem()
                for representation in item.representations {
                    pasteboardItem.setData(representation.data, forType: representation.type)
                }
                return pasteboardItem
            }
            guard !restoredItems.isEmpty else { return true }
            if pasteboard.writeObjects(restoredItems) { return true }
            // A transient pasteboard provider failure should not leave the
            // user's clipboard empty. Retry the complete item set once; if
            // this also fails the operation reports failure without ever
            // attempting to restore over newer external content.
            pasteboard.clearContents()
            return pasteboard.writeObjects(restoredItems)
        }
    }

    private static func performPaste(
        processID: pid_t?,
        submitAfterPaste: Bool,
        operation: String,
        completion: ((Bool) -> Void)?
    ) {
        let timing = ClipboardPasteTimingProbe(operation: operation)
        guard NSPasteboard.general.canReadObject(forClasses: [NSString.self, NSImage.self], options: nil) else {
            timing.mark("aborted", detail: "clipboard_unreadable")
            showAlert(
                title: "剪貼簿沒有可貼上的內容",
                message: "請先複製文字或圖片，再按一次貼上。"
            )
            completion?(false)
            return
        }

        guard let target = processID.flatMap(NSRunningApplication.init)
                ?? NSWorkspace.shared.runningApplications.first(where: isCodexApplication),
              isCodexApplication(target) else {
            timing.mark("aborted", detail: "codex_target_unavailable")
            showAlert(
                title: "找不到 Codex",
                message: "請先開啟 Codex，再使用剪貼簿貼上。"
            )
            completion?(false)
            return
        }

        guard isEventPostingAuthorized() else {
            timing.mark("aborted", detail: "accessibility_not_trusted")
            promptForAccessibilityPermissionIfNeeded()
            completion?(false)
            return
        }

        let dispatchIfFrontmost = {
            guard isTargetFrontmost(target) else {
                timing.mark("fallback_activation_requested", detail: "frontmost_recheck_failed")
                waitForTargetActivation(target, timeout: 0.18, timing: timing) { activated in
                    guard activated, isTargetFrontmost(target) else {
                        timing.mark("aborted", detail: "frontmost_retry_failed")
                        showAlert(
                            title: "無法貼上剪貼簿內容",
                            message: "Codex 沒有保持在前景，為安全起見沒有貼上或送出。"
                        )
                        completion?(false)
                        return
                    }
                    finishPaste(
                        to: target,
                        submitAfterPaste: submitAfterPaste,
                        timing: timing,
                        completion: completion
                    )
                }
                return
            }
            finishPaste(
                to: target,
                submitAfterPaste: submitAfterPaste,
                timing: timing,
                completion: completion
            )
        }

        let targetWasFrontmost = isTargetFrontmost(target)
        let dispatchDecision = ClipboardPasteDispatchPolicy.decision(
            targetIsVerifiedFrontmost: targetWasFrontmost
        )
        timing.mark(
            "t1_policy_resolved",
            detail: "frontmost=\(targetWasFrontmost) decision=\(String(describing: dispatchDecision))"
        )
        if dispatchDecision == .immediateFrontmost {
            // The HUD action has already published its in-flight state. Yield
            // one main-loop turn so SwiftUI can render that acknowledgement
            // before a fast Cmd-V completion clears it.
            DispatchQueue.main.async {
                dispatchIfFrontmost()
            }
        } else {
            // The HUD is a non-activating panel. Activate Codex first and then
            // post the shortcut to the active session, so the restored text
            // field receives it even when the original window was rebuilt.
            timing.mark("fallback_activation_requested", detail: "initial_policy")
            waitForTargetActivation(target, timeout: 0.20, timing: timing) { _ in
                dispatchIfFrontmost()
            }
        }
    }

    private static func finishPaste(
        to target: NSRunningApplication,
        submitAfterPaste: Bool,
        timing: ClipboardPasteTimingProbe,
        completion: ((Bool) -> Void)?
    ) {
        // Focus can change between the delayed activation check and this
        // event post. Revalidate both process liveness and signed publisher
        // immediately before Cmd-V so another app cannot receive the paste.
        guard isEventPostingAuthorized(), isTargetFrontmost(target) else {
            timing.mark("aborted", detail: "final_frontmost_or_accessibility_check_failed")
            showAlert(
                title: "無法貼上剪貼簿內容",
                message: "Codex 沒有保持在前景，為安全起見沒有貼上或送出。"
            )
            completion?(false)
            return
        }
        let pasteboard = NSPasteboard.general
        let settleInterval = submitAfterPaste
            ? ClipboardPasteSettlePolicy.normalSubmitSettle(
                itemTypeIdentifiers: pasteboardItemTypeIdentifiers(from: pasteboard)
            )
            : 0
        if submitAfterPaste {
            let settleKind = settleInterval == ClipboardPasteSettlePolicy.shortTextSettle
                ? "plain_text"
                : "safe_content"
            timing.mark(
                "submit_settle_policy_resolved",
                detail: "kind=\(settleKind) delay_ms=\(Int((settleInterval * 1_000).rounded()))"
            )
        }
        let cmdvPostStartedAt = DispatchTime.now().uptimeNanoseconds
        guard postKey(keyCode: 9, flags: .maskCommand) else {
            timing.mark("cmdv_post_failed", detail: "normal")
            showAlert(
                title: "無法貼上剪貼簿內容",
                message: "目前無法建立鍵盤事件。請重新開啟 CodexUsageStatus 後再試一次。"
            )
            completion?(false)
            return
        }

        timing.markDuration("cmdv_posted", startedAtUptimeNanoseconds: cmdvPostStartedAt)
        timing.mark("t2_cmdv_posted", detail: submitAfterPaste ? "normal-submit" : "normal")

        guard submitAfterPaste else {
            // The Cmd-V event has been posted and the accepted action can now
            // clear its local acknowledgement state. The focus/safety checks
            // above remain unchanged and still gate the event itself.
            timing.mark("completion_callback", detail: "cmdv_posted")
            completion?(true)
            return
        }

        // Plain text gets a bounded short settle; image, rich, multi-item, or
        // unknown representations keep the existing conservative window.
        // Focus is still revalidated before Return so an intervening app can
        // never receive the submit key.
        DispatchQueue.main.asyncAfter(deadline: .now() + settleInterval) {
            guard isEventPostingAuthorized(), !target.isTerminated, isTargetFrontmost(target) else {
                timing.mark("aborted", detail: "submit_settle_focus_check_failed")
                showAlert(
                    title: "貼上完成，但尚未送出",
                    message: "Codex 已不是前景視窗，為安全起見沒有發送 Enter。"
                )
                completion?(false)
                return
            }

            guard postKey(keyCode: 36) else {
                timing.mark("return_post_failed", detail: "submit")
                showAlert(
                    title: "無法送出貼上的內容",
                    message: "目前無法建立 Enter 鍵盤事件。請重新開啟 CodexUsageStatus 後再試一次。"
                )
                completion?(false)
                return
            }
            timing.mark("return_posted", detail: "submit")
            timing.mark("completion_callback", detail: "return_posted")
            completion?(true)
        }
    }

    private static func isTargetFrontmost(_ target: NSRunningApplication) -> Bool {
        guard !target.isTerminated,
              let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return frontmost.processIdentifier == target.processIdentifier
            && frontmost.launchDate == target.launchDate
            && frontmost.bundleURL == target.bundleURL
            && isCodexApplication(frontmost)
    }

    private static func waitForTargetActivation(
        _ target: NSRunningApplication,
        timeout: TimeInterval,
        timing: ClipboardPasteTimingProbe,
        completion: @escaping (Bool) -> Void
    ) {
        TargetActivationWaiter(
            target: target,
            timeout: timeout,
            timing: timing,
            completion: completion
        ).start()
    }

    private static func pasteboardItemTypeIdentifiers(from pasteboard: NSPasteboard) -> [[String]] {
        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            return items.map { $0.types.map(\.rawValue) }
        }
        guard let types = pasteboard.types, !types.isEmpty else { return [] }
        return [types.map(\.rawValue)]
    }

    private static func postKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags = []
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnicodeText(_ text: String) -> Bool {
        guard let units = ContinuePromptTransportPolicy.unicodeUnits(for: text),
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        let unicodePayloadConfigured = units.withUnsafeBufferPointer { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            return true
        }
        guard unicodePayloadConfigured else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func performContinueDirectUnicodeText(
        _ text: String,
        target: NSRunningApplication,
        timing: ClipboardPasteTimingProbe,
        completion: @escaping (Bool) -> Void
    ) {
        let token = UUID()
        activeTemporaryOperationToken = token
        defer {
            if activeTemporaryOperationToken == token {
                activeTemporaryOperationToken = nil
            }
        }

        guard isEventPostingAuthorized() else {
            timing.mark("aborted", detail: "accessibility_not_trusted")
            promptForAccessibilityPermissionIfNeeded()
            completion(false)
            return
        }
        guard !target.isTerminated, isTargetFrontmost(target) else {
            timing.mark("aborted", detail: "continue_target_lost_before_text")
            completion(false)
            return
        }

        timing.mark("continue_direct_text_begin", detail: "transport=quartz_unicode")
        guard postUnicodeText(text) else {
            timing.mark("aborted", detail: "continue_unicode_event_creation_failed")
            completion(false)
            return
        }
        timing.mark("temporary_text_prepared", detail: "transport=quartz_unicode")
        timing.mark("continue_unicode_text_posted", detail: "transport=quartz_unicode")

        guard isEventPostingAuthorized(),
              !target.isTerminated,
              isTargetFrontmost(target) else {
            timing.mark("aborted", detail: "continue_target_or_authority_lost_before_return")
            completion(false)
            return
        }

        timing.mark(
            "submit_settle_policy_resolved",
            detail: "kind=temporary_text delay_ms=0 transport=quartz_unicode"
        )
        guard postKey(keyCode: 36) else {
            timing.mark("return_post_failed", detail: "continue_direct")
            completion(false)
            return
        }
        timing.mark("return_posted", detail: "temporary transport=quartz_unicode")
        timing.mark("completion_callback", detail: "continue_direct_return_posted")
        completion(true)
    }

    private static func isEventPostingAuthorized() -> Bool {
        AccessibilityPermissionPolicy.current() == .trusted
    }

    private static func promptForAccessibilityPermissionIfNeeded() {
        let now = Date()
        // A click can arrive again while the user is still reading Settings.
        // Avoid presenting a stack of identical modal alerts.
        if let lastPermissionPromptAt,
           now.timeIntervalSince(lastPermissionPromptAt) < 12 {
            return
        }
        lastPermissionPromptAt = now

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要輔助功能權限"
        alert.informativeText = "要替你把剪貼簿貼到 Codex，請在「系統設定 → 隱私權與安全性 → 輔助功能」允許目前正在使用的 CodexUsageStatus.app。正常的正式簽章更新會保留 App 身份；只有權限狀態確實失效時才需要重新處理。"
        alert.addButton(withTitle: "開啟輔助功能設定")
        alert.addButton(withTitle: "稍後")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private static func openAccessibilitySettings() {
        AccessibilityPermissionPolicy.openSettings()
    }

    private static func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        CodexApplicationPolicy.isCodexApplication(application)
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
