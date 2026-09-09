import Foundation
import Combine

/// Stable sections shown by the details popover. Keeping the tab identity
/// outside the view makes routing and persistence-safe labels easy to test.
enum UsagePopoverTab: String, CaseIterable, Identifiable {
    case overview
    case history
    case accounts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概覽"
        case .history: return "歷史"
        case .accounts: return "帳號"
        case .settings: return "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .history: return "chart.xyaxis.line"
        case .accounts: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

/// View-local destinations used when an actionable alert opens Settings. The
/// selection is intentionally transient; it is a routing hint, not a user
/// preference or persisted product state.
enum SettingsSection: String, Equatable {
    case notifications
    case hud
    case sync
    case update
    case metadata
}

/// The application Settings command has one product destination: the
/// Settings tab inside the existing status-item popover. Keeping this route
/// value-semantic makes command wiring testable without creating AppKit
/// windows in the core harness.
enum ProductSettingsRoute {
    static let targetTab: UsagePopoverTab = .settings

    static func destination(from currentTab: UsagePopoverTab) -> UsagePopoverTab {
        _ = currentTab
        return targetTab
    }
}

@MainActor
final class PopoverSelectionController: ObservableObject {
    @Published var selectedTab: UsagePopoverTab = .overview
    @Published private(set) var requestGeneration = 0
    @Published private(set) var pendingSettingsSection: SettingsSection?

    func select(_ tab: UsagePopoverTab) {
        selectedTab = tab
        requestGeneration &+= 1
    }

    func selectSettings(section: SettingsSection) {
        pendingSettingsSection = section
        select(.settings)
    }

    func consumePendingSettingsSection() -> SettingsSection? {
        defer { pendingSettingsSection = nil }
        return pendingSettingsSection
    }
}
