import Foundation

/// Stable sections shown by the details popover. Keeping the tab identity
/// outside the view makes routing and persistence-safe labels easy to test.
enum UsagePopoverTab: String, CaseIterable, Identifiable {
    case overview
    case usage
    case history
    case accountGit
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概覽"
        case .usage: return "用量"
        case .history: return "歷史"
        case .accountGit: return "帳號與 Git"
        case .settings: return "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .usage: return "chart.bar.fill"
        case .history: return "chart.xyaxis.line"
        case .accountGit: return "person.2"
        case .settings: return "gearshape"
        }
    }
}
