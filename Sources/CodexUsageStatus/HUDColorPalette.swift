import SwiftUI

/// Fixed-light semantic colors shared by the floating HUD and the details
/// popover.  Keeping the palette explicit avoids `.primary` changing from
/// white to black while an accessory window changes active state.
enum HUDColorPalette {
    static let primaryText = Color.black.opacity(0.82)
    static let secondaryText = Color.black.opacity(0.58)
    static let panelTint = Color.white.opacity(0.16)

    static let fiveHour = Color.orange
    static let sevenDay = Color.blue
    static let gptReserveWeekly = Color.teal
    static let submitAction = Color.blue
    static let executeAction = Color.green
    static let commit = Color.orange
    static let push = Color.blue
    static let commitPush = Color.green
    static let update = Color.orange
}
