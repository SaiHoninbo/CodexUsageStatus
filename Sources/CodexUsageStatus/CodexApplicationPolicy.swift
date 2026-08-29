import Foundation

/// Defines the one authoritative identity check for the native Codex app.
///
/// The HUD is intentionally scoped to the native Codex desktop application.
/// Localized names and bundle paths are not identity signals: ChatGPT, a
/// browser wrapper, or an unidentifiable process must fail closed.
enum CodexApplicationPolicy {
    static let nativeBundleIdentifier = "com.openai.codex"

    static func isCodexApplication(
        bundleIdentifier: String?,
        localizedName: String? = nil,
        bundlePath: String? = nil
    ) -> Bool {
        _ = localizedName
        _ = bundlePath
        return bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == nativeBundleIdentifier
    }
}
