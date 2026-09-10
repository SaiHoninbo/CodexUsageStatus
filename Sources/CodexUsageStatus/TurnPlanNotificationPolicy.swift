import Foundation

/// Process-local cadence for bounded plan-progress notifications. The
/// provider plan is the only percentage authority; this policy never turns it
/// into whole-Turn completion or a time estimate.
enum TurnPlanNotificationPolicy {
    static let milestones = [25, 50, 75]

    /// Stable, local-only dedupe identity. Encoding each component prevents a
    /// path or Chat name containing `|` from colliding with another execution.
    /// The key is stored in the existing bounded Turn notification key store;
    /// it is not a new persistence subsystem.
    static func dedupeKey(
        profileID: UUID?,
        physicalRootPath: String,
        threadID: String,
        turnID: String,
        milestone: Int
    ) -> String {
        func encoded(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
        }
        return [
            "planProgress",
            profileID?.uuidString ?? "unknown",
            encoded(physicalRootPath),
            encoded(threadID),
            encoded(turnID),
            String(milestone)
        ].joined(separator: "|")
    }

    static func nextMilestone(
        previousPercentage: Int?,
        currentPercentage: Int,
        consumed: Set<Int>
    ) -> (milestone: Int, consumed: Set<Int>)? {
        let current = max(0, min(100, currentPercentage))
        let previous = previousPercentage.map { max(0, min(100, $0)) } ?? -1
        guard current > previous else { return nil }

        let crossed = milestones.filter { $0 > previous && $0 <= current }
        guard let latest = crossed.last else { return nil }
        var updated = consumed
        for milestone in crossed { updated.insert(milestone) }
        guard !consumed.contains(latest) else { return nil }
        return (latest, updated)
    }
}
