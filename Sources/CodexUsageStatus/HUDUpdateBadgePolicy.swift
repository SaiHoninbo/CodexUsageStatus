import Foundation

enum HUDUpdateBadgeState: Equatable {
    case version(String)
    case available(String)
    case checking
    case error(String)

    var isActionable: Bool {
        switch self {
        case .available, .error:
            return true
        case .version, .checking:
            return false
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

enum HUDUpdateBadgePolicy {
    static func state(updateState: AppUpdateState, currentVersion: String) -> HUDUpdateBadgeState {
        switch updateState {
        case .available(let release):
            return .available(release.version)
        case .downloading(let release):
            return .available(release.version)
        case .downloaded(let release, _):
            return .available(release.version)
        case .checking:
            return .checking
        case .error:
            return .error(currentVersion)
        case .idle, .upToDate:
            return .version(currentVersion)
        }
    }
}
