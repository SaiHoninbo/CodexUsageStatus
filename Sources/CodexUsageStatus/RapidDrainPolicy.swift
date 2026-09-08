import Foundation

enum RapidDrainSeverity: Int, Equatable, Comparable {
    case notice = 1
    case rapid = 2
    case severe = 3

    static func < (lhs: RapidDrainSeverity, rhs: RapidDrainSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var pulseCount: Int {
        switch self {
        case .notice: return 1
        case .rapid: return 2
        case .severe: return 3
        }
    }
}

struct ObservedRapidDrainEvent: Equatable, Identifiable {
    let id: UUID
    let profileID: UUID
    let limitID: String
    let resetAt: Int64
    let baselineRemainingPercent: Int
    let currentRemainingPercent: Int
    let observedDropPercent: Int
    let startAt: Date
    let endAt: Date
    let severity: RapidDrainSeverity

    var duration: TimeInterval { max(0, endAt.timeIntervalSince(startAt)) }
    var reason: String { "observed_quota_drop" }
}

struct RapidDrainStatusItemContent: Equatable {
    let title: String
    let tooltip: String

    init(event: ObservedRapidDrainEvent) {
        title = "↓\(event.observedDropPercent)%\n5h"
        tooltip = "Codex 5 小時可用量：觀察到下降 \(event.observedDropPercent)%，目前剩餘 \(event.currentRemainingPercent)%。"
    }
}

struct RapidDrainCoveredWindow: Equatable {
    let limitID: String
    let durationMins: Int64
    let resetAt: Int64
}

enum RapidDrainDetectorBoundaryPolicy {
    static func shouldResetForWorkerState(profileID: UUID, currentProfileID: UUID?) -> Bool {
        currentProfileID == profileID
    }
}

enum RapidDrainNotificationArbitrationPolicy {
    static func covers(
        snapshotLimitID: String?,
        window: RateLimitWindow,
        coveredWindow: RapidDrainCoveredWindow
    ) -> Bool {
        snapshotLimitID == coveredWindow.limitID
            && window.windowDurationMins == coveredWindow.durationMins
            && window.resetsAt == coveredWindow.resetAt
    }
}

private struct RapidDrainIdentity: Equatable {
    let profileID: UUID
    let limitID: String
    let resetAt: Int64
}

private struct RapidDrainObservation {
    let remainingPercent: Int
    let observedAt: Date
}

/// Stateful, in-memory policy for detecting a material five-hour quota drop.
/// It deliberately knows nothing about AppKit, notifications, foreground apps,
/// persistence, or the source of the live snapshot.
struct RapidDrainDetector {
    static let horizon: TimeInterval = 5 * 60
    static let maximumObservations = 32
    static let noticeThreshold = 3
    static let rapidThreshold = 5
    static let severeThreshold = 10
    static let successorDrop = 5

    private var identity: RapidDrainIdentity?
    private var observations: [RapidDrainObservation] = []
    private var lastEmittedAt: Date?
    private var lastEmittedRemaining: Int?
    /// Highest cumulative severity reached by the current rolling episode.
    /// A material successor may have a lower severity of its own, but it must
    /// never lower this episode-level peak and reopen an already-seen alert.
    private var episodePeakSeverity: RapidDrainSeverity?

    mutating func reset() {
        identity = nil
        observations.removeAll(keepingCapacity: true)
        lastEmittedAt = nil
        lastEmittedRemaining = nil
        episodePeakSeverity = nil
    }

    mutating func observe(snapshot: UsageSnapshot, profileID: UUID?, at observedAt: Date) -> ObservedRapidDrainEvent? {
        guard let profileID,
              let limitID = snapshot.limitId,
              !limitID.isEmpty else {
            reset()
            return nil
        }

        let fiveHourWindows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
            .filter { $0.windowDurationMins == HUDQuotaWindowKind.fiveHour.durationMins }
        guard fiveHourWindows.count == 1,
              let window = fiveHourWindows.first,
              let resetAt = window.resetsAt else {
            reset()
            return nil
        }

        let nextIdentity = RapidDrainIdentity(profileID: profileID, limitID: limitID, resetAt: resetAt)
        if identity != nextIdentity {
            identity = nextIdentity
            observations.removeAll(keepingCapacity: true)
            lastEmittedAt = nil
            lastEmittedRemaining = nil
            episodePeakSeverity = nil
        }

        if let last = observations.last, observedAt <= last.observedAt {
            return nil
        }

        observations.append(RapidDrainObservation(
            remainingPercent: window.remainingPercent,
            observedAt: observedAt
        ))
        let cutoff = observedAt.addingTimeInterval(-Self.horizon)
        observations.removeAll { $0.observedAt < cutoff }
        if observations.count > Self.maximumObservations {
            observations.removeFirst(observations.count - Self.maximumObservations)
        }

        guard let baseline = observations.first else { return nil }
        let current = window.remainingPercent
        guard current < baseline.remainingPercent else {
            // A reset or upward correction closes the episode and starts a new
            // baseline at the corrected value.
            observations = [RapidDrainObservation(remainingPercent: current, observedAt: observedAt)]
            lastEmittedAt = nil
            lastEmittedRemaining = nil
            episodePeakSeverity = nil
            return nil
        }

        let cumulativeDrop = baseline.remainingPercent - current
        let cumulativeSeverity = Self.severity(for: cumulativeDrop)
        let hasEmittedEvent = lastEmittedRemaining != nil
        let isEscalation = cumulativeSeverity.map { severity in
            hasEmittedEvent && (episodePeakSeverity.map { severity > $0 } ?? true)
        } ?? false
        let successorDrop = lastEmittedRemaining.map { $0 - current } ?? 0
        let isMaterialSuccessor = successorDrop >= Self.successorDrop
        let successorSeverity = isMaterialSuccessor ? Self.severity(for: successorDrop) : nil
        let shouldEmitEscalation = cumulativeSeverity != nil && isEscalation
        let shouldEmitSuccessor = isMaterialSuccessor
        guard cumulativeSeverity != nil
                && (!hasEmittedEvent || shouldEmitEscalation || shouldEmitSuccessor) else {
            return nil
        }
        let usesCumulativeEpisode = !hasEmittedEvent || shouldEmitEscalation
        let eventBaseline = usesCumulativeEpisode ? baseline.remainingPercent : (lastEmittedRemaining ?? baseline.remainingPercent)
        let eventDrop = usesCumulativeEpisode ? cumulativeDrop : successorDrop
        let severity = usesCumulativeEpisode ? cumulativeSeverity! : successorSeverity!
        let eventStart = usesCumulativeEpisode ? baseline.observedAt : (lastEmittedAt ?? baseline.observedAt)
        let event = ObservedRapidDrainEvent(
            id: UUID(),
            profileID: profileID,
            limitID: limitID,
            resetAt: resetAt,
            baselineRemainingPercent: eventBaseline,
            currentRemainingPercent: current,
            observedDropPercent: eventDrop,
            startAt: eventStart,
            endAt: observedAt,
            severity: severity
        )
        lastEmittedAt = observedAt
        lastEmittedRemaining = current
        if let cumulativeSeverity {
            episodePeakSeverity = max(episodePeakSeverity ?? cumulativeSeverity, cumulativeSeverity)
        }
        return event
    }

    private static func severity(for drop: Int) -> RapidDrainSeverity? {
        switch drop {
        case severeThreshold...: return .severe
        case rapidThreshold..<severeThreshold: return .rapid
        case noticeThreshold..<rapidThreshold: return .notice
        default: return nil
        }
    }
}

struct RapidDrainPresentationDecision: Equatable {
    let showMenuAlert: Bool
    let sendRapidDrainBanner: Bool
}

enum RapidDrainPresentationPolicy {
    static func decide(
        trustedCodexForeground: Bool,
        notificationsEnabled: Bool,
        notificationAuthorized: Bool
    ) -> RapidDrainPresentationDecision {
        RapidDrainPresentationDecision(
            showMenuAlert: true,
            sendRapidDrainBanner: !trustedCodexForeground && notificationsEnabled && notificationAuthorized
        )
    }
}

struct RapidDrainAnimationPlan: Equatable {
    let pulseCount: Int
    let expandedWidth: CGFloat
    let scale: CGFloat
    let showsScan: Bool
    let showsShake: Bool
    let holdDuration: TimeInterval
    let totalDuration: TimeInterval

    static func make(severity: RapidDrainSeverity, reduceMotion: Bool, drop: Int) -> RapidDrainAnimationPlan {
        _ = drop
        if reduceMotion {
            return RapidDrainAnimationPlan(
                pulseCount: 0,
                expandedWidth: 56,
                scale: 1,
                showsScan: false,
                showsShake: false,
                holdDuration: 4.5,
                totalDuration: 4.9
            )
        }
        let hold = 3.5
        return RapidDrainAnimationPlan(
            pulseCount: severity.pulseCount,
            expandedWidth: 56,
            scale: 1.10,
            showsScan: true,
            showsShake: true,
            holdDuration: hold,
            totalDuration: 0.16 + 0.24 + 0.30 + Double(severity.pulseCount) * 0.32 + hold + 0.32
        )
    }
}
