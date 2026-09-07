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
    /// A local-observation token update event. Account lifetime refreshes,
    /// cache hydration, account switches, and chart-range changes publish
    /// `nil` so the HUD cannot replay feedback for non-local consumption.
    let tokenActivityFeedback: TokenHeroUpdateFeedback?
    let tokenActivityIsStale: Bool
    let updateBadge: HUDUpdateBadgeState
    let dataAgeText: String
    let connectionState: ConnectionState
    let isStale: Bool
    let isQuotaUpdating: Bool
    let isCodexFocused: Bool
    let quotaRowCount: Int
    /// The single account-information-row visibility decision shared by the
    /// SwiftUI tree and the AppKit panel geometry. A known zero Reset Credit
    /// count is still information and therefore keeps this row visible.
    let showsAccountInfoRow: Bool
    let resetCreditCount: Int?
    let resetCreditNextExpiryAt: Int64?
    let resetCreditCountdownText: String?
    let scaleLevel: HUDScaleLevel
    let isPasteInFlight: Bool
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

/// Credits and Reset Credits are independently optional. This policy is the
/// only place that decides whether their shared HUD row exists; downstream
/// layout code consumes the resulting boolean without reinterpreting data.
enum HUDAccountInfoVisibilityPolicy {
    static func showsRow(credits: CreditsBalance?, resetCreditCount: Int?) -> Bool {
        credits?.isDisplayable == true || resetCreditCount != nil
    }
}

struct HUDResetCreditPresentation: Equatable {
    let count: Int
    let nextExpiryAt: Int64?

    static func make(from resetCredits: RateLimitResetCredits?, now: Date) -> HUDResetCreditPresentation? {
        guard let resetCredits else { return nil }
        return HUDResetCreditPresentation(
            count: resetCredits.availableCount,
            nextExpiryAt: HUDResetCreditCountdownPolicy.nearestFutureExpiry(
                in: resetCredits.availableCredits,
                now: now
            )
        )
    }
}

/// Pure shared countdown semantics for the HUD and Popover. This policy does
/// no scheduling and causes no transport work; callers reuse the model's
/// existing minute-level `currentDate` publication.
enum HUDResetCreditCountdownPolicy {
    static func nearestFutureExpiry(
        in credits: [RateLimitResetCredit],
        now: Date
    ) -> Int64? {
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        return credits
            .filter(\.isAvailable)
            .compactMap(\.expiresAt)
            .filter { $0 > nowTimestamp }
            .min()
    }

    static func text(expiresAt: Int64?, now: Date) -> String {
        guard let expiresAt else { return "到期未知" }
        let remainingSeconds = TimeInterval(expiresAt) - now.timeIntervalSince1970
        guard remainingSeconds > 0 else { return "已過期" }
        guard remainingSeconds >= 3_600 else { return "剩不到 1 小時" }

        let totalHours = Int(remainingSeconds / 3_600)
        let days = totalHours / 24
        let hours = totalHours % 24
        return "剩 \(days) 天 \(hours) 小時"
    }
}

enum HUDPasteActionPolicy {
    static func canStart(isInFlight: Bool, isCodexFocused: Bool) -> Bool {
        !isInFlight && isCodexFocused
    }
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

/// The minimal value-semantic payload needed to animate the Token Hero. Its
/// values represent the machine-scoped local observation ledger rather than
/// the account lifetime returned by Token Activity.
struct TokenHeroUpdateFeedback: Equatable {
    let generation: UInt64
    let previousTokens: Int64
    let tokens: Int64
    let changedMetricLabels: [String]

    var tokenDelta: Int64 { tokens - previousTokens }

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
    static func shouldPlay(for feedback: TokenHeroUpdateFeedback?, enabled: Bool) -> Bool {
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

    mutating func consume(feedback: TokenHeroUpdateFeedback?, enabled: Bool) -> Bool {
        guard TokenActivitySoundPolicy.shouldPlay(for: feedback, enabled: enabled),
              let feedback,
              lastPlayedGeneration != feedback.generation else {
            return false
        }
        lastPlayedGeneration = feedback.generation
        return true
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

/// A deterministic, value-semantic plan for one changed numeric slot. The
/// plan deliberately lives beside the existing slot model so the reel motion
/// remains testable without SwiftUI or any runtime/network state.
struct TokenOdometerReelPlan: Equatable {
    static let staggerStep = 0.02
    static let maxStaggerDelay = 0.08

    let startDigit: Int
    let finalDigit: Int
    let forwardSequence: [Int]
    let stepCount: Int
    let startDelay: Double

    var finalLandingIndex: Int { stepCount }

    /// Builds one complete forward revolution plus the shortest forward path
    /// to the new digit. Returning nil is intentional for unchanged digits,
    /// separators, and newly appearing leading digits without a numeric
    /// predecessor.
    static func make(
        previousCharacter: Character?,
        currentCharacter: Character,
        startDelay: Double = 0
    ) -> TokenOdometerReelPlan? {
        guard let previousDigit = previousCharacter?.wholeNumberValue,
              let finalDigit = currentCharacter.wholeNumberValue,
              (0...9).contains(previousDigit),
              (0...9).contains(finalDigit),
              previousDigit != finalDigit else {
            return nil
        }

        let forwardDelta = (finalDigit - previousDigit + 10) % 10
        let stepCount = 10 + forwardDelta
        let sequence = (0...stepCount).map { step in
            (previousDigit + step) % 10
        }

        return TokenOdometerReelPlan(
            startDigit: previousDigit,
            finalDigit: finalDigit,
            forwardSequence: sequence,
            stepCount: stepCount,
            startDelay: min(max(0, startDelay), maxStaggerDelay)
        )
    }

    /// Rightmost changed digits start first. The delay is intentionally small
    /// and bounded so the whole feedback remains a compact utility animation.
    static func startDelay(forChangedRankFromRight rank: Int) -> Double {
        min(Double(max(0, rank)) * staggerStep, maxStaggerDelay)
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

/// Truthful presentation states for the compact All Accounts overview.
/// `currentLive` is reserved for the selected profile's connected in-memory
/// snapshot; cached samples from every other profile are never promoted to
/// Live, even when their timestamp is recent.
enum AllAccountsUsageRowState: String, Equatable {
    case currentLive
    case cached
    case stale
    case unavailable

    var displayName: String {
        switch self {
        case .currentLive: return "Live"
        case .cached: return "快取"
        case .stale: return "資料較舊"
        case .unavailable: return "尚無資料"
        }
    }
}

/// Non-persistent, value-semantic projection for one All Accounts row.
/// Account identity remains supplied by `AccountProfileDisplay`, while quota
/// and freshness come from the profile-scoped history sample.
struct AllAccountsUsageRowPresentation: Identifiable, Equatable {
    let profileID: UUID
    let title: String
    let subtitle: String
    let remainingPercent: Int?
    let freshnessText: String
    let state: AllAccountsUsageRowState
    let isCurrent: Bool
    let isWarning: Bool

    var id: UUID { profileID }

    static func orderedProfiles(_ profiles: [AccountProfile], currentProfileID: UUID?) -> [AccountProfile] {
        guard let currentProfileID,
              let current = profiles.first(where: { $0.id == currentProfileID }) else {
            return profiles
        }
        return [current] + profiles.filter { $0.id != currentProfileID }
    }

    static func make(
        profile: AccountProfile,
        display: AccountProfileDisplay,
        summary: ProfileQuotaSummary?,
        currentProfileID: UUID?,
        currentConnectionState: ConnectionState,
        currentSnapshotAvailable: Bool,
        currentSnapshotIsStale: Bool,
        currentRemainingPercent: Int?,
        now: Date
    ) -> Self {
        let isCurrent = profile.id == currentProfileID
        let isCurrentLive = isCurrent
            && currentConnectionState == .connected
            && currentSnapshotAvailable
            && !currentSnapshotIsStale
        let state: AllAccountsUsageRowState
        if isCurrentLive {
            state = .currentLive
        } else if summary?.latestSample != nil {
            state = summary?.isStale(at: now) == true ? .stale : .cached
        } else {
            state = .unavailable
        }

        let percent = isCurrentLive
            ? (currentRemainingPercent ?? summary?.primaryRemainingPercent)
            : summary?.primaryRemainingPercent
        let freshnessText: String
        if state == .unavailable {
            freshnessText = state.displayName
        } else {
            freshnessText = "\(state.displayName) · \(ageText(since: summary?.latestSample?.receivedAt, now: now))"
        }

        return Self(
            profileID: profile.id,
            title: display.title,
            subtitle: display.subtitle,
            remainingPercent: clamp(percent),
            freshnessText: freshnessText,
            state: state,
            isCurrent: isCurrent,
            isWarning: display.isWarning
        )
    }

    private static func clamp(_ value: Int?) -> Int? {
        value.map { max(0, min(100, $0)) }
    }

    private static func ageText(since date: Date?, now: Date) -> String {
        guard let date else { return "尚無資料" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "剛剛" }
        if seconds < 3600 { return "\(max(1, seconds / 60)) 分鐘前" }
        if seconds < 86400 { return "\(max(1, seconds / 3600)) 小時前" }
        return "\(max(1, seconds / 86400)) 天前"
    }
}
