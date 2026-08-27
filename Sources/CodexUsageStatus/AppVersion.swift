import Foundation

enum AppVersion {
    static let fallback = "dev"

    static var current: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return value
    }

    static var label: String { "v\(current)" }
}
