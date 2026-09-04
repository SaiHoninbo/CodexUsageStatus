import Foundation

/// Semantic color classes keep status-item projections value-semantic without
/// making AppKit/SwiftUI colors part of the model's Equatable presentation.
enum StatusItemColor: Equatable {
    case secondary
    case red
    case orange
    case green
}

struct StatusItemPresentation: Equatable {
    let stackedTitle: String
    let tooltip: String
    let color: StatusItemColor

    static let placeholder = StatusItemPresentation(
        stackedTitle: "Codex\n—",
        tooltip: "Codex —",
        color: .secondary
    )
}

/// The AppDelegate subscribes to this compact projection instead of the
/// model's broad `objectWillChange` stream.  Token charts, history ranges,
/// notification preferences, and login progress intentionally have no place
/// in this value, so they cannot rebuild the status item.
struct StatusItemPresentationSource: Equatable {
    let stackedTitle: String
    let tooltip: String
    let color: StatusItemColor
}

enum StatusItemPresentationPolicy {
    static func make(from source: StatusItemPresentationSource) -> StatusItemPresentation {
        StatusItemPresentation(
            stackedTitle: source.stackedTitle,
            tooltip: source.tooltip,
            color: source.color
        )
    }
}

struct TokenActivityMetric: Equatable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Shared, pure presentation rules for the HUD and the historical popover.
/// Keeping this separate from SwiftUI makes the five-field contract directly
/// testable in the core harness and prevents the chart range from leaking into
/// account-history summary values.
enum TokenActivityPresentation {
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    static let lifetimeLabel = "累計 token"
    static let peakLabel = "歷史單日峰值"
    static let longestTurnLabel = "最長 Turn 時間"
    static let currentStreakLabel = "目前連續"
    static let longestStreakLabel = "最長連續"

    static func metrics(for snapshot: TokenActivitySnapshot?) -> [TokenActivityMetric] {
        [
            TokenActivityMetric(label: lifetimeLabel, value: tokenCount(snapshot?.lifetimeTokens)),
            TokenActivityMetric(label: peakLabel, value: tokenCount(snapshot?.peakDailyTokens)),
            TokenActivityMetric(label: longestTurnLabel, value: durationText(snapshot?.longestRunningTurnSec)),
            TokenActivityMetric(label: currentStreakLabel, value: daysText(snapshot?.currentStreakDays)),
            TokenActivityMetric(label: longestStreakLabel, value: daysText(snapshot?.longestStreakDays))
        ]
    }

    static func tokenCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return decimalFormatter.string(from: NSNumber(value: value)) ?? value.formatted()
    }

    static func daysText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return "\(value) 天"
    }

    static func durationText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value < 60 { return "\(value) 秒" }
        if value < 3600 { return "\(value / 60) 分 \(value % 60) 秒" }
        return "\(value / 3600) 小時 \((value % 3600) / 60) 分"
    }

    /// Aggregate account-history summary fields without using range-filtered
    /// chart buckets for the historical peak. `dailyBuckets` is intentionally
    /// supplied by the caller so it can remain scoped to the selected chart
    /// range while the summary fields stay range-independent.
    static func aggregate(
        snapshots: [TokenActivitySnapshot],
        dailyBuckets: [DailyTokenUsage],
        fetchedAt: Date
    ) -> TokenActivitySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let lifetimeValues = snapshots.compactMap(\.lifetimeTokens)
        return TokenActivitySnapshot(
            fetchedAt: fetchedAt,
            lifetimeTokens: lifetimeValues.isEmpty ? nil : lifetimeValues.reduce(0, +),
            peakDailyTokens: snapshots.compactMap(\.peakDailyTokens).max(),
            longestRunningTurnSec: snapshots.compactMap(\.longestRunningTurnSec).max(),
            currentStreakDays: snapshots.compactMap(\.currentStreakDays).max(),
            longestStreakDays: snapshots.compactMap(\.longestStreakDays).max(),
            dailyUsageBuckets: dailyBuckets
        )
    }
}
