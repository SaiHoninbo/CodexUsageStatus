import AppKit
import Foundation
import Security

/// Defines the one authoritative identity check for the native Codex app.
///
/// The HUD is intentionally scoped to the native Codex desktop application.
/// Localized names and bundle paths are not identity signals: ChatGPT, a
/// browser wrapper, or an unidentifiable process must fail closed.
enum CodexApplicationPolicy {
    static let nativeBundleIdentifier = "com.openai.codex"
    // Read-only probe of the installed official Codex app showed the
    // Developer ID publisher Team ID 2DC432GLL2.  Keep the requirement
    // publisher-bound instead of trusting a spoofable bundle identifier.
    static let officialPublisherTeamIdentifier = "2DC432GLL2"

    /// Identity of a live Codex process whose publisher-bound trust check has
    /// already succeeded. The process identity fields keep the cache bounded
    /// to one running process; a new launch must pass Security.framework
    /// validation again.
    struct TrustedApplicationIdentity: Equatable {
        let processIdentifier: pid_t
        let launchDate: Date
        let bundleURL: URL

        func matches(
            processIdentifier: pid_t,
            launchDate: Date,
            bundleURL: URL
        ) -> Bool {
            self.processIdentifier == processIdentifier
                && self.launchDate == launchDate
                && self.bundleURL == bundleURL
        }
    }

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

    /// Verifies both the expected bundle identifier and the signed publisher
    /// of the running process.  A process with the right identifier but an
    /// ad-hoc, self-signed, or different Developer ID signature fails closed.
    static func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        guard isCodexApplication(bundleIdentifier: application.bundleIdentifier),
              let bundleURL = application.bundleURL else { return false }
        return isTrustedBundle(at: bundleURL)
    }

    static func isTrustedBundle(at bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }

        let requirementText = "identifier \"\(nativeBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(officialPublisherTeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess else {
            return false
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let signingInformation,
              let info = signingInformation as NSDictionary?,
              let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return teamIdentifier == officialPublisherTeamIdentifier
    }
}
