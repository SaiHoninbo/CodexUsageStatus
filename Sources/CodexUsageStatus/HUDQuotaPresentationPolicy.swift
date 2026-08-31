import Foundation

enum HUDQuotaWindowKind: Equatable, CaseIterable, Hashable {
    case fiveHour
    case sevenDay
    case gptReserveWeekly

    var durationMins: Int64 {
        switch self {
        case .fiveHour: return 300
        case .sevenDay: return 10_080
        case .gptReserveWeekly: return 10_080
        }
    }

    var label: String {
        switch self {
        case .fiveHour: return "5 小時"
        case .sevenDay: return "7 天"
        case .gptReserveWeekly: return "GPT reserve Weekly"
        }
    }
}
struct HUDQuotaWindowPresentation: Equatable {
    let kind: HUDQuotaWindowKind
    let durationMins: Int64
    let label: String
    let remainingPercent: Int
    let resetsAt: Int64?
    let resetDescription: String

    var fillFraction: Double {
        Double(remainingPercent) / 100.0
    }
}

struct HUDDualQuotaPresentation: Equatable {
    let profileID: UUID
    let fiveHour: HUDQuotaWindowPresentation?
    let sevenDay: HUDQuotaWindowPresentation?
    let gptReserveWeekly: HUDQuotaWindowPresentation?
    let credits: CreditsBalance?

    init(
        profileID: UUID,
        fiveHour: HUDQuotaWindowPresentation?,
        sevenDay: HUDQuotaWindowPresentation?,
        gptReserveWeekly: HUDQuotaWindowPresentation? = nil,
        credits: CreditsBalance? = nil
    ) {
        self.profileID = profileID
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.gptReserveWeekly = gptReserveWeekly
        self.credits = credits
    }

    var rows: [HUDQuotaWindowPresentation] {
        [fiveHour, sevenDay, gptReserveWeekly].compactMap { $0 }
    }

    var rowCount: Int { rows.count }

    var hasRecognizedWindow: Bool {
        !rows.isEmpty
    }
}

enum HUDQuotaPresentationPolicy {
    static func make(
        snapshot: UsageSnapshot?,
        profileID: UUID?,
        now: Date = Date()
    ) -> HUDDualQuotaPresentation? {
        guard let profileID else { return nil }
        let windows = [snapshot?.primary, snapshot?.secondary].compactMap { $0 }
        let fiveHour = makeWindow(.fiveHour, from: windows, now: now)
        let sevenDay = makeWindow(.sevenDay, from: windows, now: now)
        // `gpt-reserve` is a separate rate-limit bucket in
        // `rateLimitsByLimitId`, not the optional spend-control/monthly
        // credit object. Prefer the real window when present and retain the
        // spend-control mapping as a compatibility fallback for older
        // servers that exposed only `individualLimit`.
        let gptReserveWeekly = makeWindow(
            .gptReserveWeekly,
            from: [snapshot?.gptReserveWeekly].compactMap { $0 },
            now: now
        ) ?? makeSpendControl(snapshot?.individualLimit, now: now)
        guard fiveHour != nil || sevenDay != nil || gptReserveWeekly != nil else { return nil }
        return HUDDualQuotaPresentation(
            profileID: profileID,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            gptReserveWeekly: gptReserveWeekly,
            credits: snapshot?.credits
        )
    }

    static func makeWindow(
        _ kind: HUDQuotaWindowKind,
        from windows: [RateLimitWindow],
        now: Date = Date()
    ) -> HUDQuotaWindowPresentation? {
        let matches = windows.filter { $0.windowDurationMins == kind.durationMins }
        guard matches.count == 1, let window = matches.first else { return nil }
        return HUDQuotaWindowPresentation(
            kind: kind,
            durationMins: kind.durationMins,
            label: kind.label,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            resetDescription: compactResetDescription(window.resetsAt, now: now)
        )
    }

    static func makeSpendControl(
        _ spend: SpendControlLimit?,
        now: Date = Date()
    ) -> HUDQuotaWindowPresentation? {
        guard let spend else { return nil }
        return HUDQuotaWindowPresentation(
            kind: .gptReserveWeekly,
            durationMins: HUDQuotaWindowKind.gptReserveWeekly.durationMins,
            label: HUDQuotaWindowKind.gptReserveWeekly.label,
            remainingPercent: max(0, min(100, spend.remainingPercent)),
            resetsAt: spend.resetsAt,
            resetDescription: compactResetDescription(spend.resetsAt, now: now)
        )
    }

    static func compactResetDescription(_ timestamp: Int64?, now: Date = Date()) -> String {
        guard let timestamp else { return "更新中" }
        let seconds = Int(Date(timeIntervalSince1970: TimeInterval(timestamp)).timeIntervalSince(now))
        guard seconds > 0 else { return "已重置" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = max(1, (seconds % 3_600) / 60)
        if days > 0 { return "\(days)天\(hours)小時" }
        if hours > 0 { return "\(hours)小時\(minutes)分" }
        return "\(minutes)分"
    }
}
