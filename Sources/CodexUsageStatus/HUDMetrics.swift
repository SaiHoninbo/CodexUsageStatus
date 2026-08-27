import CoreGraphics
import Foundation

/// Geometry and typography for the C vertical HUD.  Keeping these values in
/// one pure type makes the five levels auditable and prevents independent
/// rows/cards from accidentally acquiring different scale factors.
struct HUDMetrics: Equatable {
    let scaleLevel: HUDScaleLevel

    // The current smallest C-layout HUD is the user's 100% reference.
    // Larger/smaller levels are derived from this 416x208 base as a single
    // proportional layout, rather than treating the old 520x260 draft as
    // the standard.
    static let canonicalPanelSize = CGSize(width: 416, height: 208)
    static let canonicalOuterPadding: CGFloat = 14.4
    static let canonicalQuotaRowHeight: CGFloat = 40
    static let canonicalQuotaGap: CGFloat = 6.4
    static let canonicalSectionGap: CGFloat = 11.2
    static let canonicalActionHeight: CGFloat = 38.4
    static let canonicalFooterHeight: CGFloat = 32
    static let canonicalActionSpacing: CGFloat = 8
    static let canonicalFooterSpacing: CGFloat = 9.6
    static let canonicalFooterCommitWidth: CGFloat = 64
    static let canonicalFooterPushWidth: CGFloat = 54.4
    static let canonicalFooterCommitPushWidth: CGFloat = 92.8
    static let canonicalFooterDividerGap: CGFloat = 3.2
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
    var quotaRowHeight: CGFloat { Self.canonicalQuotaRowHeight * factor }
    var quotaGap: CGFloat { Self.canonicalQuotaGap * factor }
    var sectionGap: CGFloat { Self.canonicalSectionGap * factor }
    var actionHeight: CGFloat { Self.canonicalActionHeight * factor }
    var footerHeight: CGFloat { Self.canonicalFooterHeight * factor }
    var actionSpacing: CGFloat { Self.canonicalActionSpacing * factor }
    var footerSpacing: CGFloat { Self.canonicalFooterSpacing * factor }
    var cornerRadius: CGFloat { Self.canonicalCornerRadius * factor }
    var footerCommitWidth: CGFloat { Self.canonicalFooterCommitWidth * factor }
    var footerPushWidth: CGFloat { Self.canonicalFooterPushWidth * factor }
    var footerCommitPushWidth: CGFloat { Self.canonicalFooterCommitPushWidth * factor }
    var footerDividerGap: CGFloat { Self.canonicalFooterDividerGap * factor }
    var footerControlsWidth: CGFloat {
        footerCommitWidth + footerPushWidth + footerCommitPushWidth
            + (3 * 1) + (6 * footerDividerGap)
    }
    var footerEmailWidth: CGFloat {
        max(72 * factor, contentWidth - footerControlsWidth - (footerSpacing * 1.4))
    }

    var contentWidth: CGFloat {
        max(0, panelSize.width - (outerPadding * 2))
    }

    var actionCardWidth: CGFloat {
        (contentWidth - (actionSpacing * 3)) / 4
    }

    var quotaColumnHeight: CGFloat {
        (quotaRowHeight * 2) + quotaGap
    }

    var verticalContentHeight: CGFloat {
        quotaColumnHeight + sectionGap + actionHeight + sectionGap + footerHeight
    }
}
