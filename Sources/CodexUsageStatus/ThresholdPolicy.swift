import Foundation

enum UsageThresholdPolicy {
    static func pendingThresholds(
        remainingPercent: Int,
        thresholds: [Int],
        sentThresholds: Set<Int>
    ) -> [Int] {
        thresholds
            .map { max(1, min(99, $0)) }
            .sorted()
            .filter { remainingPercent <= $0 && !sentThresholds.contains($0) }
    }
}

enum HUDWarningLevel: Equatable {
    case neutral
    case normal
    case warning
    case critical
}

struct HUDFramePulseProfile: Equatable {
    /// The period of one outer-frame breathing cycle, in seconds.
    let period: TimeInterval
    /// The low and high opacity of the color-matched frame glow.
    let minOpacity: Double
    let maxOpacity: Double
    /// The blur radius of the color-matched frame glow.
    let glowRadius: Double
}

enum HUDWarningPolicy {
    static func level(
        remainingPercent: Int?,
        connectionState: ConnectionState,
        isStale: Bool
    ) -> HUDWarningLevel {
        guard connectionState == .connected, !isStale, let remainingPercent else {
            return .neutral
        }
        if remainingPercent < 20 { return .critical }
        if remainingPercent < 50 { return .warning }
        return .normal
    }

    static func shouldPulse(
        remainingPercent: Int?,
        connectionState: ConnectionState,
        isStale: Bool
    ) -> Bool {
        framePulseProfile(
            remainingPercent: remainingPercent,
            connectionState: connectionState,
            isStale: isStale
        ) != nil
    }

    /// Returns the outer-frame breathing intensity for a live primary quota.
    /// Every valid connected value pulses, including 100%, so the HUD has a
    /// subtle "alive" signal. Lower remaining quota values get a faster,
    /// brighter frame glow without animating the panel contents.
    static func framePulseProfile(
        remainingPercent: Int?,
        connectionState: ConnectionState,
        isStale: Bool
    ) -> HUDFramePulseProfile? {
        guard connectionState == .connected, !isStale, let remainingPercent else {
            return nil
        }

        let remaining = max(0, min(100, remainingPercent))
        switch remaining {
        case 50...100:
            return HUDFramePulseProfile(
                period: 2.3,
                minOpacity: 0.28,
                maxOpacity: 0.74,
                glowRadius: 5.0
            )
        case 20...49:
            return HUDFramePulseProfile(
                period: 1.8,
                minOpacity: 0.38,
                maxOpacity: 0.92,
                glowRadius: 8.0
            )
        case 10...19:
            return HUDFramePulseProfile(
                period: 1.45,
                minOpacity: 0.48,
                maxOpacity: 1.0,
                glowRadius: 11.0
            )
        default:
            return HUDFramePulseProfile(
                period: 1.1,
                minOpacity: 0.58,
                maxOpacity: 1.0,
                glowRadius: 14.0
            )
        }
    }

    static func decreaseAmount(
        previous: Int?,
        current: Int?,
        connectionState: ConnectionState,
        isStale: Bool,
        sameProfile: Bool
    ) -> Int? {
        guard sameProfile,
              connectionState == .connected,
              !isStale,
              let previous,
              let current,
              current < previous else { return nil }
        return previous - current
    }
}
