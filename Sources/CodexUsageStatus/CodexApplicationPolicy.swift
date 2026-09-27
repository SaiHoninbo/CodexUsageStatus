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
    struct TrustedApplicationIdentity: Equatable, Sendable {
        let processIdentifier: pid_t
        let launchDate: Date
        let bundleURL: URL

        init(processIdentifier: pid_t, launchDate: Date, bundleURL: URL) {
            self.processIdentifier = processIdentifier
            self.launchDate = launchDate
            self.bundleURL = bundleURL.standardizedFileURL
        }

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

    /// Shares publisher validation between HUD visibility and workflow actions.
    /// The expensive Security.framework result is resolved once per exact live
    /// process identity; changing PID, launch date, or bundle URL requires a
    /// fresh check. Rejected results are cached too, so a spoofed process cannot
    /// force repeated synchronous signature work on every button press.
    final class ProcessBoundTrustCache: @unchecked Sendable {
        private let condition = NSCondition()
        private var resolvedIdentity: TrustedApplicationIdentity?
        private var resolvedTrust: Bool?
        private var validatingIdentity: TrustedApplicationIdentity?

        func cachedResult(for identity: TrustedApplicationIdentity) -> Bool? {
            condition.lock()
            defer { condition.unlock() }
            guard resolvedIdentity == identity else { return nil }
            return resolvedTrust
        }

        func resolve(
            _ identity: TrustedApplicationIdentity,
            validate: () -> Bool
        ) -> Bool {
            while true {
                condition.lock()
                if resolvedIdentity == identity, let resolvedTrust {
                    condition.unlock()
                    return resolvedTrust
                }

                if validatingIdentity != nil {
                    condition.wait()
                    condition.unlock()
                    continue
                }

                // A newly observed process identity retires the previous
                // process result before doing any publisher verification.
                resolvedIdentity = nil
                resolvedTrust = nil
                validatingIdentity = identity
                condition.unlock()

                let trusted = validate()

                condition.lock()
                if validatingIdentity == identity {
                    resolvedIdentity = identity
                    resolvedTrust = trusted
                    validatingIdentity = nil
                }
                condition.broadcast()
                condition.unlock()
                return trusted
            }
        }

        func invalidate(_ identity: TrustedApplicationIdentity) {
            condition.lock()
            defer { condition.unlock() }
            guard resolvedIdentity == identity else { return }
            resolvedIdentity = nil
            resolvedTrust = nil
        }
    }

    private static let processTrustCache = ProcessBoundTrustCache()

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
              !application.isTerminated,
              let launchDate = application.launchDate,
              let bundleURL = application.bundleURL else { return false }
        let identity = TrustedApplicationIdentity(
            processIdentifier: application.processIdentifier,
            launchDate: launchDate,
            bundleURL: bundleURL
        )
        guard isCurrentLiveCodexProcess(identity) else { return false }
        let trusted = processTrustCache.resolve(identity) {
            guard isCurrentLiveCodexProcess(identity),
                  isTrustedBundle(at: identity.bundleURL) else { return false }
            return isCurrentLiveCodexProcess(identity)
        }
        guard isCurrentLiveCodexProcess(identity) else {
            processTrustCache.invalidate(identity)
            return false
        }
        return trusted
    }

    /// HUD validation calls this from its existing utility task. It populates
    /// the same identity-bound cache used by synchronous AX workflow checks.
    static func isTrustedApplication(identity: TrustedApplicationIdentity) -> Bool {
        guard isCurrentLiveCodexProcess(identity) else { return false }
        let trusted = processTrustCache.resolve(identity) {
            guard isCurrentLiveCodexProcess(identity),
                  isTrustedBundle(at: identity.bundleURL) else { return false }
            return isCurrentLiveCodexProcess(identity)
        }
        guard isCurrentLiveCodexProcess(identity) else {
            processTrustCache.invalidate(identity)
            return false
        }
        return trusted
    }

    /// Returns only an already-resolved result; this never starts Security
    /// framework work and is used by the HUD's activation fast path.
    static func cachedTrustResult(for identity: TrustedApplicationIdentity) -> Bool? {
        guard isCurrentLiveCodexProcess(identity) else { return nil }
        return processTrustCache.cachedResult(for: identity)
    }

    static func invalidateTrust(for identity: TrustedApplicationIdentity) {
        processTrustCache.invalidate(identity)
    }

    private static func isCurrentLiveCodexProcess(_ identity: TrustedApplicationIdentity) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: identity.processIdentifier),
              !application.isTerminated,
              isCodexApplication(bundleIdentifier: application.bundleIdentifier),
              let launchDate = application.launchDate,
              let bundleURL = application.bundleURL else { return false }
        return identity.matches(
            processIdentifier: application.processIdentifier,
            launchDate: launchDate,
            bundleURL: bundleURL.standardizedFileURL
        )
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
