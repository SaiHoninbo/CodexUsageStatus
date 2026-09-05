import SwiftUI

/// Fixed-dark semantic colors shared by the floating HUD and the details
/// popover.  The graphite values are intentionally expressed as material
/// overlays and semantic colors rather than opaque RGB cards so the panel
/// keeps a native macOS glass surface.
enum HUDColorPalette {
    // Reference targets from the canonical visual spec. Material and opacity
    // may blend these values with the active window backdrop.
    static let graphitePanel = Color(red: 0.067, green: 0.075, blue: 0.090)
    static let graphiteElevated = Color(red: 0.098, green: 0.114, blue: 0.133)
    static let graphiteControl = Color(red: 0.137, green: 0.157, blue: 0.188)

    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.66)
    static let tertiaryText = Color.white.opacity(0.46)
    // Keep the material visible; this is a tint over regularMaterial, not an
    // opaque card fill.
    static let panelTint = graphitePanel.opacity(0.34)
    static let surface = Color.white.opacity(0.075)
    static let elevatedSurface = Color.white.opacity(0.115)
    static let controlSurface = Color.white.opacity(0.15)
    static let border = Color.white.opacity(0.16)
    static let divider = Color.white.opacity(0.12)
    static let focusBorder = Color.white.opacity(0.72)
    static let disabled = Color.white.opacity(0.34)
    static let shadow = Color.black.opacity(0.36)

    static let fiveHour = Color(red: 1.0, green: 0.71, blue: 0.30)
    static let sevenDay = Color(red: 0.38, green: 0.66, blue: 1.0)
    static let gptReserveWeekly = Color(red: 0.30, green: 0.82, blue: 0.74)
    static let credits = Color(red: 0.30, green: 0.82, blue: 0.74)
    static let token = Color(red: 0.25, green: 0.84, blue: 0.76)
    static let submitAction = Color(red: 0.34, green: 0.64, blue: 1.0)
    static let continueAction = Color(red: 0.37, green: 0.82, blue: 0.55)
    static let fixAction = Color(red: 1.0, green: 0.71, blue: 0.30)
    static let verificationAction = Color(red: 0.69, green: 0.48, blue: 1.0)
    static let commitPushAction = Color(red: 0.37, green: 0.82, blue: 0.55)
    static let update = Color(red: 1.0, green: 0.71, blue: 0.30)
    static let warning = Color(red: 1.0, green: 0.71, blue: 0.30)
    static let error = Color(red: 1.0, green: 0.37, blue: 0.37)
}
