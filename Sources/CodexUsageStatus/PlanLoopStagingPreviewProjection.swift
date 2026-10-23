import Foundation

enum PlanLoopStagingPreviewProjection {
    static func usageSnapshot(from quota: CodexUsageAccountQuotaSnapshot) -> UsageSnapshot? {
        guard quota.availability == .available,
              let observedAt = quota.observedAt,
              let remainingPercent = quota.rollingQuotaPercent,
              (0...100).contains(remainingPercent),
              let label = quota.quotaWindowLabel,
              let kind = HUDQuotaWindowKind.allCases.first(where: { $0.label == label }) else {
            return nil
        }

        let window = RateLimitWindow(
            usedPercent: 100 - remainingPercent,
            resetsAt: quota.resetAt.map { Int64($0.timeIntervalSince1970) },
            windowDurationMins: kind.durationMins
        )
        let resetCredits = quota.resetCredits.map {
            RateLimitResetCredits(availableCount: max(0, $0), credits: nil)
        }
        return UsageSnapshot(
            limitId: nil,
            limitName: nil,
            planType: quota.plan,
            primary: kind == .gptReserveWeekly ? nil : window,
            secondary: nil,
            individualLimit: nil,
            rateLimitReachedType: nil,
            spendControlReached: nil,
            rateLimitResetCredits: resetCredits,
            receivedAt: observedAt,
            gptReserveWeekly: kind == .gptReserveWeekly ? window : nil
        )
    }

    static func tokenActivityMetrics(from projection: CodexUsageProjectionSnapshot) -> [TokenActivityMetric]? {
        projection.localTokenMetrics?.map { TokenActivityMetric(label: $0.label, value: $0.value) }
    }
}
