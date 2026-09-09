import Foundation

enum TurnPlanStepStatus: String, Equatable {
    case pending
    case inProgress
    case completed
}

struct TurnPlanStep: Equatable {
    let text: String
    let status: TurnPlanStepStatus
}

/// The provider's plan is intentionally kept as a complete, ephemeral
/// snapshot. It contains no provider timestamp, explanation, step identity,
/// weighting, or persistence metadata.
struct TurnPlanSnapshot: Equatable {
    let profileID: UUID?
    let threadID: String
    let turnID: String
    let steps: [TurnPlanStep]
}

/// Stage-one envelope decoding keeps identity available even when a newer
/// provider status makes the plan payload unparseable. This lets the caller
/// clear a same-Turn plan without clearing an unrelated current plan.
struct TurnPlanEnvelope {
    let turnID: String
    let optionalThreadID: String?
    let rawPlan: Any?
    let hasPlanField: Bool
}

enum TurnPlanAdmissionDecision: Equatable {
    case ignore
    case clear
    case replace(TurnPlanSnapshot)
}

enum TurnPlanCodec {
    /// Decode only the stable identity envelope. Unknown top-level fields,
    /// including `items`, are deliberately ignored. `threadId` is an
    /// optional local extension and malformed values are ignored.
    static func decodeEnvelope(params: Any) -> TurnPlanEnvelope? {
        guard let object = params as? [String: Any],
              let turnID = object["turnId"] as? String,
              !turnID.isEmpty else { return nil }
        let hasPlanField = object.keys.contains("plan")
        return TurnPlanEnvelope(
            turnID: turnID,
            optionalThreadID: object["threadId"] as? String,
            rawPlan: object["plan"],
            hasPlanField: hasPlanField
        )
    }

    /// Decode the raw plan only after the caller has established identity.
    /// Any malformed entry or unknown status rejects the entire snapshot.
    static func decodeSteps(from envelope: TurnPlanEnvelope) -> [TurnPlanStep]? {
        guard envelope.hasPlanField,
              let rawEntries = envelope.rawPlan as? [Any] else { return nil }
        var steps: [TurnPlanStep] = []
        steps.reserveCapacity(rawEntries.count)
        for rawEntry in rawEntries {
            guard let entry = rawEntry as? [String: Any],
                  let text = entry["step"] as? String,
                  let rawStatus = entry["status"] as? String,
                  let status = TurnPlanStepStatus(rawValue: rawStatus) else {
                return nil
            }
            steps.append(TurnPlanStep(text: text, status: status))
        }
        return steps
    }

    static func normalizedStepText(_ rawText: String?, maxLength: Int = 96) -> String? {
        guard let rawText else { return nil }
        let normalized = rawText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard maxLength > 1, normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength - 1)) + "…"
    }
}

struct TurnPlanProgress: Equatable {
    let hasPlanAuthority: Bool
    let completedCount: Int
    let totalCount: Int
    let percentage: Int?
    let currentStepText: String?
    let hasMultipleInProgress: Bool
    let remainingStepCount: Int?

    static let unknown = TurnPlanProgress(
        hasPlanAuthority: false,
        completedCount: 0,
        totalCount: 0,
        percentage: nil,
        currentStepText: nil,
        hasMultipleInProgress: false,
        remainingStepCount: nil
    )

    var compactText: String? {
        guard hasPlanAuthority, let percentage else { return nil }
        return "目前計畫 \(completedCount) / \(totalCount) · \(percentage)%"
    }
}

enum TurnPlanProgressPolicy {
    static func make(from snapshot: TurnPlanSnapshot?) -> TurnPlanProgress {
        guard let snapshot, !snapshot.steps.isEmpty else { return .unknown }
        let completedCount = snapshot.steps.count(where: { $0.status == .completed })
        let totalCount = snapshot.steps.count
        let inProgress = snapshot.steps.filter { $0.status == .inProgress }
        let currentStepText = inProgress.count == 1 ? inProgress[0].text : nil
        return TurnPlanProgress(
            hasPlanAuthority: true,
            completedCount: completedCount,
            totalCount: totalCount,
            percentage: Int((Double(completedCount) / Double(totalCount) * 100).rounded()),
            currentStepText: currentStepText,
            hasMultipleInProgress: inProgress.count > 1,
            remainingStepCount: totalCount - completedCount
        )
    }

    static func hudText(state: TurnActivityState, progress: TurnPlanProgress) -> String? {
        guard state == .active else { return nil }
        if progress.hasPlanAuthority {
            return "Codex · \(progress.completedCount)/\(progress.totalCount)"
        }
        return "Codex 執行中"
    }
}

/// Pure admission rules for a plan snapshot. Identity is checked before the
/// payload is interpreted, so a malformed replacement can invalidate only the
/// current Turn while an event from another profile/thread/Turn is ignored.
enum TurnPlanAdmissionPolicy {
    static func matchesIdentity(
        sourceProfileID: UUID?,
        currentProfileID: UUID?,
        currentProfileIsManaged: Bool,
        activeTurnState: TurnActivityState,
        activeThreadID: String?,
        activeTurnID: String?,
        envelope: TurnPlanEnvelope
    ) -> Bool {
        guard activeTurnState == .active,
              let activeTurnID,
              activeTurnID == envelope.turnID,
              let activeThreadID,
              !activeThreadID.isEmpty else {
            return false
        }

        if let sourceProfileID {
            guard currentProfileID == sourceProfileID else { return false }
        } else if currentProfileIsManaged {
            // The default connection cannot publish into a managed profile.
            return false
        }

        if let payloadThreadID = envelope.optionalThreadID,
           payloadThreadID != activeThreadID {
            return false
        }
        return true
    }

    static func decide(
        sourceProfileID: UUID?,
        currentProfileID: UUID?,
        currentProfileIsManaged: Bool,
        activeTurnState: TurnActivityState,
        activeThreadID: String?,
        activeTurnID: String?,
        envelope: TurnPlanEnvelope,
        steps: [TurnPlanStep]?
    ) -> TurnPlanAdmissionDecision {
        guard matchesIdentity(
            sourceProfileID: sourceProfileID,
            currentProfileID: currentProfileID,
            currentProfileIsManaged: currentProfileIsManaged,
            activeTurnState: activeTurnState,
            activeThreadID: activeThreadID,
            activeTurnID: activeTurnID,
            envelope: envelope
        ) else { return .ignore }

        guard let steps else { return .clear }
        guard !steps.isEmpty else { return .clear }
        guard let activeThreadID else { return .ignore }
        return .replace(TurnPlanSnapshot(
            profileID: sourceProfileID ?? currentProfileID,
            threadID: activeThreadID,
            turnID: envelope.turnID,
            steps: steps
        ))
    }
}
