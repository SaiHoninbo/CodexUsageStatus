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

/// Equatable snapshot for the rendered HUD content. The root view may still
/// observe the model to coordinate AppKit events and local state, but this
/// value is the only input that can invalidate the visual content boundary.
struct HUDPresentation: Equatable {
    let profileID: UUID?
    let accountEmail: String?
    let plan: String?
    // Identity sentinels keep profile/account transitions observable even
    // when the compact display has not yet accepted the replacement label.
    let identityEmail: String?
    let identityPlan: String?
    let quota: HUDDualQuotaPresentation?
    let tokenMetrics: [TokenActivityMetric]?
    /// A network-only token update event. Cache hydration, account switches,
    /// and chart-range changes intentionally publish `nil` here so the HUD
    /// keeps its stable geometry and does not replay feedback.
    let tokenActivityFeedback: TokenActivityUpdateFeedback?
    let tokenActivityIsStale: Bool
    let updateBadge: HUDUpdateBadgeState
    let dataAgeText: String
    let connectionState: ConnectionState
    let isStale: Bool
    let isQuotaUpdating: Bool
    let isCodexFocused: Bool
    let quotaRowCount: Int
    let hasCredits: Bool
    let scaleLevel: HUDScaleLevel
    let isPasteAndSubmitInFlight: Bool
    let isPromptShortcutInFlight: Bool
    let clipboardOperationInFlight: Bool
    let decreaseAmount: Int?
    let remainingPercent: Int?
    let statusColor: StatusItemColor
    let isPasteHovered: Bool
    let isPasteAndSubmitHovered: Bool
    let isContinueHovered: Bool
    let isFixUntilDoneHovered: Bool
    let isFullVerificationHovered: Bool
    let isCommitAndPushHovered: Bool
    /// Reduce Motion is an environment input to the pulse treatment. Keep it
    /// in the value so toggling the accessibility setting invalidates the
    /// Equatable visual boundary immediately.
    let reduceMotion: Bool
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

/// The minimal value-semantic payload needed to animate the existing compact
/// Token Activity summary. It deliberately carries the final lifetime value
/// and changed secondary labels rather than raw persistence or network state.
struct TokenActivityUpdateFeedback: Equatable {
    let generation: UInt64
    let previousLifetimeTokens: Int64
    let lifetimeTokens: Int64
    let changedMetricLabels: [String]

    var lifetimeDelta: Int64 { lifetimeTokens - previousLifetimeTokens }

    func changed(_ label: String) -> Bool {
        changedMetricLabels.contains(label)
    }
}

enum TokenActivityFeedbackAnimation {
    static let normalDuration = 0.6
    static let reduceMotionDuration = 0.18

    static func duration(reduceMotion: Bool) -> Double {
        reduceMotion ? reduceMotionDuration : normalDuration
    }
}

enum TokenActivitySoundKind: Equatable {
    case tink
    case glass
    case beep
}

enum TokenActivitySoundPolicy {
    static let preferredSystemSoundName = "Tink"
    static let fallbackSystemSoundName = "Glass"

    /// Sound is a per-event decision. The view model owns the generation gate
    /// and invokes this once for each qualifying callback.
    static func shouldPlay(for feedback: TokenActivityUpdateFeedback?, enabled: Bool) -> Bool {
        enabled && feedback != nil
    }

    static func select(tinkAvailable: Bool, glassAvailable: Bool) -> TokenActivitySoundKind {
        if tinkAvailable { return .tink }
        if glassAvailable { return .glass }
        return .beep
    }
}

struct TokenActivitySoundGate: Equatable {
    private(set) var lastPlayedGeneration: UInt64?

    mutating func consume(feedback: TokenActivityUpdateFeedback?, enabled: Bool) -> Bool {
        guard TokenActivitySoundPolicy.shouldPlay(for: feedback, enabled: enabled),
              let feedback,
              lastPlayedGeneration != feedback.generation else {
            return false
        }
        lastPlayedGeneration = feedback.generation
        return true
    }
}

/// Pure trigger policy for Token Activity feedback. The raw incoming
/// snapshot is required because `TokenActivityStore.update` merges nullable
/// fields; a sparse patch must never look like a lifetime increase merely
/// because it retained an older stored value.
enum TokenActivityFeedbackPolicy {
    static func make(
        previousSource: TokenActivitySnapshot?,
        previousSummary: TokenActivitySnapshot?,
        currentSummary: TokenActivitySnapshot?,
        incoming: TokenActivitySnapshot,
        generation: UInt64,
        sameProfile: Bool = true
    ) -> TokenActivityUpdateFeedback? {
        guard sameProfile,
              let previousSource,
              let previousSummary,
              let currentSummary,
              incoming.fetchedAt > previousSource.fetchedAt,
              let oldLifetime = previousSource.lifetimeTokens,
              let incomingLifetime = incoming.lifetimeTokens,
              incomingLifetime > oldLifetime,
              let previousSummaryLifetime = previousSummary.lifetimeTokens,
              let currentSummaryLifetime = currentSummary.lifetimeTokens,
              currentSummaryLifetime > previousSummaryLifetime else {
            return nil
        }

        let oldMetrics = TokenActivityPresentation.metrics(for: previousSummary)
        let newMetrics = TokenActivityPresentation.metrics(for: currentSummary)
        let changedLabels = zip(oldMetrics, newMetrics)
            .filter { $0.0.value != $0.1.value }
            .map { $0.1.label }

        return TokenActivityUpdateFeedback(
            generation: generation,
            previousLifetimeTokens: previousSummaryLifetime,
            lifetimeTokens: currentSummaryLifetime,
            changedMetricLabels: changedLabels
        )
    }
}

struct TokenOdometerSlot: Equatable, Identifiable {
    let offset: Int
    let previousCharacter: Character?
    let currentCharacter: Character

    var id: Int { offset }
    var isChangedDigit: Bool {
        guard let previousCharacter,
              previousCharacter != currentCharacter else { return false }
        return previousCharacter.isNumber && currentCharacter.isNumber
    }
}

/// Split the formatted lifetime value into stable slots so only changed
/// digits receive a numeric transition. Separators and leading positions keep
/// their identity, which prevents the compact HUD from shifting during a
/// roll.
enum TokenOdometerPresentation {
    static func slots(previous: Int64, current: Int64) -> [TokenOdometerSlot] {
        let oldCharacters = Array(TokenActivityPresentation.tokenCount(previous))
        let newCharacters = Array(TokenActivityPresentation.tokenCount(current))
        let width = max(oldCharacters.count, newCharacters.count)
        let oldPadded = Array(repeating: Character(" "), count: width - oldCharacters.count) + oldCharacters
        let newPadded = Array(repeating: Character(" "), count: width - newCharacters.count) + newCharacters
        return newPadded.indices.map { index in
            TokenOdometerSlot(
                offset: index,
                previousCharacter: oldPadded[index],
                currentCharacter: newPadded[index]
            )
        }
    }
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

/// Scope-level account counts keep Overview useful in all-account mode without
/// duplicating the full management list that belongs in Settings.
struct AccountScopeSummary: Equatable {
    let totalAccounts: Int
    let availableOrActiveAccounts: Int
    let staleAccounts: Int
    let unidentifiedAccounts: Int

    static func make(
        profiles: [AccountProfile],
        quotaSummaries: [ProfileQuotaSummary]
    ) -> AccountScopeSummary {
        let summariesByID = Dictionary(uniqueKeysWithValues: quotaSummaries.map { ($0.profile.id, $0) })
        let stale = profiles.filter { summariesByID[$0.id]?.isStale ?? true }.count
        let available = profiles.filter { profile in
            guard let summary = summariesByID[profile.id] else { return false }
            return !summary.isStale
        }.count
        return AccountScopeSummary(
            totalAccounts: profiles.count,
            availableOrActiveAccounts: available,
            staleAccounts: stale,
            unidentifiedAccounts: profiles.filter(\.isUnidentified).count
        )
    }
}
