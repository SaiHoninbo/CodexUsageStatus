import Foundation

enum HUDPositionResult: Equatable {
    case positioned
    case retainedExistingPosition
    case unavailable
}

enum HUDVisibilityFocus: Equatable {
    case codex
    case otherApplication
    case unknown
}

enum HUDVisibilityDecision: Equatable {
    case hideImmediately
    case show
    case retainPanel
    case keepHidden
    case pendingHide
}

enum HUDVisibilityPolicy {
    static func visibilityDecision(
        enabled: Bool,
        focus: HUDVisibilityFocus,
        panelIsVisible: Bool,
        position: HUDPositionResult
    ) -> HUDVisibilityDecision {
        guard enabled else { return .hideImmediately }

        switch focus {
        case .unknown:
            return panelIsVisible ? .hideImmediately : .keepHidden
        case .otherApplication:
            return panelIsVisible ? .pendingHide : .keepHidden
        case .codex:
            switch position {
            case .positioned:
                return .show
            case .retainedExistingPosition:
                return .retainPanel
            case .unavailable:
                return panelIsVisible ? .hideImmediately : .keepHidden
            }
        }
    }

    static func positionResult(hasValidFrame: Bool, hasRetainableSafeFrame: Bool) -> HUDPositionResult {
        if hasValidFrame { return .positioned }
        return hasRetainableSafeFrame ? .retainedExistingPosition : .unavailable
    }

    static func focusDecision(
        focus: HUDVisibilityFocus,
        panelIsVisible: Bool,
        elapsedFocusLoss: TimeInterval,
        grace: TimeInterval
    ) -> HUDVisibilityDecision {
        switch focus {
        case .codex:
            return panelIsVisible ? .retainPanel : .keepHidden
        case .unknown:
            return panelIsVisible ? .hideImmediately : .keepHidden
        case .otherApplication:
            guard panelIsVisible else { return .keepHidden }
            return elapsedFocusLoss >= grace ? .hideImmediately : .pendingHide
        }
    }

    static func cachedPresentation(
        currentProfileID: UUID?,
        cached: HUDDualQuotaPresentation?
    ) -> HUDDualQuotaPresentation? {
        guard let currentProfileID,
              let cached,
              cached.profileID == currentProfileID else { return nil }
        return cached
    }

    /// Combine a partial live response with the last presentation for the
    /// same account. App Server responses can briefly omit one recognized
    /// window while refreshing; the available live window must win, while a
    /// missing window may retain its profile-bound value until it is refreshed.
    /// A profile mismatch is never eligible for this merge.
    static func mergedPresentation(
        currentProfileID: UUID?,
        live: HUDDualQuotaPresentation?,
        cached: HUDDualQuotaPresentation?
    ) -> HUDDualQuotaPresentation? {
        guard let currentProfileID else { return nil }
        let live = live?.profileID == currentProfileID ? live : nil
        let cached = cached?.profileID == currentProfileID ? cached : nil

        guard let live else { return cached }
        guard let cached else { return live }
        return HUDDualQuotaPresentation(
            profileID: currentProfileID,
            fiveHour: live.fiveHour ?? cached.fiveHour,
            sevenDay: live.sevenDay ?? cached.sevenDay
        )
    }

    static func presentationSnapshot(
        currentProfileID: UUID?,
        trackedProfileID: UUID?,
        lastUpdated: Date?,
        presentation: HUDDualQuotaPresentation?
    ) -> HUDDualQuotaPresentation? {
        guard let currentProfileID,
              currentProfileID == trackedProfileID,
              lastUpdated != nil,
              let presentation,
              presentation.profileID == currentProfileID,
              presentation.hasRecognizedWindow else { return nil }
        return presentation
    }

    static func shouldApplyFocusLoss(
        scheduledGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        scheduledGeneration == currentGeneration
    }

    /// Match a normalized AX focused-window frame against Quartz candidates.
    /// The caller owns PID, layer, and minimum-size filtering. When AX is
    /// unavailable, a single filtered Quartz candidate is still unambiguous
    /// for the frontmost process and may be accepted. When AX reports a
    /// synthetic full-screen window (as current Codex builds can), that same
    /// single-candidate rule bridges the geometry mismatch. Multiple
    /// candidates without a geometry match remain unavailable so first-show
    /// positioning never cross-wires another Codex window.
    static func uniqueQuartzWindowMatch(
        focusedBounds: CGRect?,
        candidates: [CGRect],
        tolerance: CGFloat = 24
    ) -> CGRect? {
        guard let focusedBounds else {
            guard candidates.count == 1 else { return nil }
            return candidates[0]
        }
        let matches = candidates.filter { candidate in
            abs(candidate.minX - focusedBounds.minX) <= tolerance
                && abs(candidate.minY - focusedBounds.minY) <= tolerance
                && abs(candidate.width - focusedBounds.width) <= tolerance
                && abs(candidate.height - focusedBounds.height) <= tolerance
        }
        if matches.count == 1 { return matches[0] }
        guard matches.isEmpty, candidates.count == 1,
              let candidate = candidates.first,
              focusedBounds.contains(candidate),
              focusedBounds.width > candidate.width + tolerance,
              focusedBounds.height > candidate.height + tolerance else {
            return nil
        }
        return candidate
    }
}
