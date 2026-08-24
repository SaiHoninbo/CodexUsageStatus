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

struct HUDPresentationSnapshot: Equatable {
    let profileID: UUID
    let remainingPercent: Int
    let resetDescription: String
}

enum HUDVisibilityPolicy {
    static func visibilityDecision(
        enabled: Bool,
        focus: HUDVisibilityFocus,
        panelIsVisible: Bool,
        hasValidQuota: Bool,
        position: HUDPositionResult
    ) -> HUDVisibilityDecision {
        guard enabled else { return .hideImmediately }

        switch focus {
        case .unknown:
            return panelIsVisible ? .retainPanel : .keepHidden
        case .otherApplication:
            return panelIsVisible ? .pendingHide : .keepHidden
        case .codex:
            guard hasValidQuota else {
                return panelIsVisible ? .retainPanel : .keepHidden
            }
            switch position {
            case .positioned:
                return .show
            case .retainedExistingPosition:
                return .retainPanel
            case .unavailable:
                return panelIsVisible ? .retainPanel : .keepHidden
            }
        }
    }

    static func positionResult(hasValidFrame: Bool, panelIsVisible: Bool) -> HUDPositionResult {
        if hasValidFrame { return .positioned }
        return panelIsVisible ? .retainedExistingPosition : .unavailable
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
            return panelIsVisible ? .retainPanel : .keepHidden
        case .otherApplication:
            guard panelIsVisible else { return .keepHidden }
            return elapsedFocusLoss >= grace ? .hideImmediately : .pendingHide
        }
    }

    static func cachedPresentation(
        currentProfileID: UUID?,
        cached: HUDPresentationSnapshot?
    ) -> HUDPresentationSnapshot? {
        guard let currentProfileID,
              let cached,
              cached.profileID == currentProfileID else { return nil }
        return cached
    }

    static func presentationSnapshot(
        currentProfileID: UUID?,
        trackedProfileID: UUID?,
        lastUpdated: Date?,
        remainingPercent: Int?,
        resetDescription: String
    ) -> HUDPresentationSnapshot? {
        guard let currentProfileID,
              currentProfileID == trackedProfileID,
              lastUpdated != nil,
              let remainingPercent else { return nil }
        return HUDPresentationSnapshot(
            profileID: currentProfileID,
            remainingPercent: remainingPercent,
            resetDescription: resetDescription
        )
    }

    static func shouldApplyFocusLoss(
        scheduledGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        scheduledGeneration == currentGeneration
    }

    /// Match a normalized AX focused-window frame against Quartz candidates.
    /// The caller owns PID, layer, and minimum-size filtering; this helper only
    /// decides whether geometry identifies exactly one candidate. Returning nil
    /// for zero or multiple matches keeps first-show positioning fail-closed.
    static func uniqueQuartzWindowMatch(
        focusedBounds: CGRect,
        candidates: [CGRect],
        tolerance: CGFloat = 24
    ) -> CGRect? {
        let matches = candidates.filter { candidate in
            abs(candidate.minX - focusedBounds.minX) <= tolerance
                && abs(candidate.minY - focusedBounds.minY) <= tolerance
                && abs(candidate.width - focusedBounds.width) <= tolerance
                && abs(candidate.height - focusedBounds.height) <= tolerance
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
