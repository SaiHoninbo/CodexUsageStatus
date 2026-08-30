import CoreGraphics
import Foundation

/// Geometry and typography for the C vertical HUD.  Keeping these values in
/// one pure type makes the five levels auditable and prevents independent
/// rows/cards from accidentally acquiring different scale factors.
struct HUDMetrics: Equatable {
    let scaleLevel: HUDScaleLevel

    // The current smallest C-layout HUD is the user's 100% reference.
    // Larger/smaller levels are derived from this 416x240 base as a single
    // proportional layout, rather than treating the old 520x260 draft as
    // the standard.
    static let canonicalPanelSize = CGSize(width: 416, height: 240)
    static let canonicalOuterPadding: CGFloat = 14.4
    static let canonicalHeaderHeight: CGFloat = 24
    static let canonicalHeaderGap: CGFloat = 8
    static let canonicalQuotaRowHeight: CGFloat = 40
    // Keep identity/header text visually aligned with the primary quota
    // label (for example, "5 小時") at every HUD scale.
    static let canonicalQuotaPrimaryTextScale: CGFloat = 0.46
    static let canonicalQuotaGap: CGFloat = 6.4
    static let canonicalSectionGap: CGFloat = 11.2
    static let canonicalActionHeight: CGFloat = 38.4
    static let canonicalFooterHeight: CGFloat = 32
    static let canonicalActionSpacing: CGFloat = 8
    static let canonicalFooterSpacing: CGFloat = 9.6
    static let canonicalFooterHorizontalPaddingMultiplier: CGFloat = 0.65
    static let canonicalFooterButtonSpacing: CGFloat = 4
    static let canonicalCornerRadius: CGFloat = 19.2

    init(scaleLevel: HUDScaleLevel = .standard) {
        self.scaleLevel = scaleLevel
    }

    var factor: CGFloat { scaleLevel.scaleFactor }
    var panelSize: CGSize {
        // Keep the AppKit frame and all internal tokens on the same exact
        // proportion. AppKit handles device-pixel alignment; rounding only
        // the outer frame would make fractional levels clip at the bottom.
        CGSize(width: Self.canonicalPanelSize.width * factor,
               height: Self.canonicalPanelSize.height * factor)
    }
    var outerPadding: CGFloat { Self.canonicalOuterPadding * factor }
    var headerHeight: CGFloat { Self.canonicalHeaderHeight * factor }
    var headerGap: CGFloat { Self.canonicalHeaderGap * factor }
    var quotaRowHeight: CGFloat { Self.canonicalQuotaRowHeight * factor }
    var quotaPrimaryTextSize: CGFloat {
        quotaRowHeight * Self.canonicalQuotaPrimaryTextScale
    }
    var quotaGap: CGFloat { Self.canonicalQuotaGap * factor }
    var sectionGap: CGFloat { Self.canonicalSectionGap * factor }
    var actionHeight: CGFloat { Self.canonicalActionHeight * factor }
    var footerHeight: CGFloat { Self.canonicalFooterHeight * factor }
    var actionSpacing: CGFloat { Self.canonicalActionSpacing * factor }
    var footerSpacing: CGFloat { Self.canonicalFooterSpacing * factor }
    var footerHorizontalPadding: CGFloat {
        footerSpacing * Self.canonicalFooterHorizontalPaddingMultiplier
    }
    var footerButtonSpacing: CGFloat { Self.canonicalFooterButtonSpacing * factor }
    var cornerRadius: CGFloat { Self.canonicalCornerRadius * factor }
    var footerButtonWidth: CGFloat {
        max(0, (contentWidth - (footerHorizontalPadding * 2) - (footerButtonSpacing * 2)) / 3)
    }
    var footerControlsWidth: CGFloat {
        footerButtonWidth * 3 + (footerButtonSpacing * 2)
    }
    var contentWidth: CGFloat {
        max(0, panelSize.width - (outerPadding * 2))
    }

    var actionCardWidth: CGFloat {
        (contentWidth - (actionSpacing * 2)) / 3
    }

    var quotaColumnHeight: CGFloat {
        (quotaRowHeight * 2) + quotaGap
    }

    var verticalContentHeight: CGFloat {
        headerHeight + headerGap + quotaColumnHeight + sectionGap + actionHeight + sectionGap + footerHeight
    }
}
