import CoreGraphics
import Foundation

/// Geometry and typography for the C vertical HUD.  Keeping these values in
/// one pure type makes every scale level auditable and prevents independent
/// rows/cards from accidentally acquiring different scale factors.
struct HUDMetrics: Equatable {
    let scaleLevel: HUDScaleLevel

    // The current smallest C-layout HUD is the user's 100% reference.
    // Larger/smaller levels are derived from this compact 416x196.8 base as a single
    // proportional layout, rather than treating the old 520x260 draft as
    // the standard.
    // The direct Git footer was retired in V2. Removing its vertical budget
    // keeps the panel tight instead of leaving an empty band below actions.
    static let canonicalPanelSize = CGSize(width: 416, height: 196.8)
    static let canonicalOuterPadding: CGFloat = 14.4
    static let canonicalHeaderHeight: CGFloat = 24
    static let canonicalHeaderGap: CGFloat = 8
    static let canonicalQuotaRowHeight: CGFloat = 40
    static let canonicalQuotaRowCount: Int = 2
    // Keep identity/header text visually aligned with the primary quota
    // label (for example, "5 小時") at every HUD scale.
    static let canonicalQuotaPrimaryTextScale: CGFloat = 0.46
    static let canonicalQuotaGap: CGFloat = 6.4
    static let canonicalSectionGap: CGFloat = 11.2
    static let canonicalActionHeight: CGFloat = 38.4
    // Credits is a non-progress balance row between the quota stack and
    // command controls. Its dividers and breathing room are included in this
    // token so AppKit and SwiftUI keep one shared height contract.
    static let canonicalCreditsSectionHeight: CGFloat = 56
    static let canonicalActionSpacing: CGFloat = 8
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

    /// Returns the panel geometry for the number of quota rows currently
    /// available to the active account. The canonical two-row size remains
    /// the compatibility default; accounts with one or three windows shrink or
    /// grow only by the quota column delta, so no empty placeholder row is
    /// reserved in the HUD.
    func panelSize(quotaRowCount: Int, includesCredits: Bool = false) -> CGSize {
        let count = max(1, quotaRowCount)
        let canonicalHeight = Self.canonicalPanelSize.height
        let quotaDelta = quotaColumnHeight(for: count) - quotaColumnHeight(for: Self.canonicalQuotaRowCount)
        let creditsDelta = includesCredits ? creditsSectionHeight + sectionGap : 0
        return CGSize(
            width: Self.canonicalPanelSize.width * factor,
            height: canonicalHeight * factor + quotaDelta + creditsDelta
        )
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
    var creditsSectionHeight: CGFloat { Self.canonicalCreditsSectionHeight * factor }
    var creditsRowHeight: CGFloat { max(32, creditsSectionHeight - (sectionGap * 0.85)) }
    var actionSpacing: CGFloat { Self.canonicalActionSpacing * factor }
    var cornerRadius: CGFloat { Self.canonicalCornerRadius * factor }
    var contentWidth: CGFloat {
        max(0, panelSize.width - (outerPadding * 2))
    }

    var actionCardWidth: CGFloat {
        (contentWidth - (actionSpacing * 2)) / 3
    }

    var quotaColumnHeight: CGFloat {
        quotaColumnHeight(for: Self.canonicalQuotaRowCount)
    }

    func quotaColumnHeight(for rowCount: Int) -> CGFloat {
        let count = max(1, rowCount)
        return (quotaRowHeight * CGFloat(count)) + (quotaGap * CGFloat(max(0, count - 1)))
    }

    var verticalContentHeight: CGFloat {
        verticalContentHeight(for: Self.canonicalQuotaRowCount)
    }

    func verticalContentHeight(for rowCount: Int) -> CGFloat {
        headerHeight + headerGap + quotaColumnHeight(for: rowCount) + sectionGap + actionHeight
    }
}
