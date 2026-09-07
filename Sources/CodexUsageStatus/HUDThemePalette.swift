import Foundation
import SwiftUI

/// HUD-only visual themes.  The popover intentionally keeps its canonical
/// graphite palette; these values are injected only into the floating HUD.
enum HUDTheme: String, CaseIterable, Codable, Equatable, Identifiable {
    case neonPurple
    case lightSky
    case mario

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neonPurple: return "霓虹紫光"
        case .lightSky: return "亮色天空"
        case .mario: return "瑪利歐風"
        }
    }

    var next: HUDTheme {
        switch self {
        case .neonPurple: return .lightSky
        case .lightSky: return .mario
        case .mario: return .neonPurple
        }
    }
}

enum HUDThemeRotationInterval: Int, CaseIterable, Codable, Equatable, Identifiable {
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case threeHours = 10_800
    case sixHours = 21_600
    case twelveHours = 43_200
    case oneDay = 86_400

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .thirtyMinutes: return "每 30 分鐘"
        case .oneHour: return "每 60 分鐘"
        case .threeHours: return "每 3 小時"
        case .sixHours: return "每 6 小時"
        case .twelveHours: return "每 12 小時"
        case .oneDay: return "每 24 小時"
        }
    }
}

/// The AppKit/SwiftUI appearance contract for the floating HUD.  This is
/// intentionally HUD-only; the product popover keeps its own appearance.
enum HUDThemeAppearance: String, Equatable {
    case dark
    case light

    var colorScheme: ColorScheme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// Component-level semantic tokens for the floating HUD. Keeping surfaces,
/// appearance, and action emphasis here lets one theme change repaint the HUD
/// without touching the model, ledger, Token Reel, or popover surface.
struct HUDThemePalette: Equatable {
    let appearance: HUDThemeAppearance
    let panelSurface: Color
    let panelTint: Color
    let panelBorder: Color
    let surface: Color
    let elevatedSurface: Color
    let controlSurface: Color
    let graphiteControl: Color
    let tokenHeroSurface: Color
    let tokenHeroBorder: Color
    let fiveHourSurface: Color
    let sevenDaySurface: Color
    let gptReserveSurface: Color
    let accountInfoSurface: Color
    let neutralActionSurface: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let border: Color
    let divider: Color
    let focusBorder: Color
    let disabled: Color
    let shadow: Color
    let fiveHour: Color
    let sevenDay: Color
    let gptReserveWeekly: Color
    let credits: Color
    let token: Color
    let submitAction: Color
    let continueAction: Color
    let fixAction: Color
    let verificationAction: Color
    let commitPushAction: Color
    let filledActionForeground: Color
    let commitPushForeground: Color
    let filledActionOpacity: Double
    let filledActionHoverOpacity: Double
    let filledActionPressedOpacity: Double
    let update: Color
    let warning: Color
    let error: Color

    static let neonPurple = HUDThemePalette(
        appearance: .dark,
        panelSurface: Color(red: 0.067, green: 0.075, blue: 0.090).opacity(0.82),
        panelTint: Color(red: 0.067, green: 0.075, blue: 0.090).opacity(0.16),
        panelBorder: Color(red: 0.68, green: 0.38, blue: 1.0).opacity(0.62),
        surface: Color.white.opacity(0.075),
        elevatedSurface: Color(red: 0.098, green: 0.114, blue: 0.133).opacity(0.92),
        controlSurface: Color(red: 0.137, green: 0.157, blue: 0.188).opacity(0.92),
        graphiteControl: Color(red: 0.137, green: 0.157, blue: 0.188),
        tokenHeroSurface: Color(red: 0.098, green: 0.114, blue: 0.133).opacity(0.96),
        tokenHeroBorder: Color(red: 0.68, green: 0.38, blue: 1.0).opacity(0.72),
        fiveHourSurface: Color(red: 0.20, green: 0.11, blue: 0.10).opacity(0.82),
        sevenDaySurface: Color(red: 0.08, green: 0.13, blue: 0.25).opacity(0.82),
        gptReserveSurface: Color(red: 0.07, green: 0.20, blue: 0.19).opacity(0.82),
        accountInfoSurface: Color(red: 0.13, green: 0.11, blue: 0.20).opacity(0.86),
        neutralActionSurface: Color(red: 0.137, green: 0.157, blue: 0.188).opacity(0.94),
        primaryText: Color.white.opacity(0.96),
        secondaryText: Color.white.opacity(0.72),
        tertiaryText: Color.white.opacity(0.48),
        border: Color(red: 0.68, green: 0.38, blue: 1.0).opacity(0.52),
        divider: Color.white.opacity(0.16),
        focusBorder: Color(red: 0.75, green: 0.58, blue: 1.0),
        disabled: Color.white.opacity(0.32),
        shadow: Color.black.opacity(0.48),
        fiveHour: Color(red: 1.0, green: 0.43, blue: 0.20),
        sevenDay: Color(red: 0.24, green: 0.53, blue: 1.0),
        gptReserveWeekly: Color(red: 0.30, green: 0.82, blue: 0.74),
        credits: Color(red: 0.64, green: 0.43, blue: 1.0),
        token: Color(red: 0.72, green: 0.43, blue: 1.0),
        submitAction: Color(red: 0.17, green: 0.31, blue: 0.92),
        continueAction: Color(red: 0.40, green: 0.17, blue: 0.82),
        fixAction: Color(red: 0.82, green: 0.25, blue: 0.10),
        verificationAction: Color(red: 0.48, green: 0.18, blue: 0.94),
        commitPushAction: Color(red: 0.28, green: 0.16, blue: 0.72),
        filledActionForeground: .white,
        commitPushForeground: .white,
        filledActionOpacity: 0.36,
        filledActionHoverOpacity: 0.52,
        filledActionPressedOpacity: 0.64,
        update: Color(red: 1.0, green: 0.43, blue: 0.20),
        warning: Color(red: 1.0, green: 0.43, blue: 0.20),
        error: Color(red: 1.0, green: 0.27, blue: 0.36)
    )

    static let lightSky = HUDThemePalette(
        appearance: .light,
        panelSurface: Color.white.opacity(0.84),
        panelTint: Color(red: 0.82, green: 0.93, blue: 1.0).opacity(0.10),
        panelBorder: Color(red: 0.35, green: 0.65, blue: 0.95).opacity(0.58),
        surface: Color.white.opacity(0.54),
        elevatedSurface: Color.white.opacity(0.76),
        controlSurface: Color(red: 0.84, green: 0.93, blue: 1.0).opacity(0.80),
        graphiteControl: Color(red: 0.88, green: 0.95, blue: 1.0),
        tokenHeroSurface: Color.white.opacity(0.82),
        tokenHeroBorder: Color(red: 0.10, green: 0.48, blue: 0.90).opacity(0.55),
        fiveHourSurface: Color(red: 1.0, green: 0.93, blue: 0.86).opacity(0.88),
        sevenDaySurface: Color(red: 0.86, green: 0.94, blue: 1.0).opacity(0.90),
        gptReserveSurface: Color(red: 0.86, green: 0.98, blue: 0.94).opacity(0.90),
        accountInfoSurface: Color.white.opacity(0.88),
        neutralActionSurface: Color.white.opacity(0.88),
        primaryText: Color(red: 0.04, green: 0.10, blue: 0.23),
        secondaryText: Color(red: 0.12, green: 0.25, blue: 0.43).opacity(0.86),
        tertiaryText: Color(red: 0.19, green: 0.32, blue: 0.48).opacity(0.68),
        border: Color(red: 0.35, green: 0.65, blue: 0.95).opacity(0.48),
        divider: Color(red: 0.30, green: 0.50, blue: 0.70).opacity(0.20),
        focusBorder: Color(red: 0.12, green: 0.42, blue: 0.86),
        disabled: Color(red: 0.20, green: 0.32, blue: 0.46).opacity(0.38),
        shadow: Color(red: 0.08, green: 0.24, blue: 0.42).opacity(0.20),
        fiveHour: Color(red: 0.92, green: 0.30, blue: 0.12),
        sevenDay: Color(red: 0.08, green: 0.40, blue: 0.90),
        gptReserveWeekly: Color(red: 0.04, green: 0.62, blue: 0.54),
        credits: Color(red: 0.02, green: 0.55, blue: 0.42),
        token: Color(red: 0.03, green: 0.48, blue: 0.86),
        submitAction: Color(red: 0.12, green: 0.52, blue: 0.94),
        continueAction: Color(red: 0.10, green: 0.70, blue: 0.48),
        fixAction: Color(red: 1.0, green: 0.47, blue: 0.14),
        verificationAction: Color(red: 0.48, green: 0.30, blue: 0.92),
        commitPushAction: Color(red: 0.04, green: 0.63, blue: 0.72),
        filledActionForeground: .white,
        commitPushForeground: .white,
        filledActionOpacity: 0.76,
        filledActionHoverOpacity: 0.88,
        filledActionPressedOpacity: 0.96,
        update: Color(red: 0.95, green: 0.40, blue: 0.13),
        warning: Color(red: 0.95, green: 0.40, blue: 0.13),
        error: Color(red: 0.84, green: 0.12, blue: 0.18)
    )

    static let mario = HUDThemePalette(
        appearance: .light,
        panelSurface: Color(red: 1.0, green: 0.97, blue: 0.88).opacity(0.90),
        panelTint: Color(red: 0.98, green: 0.83, blue: 0.48).opacity(0.08),
        panelBorder: Color(red: 0.88, green: 0.18, blue: 0.06).opacity(0.62),
        surface: Color.white.opacity(0.68),
        elevatedSurface: Color(red: 1.0, green: 0.95, blue: 0.78).opacity(0.86),
        controlSurface: Color(red: 1.0, green: 0.82, blue: 0.20).opacity(0.82),
        graphiteControl: Color(red: 1.0, green: 0.92, blue: 0.70),
        tokenHeroSurface: Color(red: 0.98, green: 0.18, blue: 0.08).opacity(0.94),
        tokenHeroBorder: Color(red: 1.0, green: 0.72, blue: 0.02).opacity(0.88),
        fiveHourSurface: Color(red: 1.0, green: 0.90, blue: 0.84).opacity(0.92),
        sevenDaySurface: Color(red: 0.87, green: 0.94, blue: 1.0).opacity(0.92),
        gptReserveSurface: Color(red: 0.88, green: 1.0, blue: 0.90).opacity(0.92),
        accountInfoSurface: Color(red: 1.0, green: 0.96, blue: 0.79).opacity(0.94),
        neutralActionSurface: Color.white.opacity(0.90),
        primaryText: Color(red: 0.13, green: 0.07, blue: 0.05),
        secondaryText: Color(red: 0.25, green: 0.12, blue: 0.08).opacity(0.82),
        tertiaryText: Color(red: 0.33, green: 0.18, blue: 0.10).opacity(0.64),
        border: Color(red: 0.92, green: 0.18, blue: 0.08).opacity(0.55),
        divider: Color(red: 0.50, green: 0.18, blue: 0.08).opacity(0.20),
        focusBorder: Color(red: 0.05, green: 0.32, blue: 0.85),
        disabled: Color(red: 0.35, green: 0.18, blue: 0.08).opacity(0.35),
        shadow: Color(red: 0.40, green: 0.08, blue: 0.02).opacity(0.25),
        fiveHour: Color(red: 0.90, green: 0.14, blue: 0.06),
        sevenDay: Color(red: 0.04, green: 0.35, blue: 0.92),
        gptReserveWeekly: Color(red: 0.04, green: 0.62, blue: 0.23),
        credits: Color(red: 0.02, green: 0.54, blue: 0.22),
        token: Color(red: 0.96, green: 0.48, blue: 0.02),
        submitAction: Color(red: 0.03, green: 0.40, blue: 0.95),
        continueAction: Color(red: 0.02, green: 0.65, blue: 0.20),
        fixAction: Color(red: 0.94, green: 0.12, blue: 0.08),
        verificationAction: Color(red: 0.44, green: 0.18, blue: 0.90),
        commitPushAction: Color(red: 1.0, green: 0.72, blue: 0.02),
        filledActionForeground: .white,
        commitPushForeground: Color(red: 0.12, green: 0.08, blue: 0.02),
        filledActionOpacity: 0.90,
        filledActionHoverOpacity: 1.0,
        filledActionPressedOpacity: 1.0,
        update: Color(red: 0.96, green: 0.48, blue: 0.02),
        warning: Color(red: 0.96, green: 0.48, blue: 0.02),
        error: Color(red: 0.92, green: 0.08, blue: 0.05)
    )

    static func forTheme(_ theme: HUDTheme) -> HUDThemePalette {
        switch theme {
        case .neonPurple: return .neonPurple
        case .lightSky: return .lightSky
        case .mario: return .mario
        }
    }

    var statusColor: (StatusItemColor) -> Color {
        { color in
            switch color {
            case .secondary: return secondaryText
            case .red: return error
            case .orange: return warning
            case .green: return continueAction
            }
        }
    }
}

private struct HUDThemePaletteKey: EnvironmentKey {
    static let defaultValue = HUDThemePalette.forTheme(.neonPurple)
}

extension EnvironmentValues {
    var hudThemePalette: HUDThemePalette {
        get { self[HUDThemePaletteKey.self] }
        set { self[HUDThemePaletteKey.self] = newValue }
    }
}

enum HUDThemePreference {
    static let themeKey = "ui.floatingHUD.theme"
    static let rotationEnabledKey = "ui.floatingHUD.themeRotationEnabled"
    static let intervalKey = "ui.floatingHUD.themeRotationIntervalSeconds"
    static let lastRotationKey = "ui.floatingHUD.lastThemeRotationAt"

    static func loadTheme(from defaults: UserDefaults = .standard) -> HUDTheme {
        guard let raw = defaults.string(forKey: themeKey), let theme = HUDTheme(rawValue: raw) else {
            return .neonPurple
        }
        return theme
    }

    static func loadInterval(from defaults: UserDefaults = .standard) -> HUDThemeRotationInterval {
        HUDThemeRotationInterval(rawValue: defaults.integer(forKey: intervalKey)) ?? .oneHour
    }
}

enum HUDThemeRotationPolicy {
    static func shouldRotate(now: Date, lastRotationAt: Date?, interval: HUDThemeRotationInterval) -> Bool {
        guard let lastRotationAt else { return false }
        return now.timeIntervalSince(lastRotationAt) >= Double(interval.rawValue)
    }

    static func advance(_ theme: HUDTheme, steps: Int = 1) -> HUDTheme {
        guard steps > 0 else { return theme }
        var result = theme
        for _ in 0..<steps {
            result = result.next
        }
        return result
    }
}
