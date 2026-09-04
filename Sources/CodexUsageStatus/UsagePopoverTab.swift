import Foundation
import Combine

/// Stable sections shown by the details popover. Keeping the tab identity
/// outside the view makes routing and persistence-safe labels easy to test.
enum UsagePopoverTab: String, CaseIterable, Identifiable {
    case overview
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概覽"
        case .history: return "歷史"
        case .settings: return "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .history: return "chart.xyaxis.line"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class PopoverSelectionController: ObservableObject {
    @Published var selectedTab: UsagePopoverTab = .overview
    @Published private(set) var requestGeneration = 0

    func select(_ tab: UsagePopoverTab) {
        selectedTab = tab
        requestGeneration &+= 1
    }
}
