import Foundation

/// Five proportional HUD sizes centered on the standard C layout: two below,
/// standard, and two above. The standard level remains the 520x260 reference.
enum HUDScaleLevel: Int, CaseIterable, Codable, Equatable {
    case smaller2 = 1
    case smaller1 = 2
    case standard = 3
    case larger1 = 4
    case larger2 = 5

    static let userDefaultsKey = "ui.floatingHUD.scaleLevel"
    static let schemaVersionKey = "ui.floatingHUD.scaleLevel.schemaVersion"
    static let currentSchemaVersion = 3

    var scaleFactor: CGFloat {
        switch self {
        case .smaller2: return 0.80
        case .smaller1: return 0.90
        case .standard: return 1.00
        case .larger1: return 1.15
        case .larger2: return 1.30
        }
    }

    var displayName: String {
        switch self {
        case .smaller2: return "小 2 級"
        case .smaller1: return "小 1 級"
        case .standard: return "標準"
        case .larger1: return "大 1 級"
        case .larger2: return "大 2 級"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> HUDScaleLevel {
        guard let rawValue = defaults.object(forKey: userDefaultsKey) as? Int,
              let storedLevel = HUDScaleLevel(rawValue: rawValue) else {
            return .standard
        }

        let schemaVersion = defaults.integer(forKey: schemaVersionKey)
        if schemaVersion >= currentSchemaVersion {
            return storedLevel
        }

        if schemaVersion == 2 {
            // A short-lived build temporarily used level 1 as standard and
            // shifted every larger level upward. Map that representation to
            // the final centered five-level contract by preserving size.
            let migrated: HUDScaleLevel
            switch rawValue {
            case 1: migrated = .standard
            case 2: migrated = .larger1
            case 3: migrated = .larger2
            default: migrated = .standard
            }
            migrated.persist(to: defaults)
            return migrated
        }

        // v1 already used the desired raw ordering (0.80/0.90/1.00/1.15/1.30).
        // Mark it as migrated without changing the user's selected level.
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
        return storedLevel
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
    }
}
