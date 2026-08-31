import Foundation
import CryptoKit

enum GitWorkspaceChangeKind: String, Equatable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted
    case ignored
    case unknown
}

struct GitWorkspaceChange: Identifiable, Equatable {
    let path: String
    let originalPath: String?
    let kind: GitWorkspaceChangeKind
    let isStaged: Bool
    let isUnstaged: Bool
    let isSensitive: Bool

    var id: String { path }
}

struct GitWorkspaceIdentity: Equatable {
    let repositoryRoot: String
    let gitDirectory: String
    let branch: String?
    let head: String?
    let remote: String?
    let upstream: String?
    /// Non-reversible identity for the configured remote URL. The URL itself
    /// is never surfaced or persisted because it may contain credentials.
    let remoteFingerprint: String?
}

struct GitWorkspaceSnapshot: Equatable {
    let identity: GitWorkspaceIdentity
    let changes: [GitWorkspaceChange]
    let ahead: Int
    let behind: Int
    let isDetached: Bool
    let refreshedAt: Date

    var hasConflicts: Bool { changes.contains { $0.kind == .conflicted } }
    var selectedSummary: String { "\(changes.count) 個變更" }
}

enum GitWorkspaceOperationState: Equatable {
    case idle
    case resolving
    case ready
    case committing
    case pushing
    case success(String)
    case unavailable(String)
    case error(String)

    var isBusy: Bool {
        switch self {
        case .resolving, .committing, .pushing: return true
        default: return false
        }
    }
}

enum GitWorkspaceConfirmation: Equatable {
    case commit
    case sensitiveCommit
    case push
}

enum GitWorkspaceSensitivity {
    private static let exactNames: Set<String> = [
        ".env", "auth.json", "history.json", "token-activity.json", "profiles.json",
        "profile-salt", "credentials", "token"
    ]

    static func isSensitive(path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        for component in components {
            if component == "accounts" || component == "updates" { return true }
            if exactNames.contains(component.lowercased()) { return true }
            if component.lowercased().hasPrefix(".env.") { return true }
            if [".pem", ".key", ".p12", ".mobileprovision"].contains(where: { component.lowercased().hasSuffix($0) }) { return true }
        }
        return components.contains { $0.lowercased().contains("credential") || $0.lowercased().contains("token") }
    }
}

/// Parser for `git status --porcelain=v2 --branch -z`.  It intentionally
/// consumes machine-readable records instead of locale-dependent human text.
enum GitStatusPorcelainParser {
    struct Result: Equatable {
        var branch: String?
        var head: String?
        var upstream: String?
        var ahead: Int = 0
        var behind: Int = 0
        var changes: [GitWorkspaceChange] = []
    }

    static func parse(_ data: Data) -> Result {
        let records = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var result = Result()
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst("# branch.oid ".count))
                result.head = value == "(initial)" ? nil : value
            } else if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst("# branch.head ".count))
                result.branch = value == "(detached)" ? nil : value
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let values = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for value in values {
                    if value.hasPrefix("+") { result.ahead = Int(value.dropFirst()) ?? 0 }
                    if value.hasPrefix("-") { result.behind = Int(value.dropFirst()) ?? 0 }
                }
            } else {
                switch record.first {
                case "?":
                    let path = String(record.dropFirst(2))
                    result.changes.append(GitWorkspaceChange(path: path, originalPath: nil, kind: .untracked, isStaged: false, isUnstaged: true, isSensitive: GitWorkspaceSensitivity.isSensitive(path: path)))
                case "!":
                    let path = String(record.dropFirst(2))
                    result.changes.append(GitWorkspaceChange(path: path, originalPath: nil, kind: .ignored, isStaged: false, isUnstaged: false, isSensitive: GitWorkspaceSensitivity.isSensitive(path: path)))
                case "1":
                    let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                    if fields.count >= 9 {
                        let xy = String(fields[1])
                        let path = String(fields[8])
                        result.changes.append(GitWorkspaceChange(path: path, originalPath: nil, kind: kind(for: xy), isStaged: xy.first != ".", isUnstaged: xy.count > 1 && xy.last != ".", isSensitive: GitWorkspaceSensitivity.isSensitive(path: path)))
                    }
                case "2":
                    let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
                    if fields.count >= 10 {
                        let xy = String(fields[1])
                        let path = String(fields[9])
                        // Porcelain v2 -z emits the old path as the following NUL
                        // record for rename/copy entries. Consume it explicitly.
                        let originalPath = index + 1 < records.count ? records[index + 1] : nil
                        if originalPath != nil { index += 1 }
                        result.changes.append(GitWorkspaceChange(path: path, originalPath: originalPath, kind: xy.contains("C") ? .copied : .renamed, isStaged: xy.first != ".", isUnstaged: xy.count > 1 && xy.last != ".", isSensitive: GitWorkspaceSensitivity.isSensitive(path: path) || (originalPath.map(GitWorkspaceSensitivity.isSensitive(path:)) ?? false)))
                    }
                case "u":
                    let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                    if fields.count >= 11 {
                        let path = String(fields[10])
                        result.changes.append(GitWorkspaceChange(path: path, originalPath: nil, kind: .conflicted, isStaged: true, isUnstaged: true, isSensitive: GitWorkspaceSensitivity.isSensitive(path: path)))
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return result
    }

    private static func kind(for xy: String) -> GitWorkspaceChangeKind {
        guard let first = xy.first, let second = xy.last else { return .unknown }
        if first == "U" || second == "U" { return .conflicted }
        switch first == "R" ? "R" : first == "C" ? "C" : second == "D" ? "D" : first == "D" ? "D" : first == "A" ? "A" : second == "A" ? "A" : "M" {
        case "R": return .renamed
        case "C": return .copied
        case "D": return .deleted
        case "A": return .added
        default: return .modified
        }
    }
}

extension GitWorkspaceIdentity {
    static func fingerprint(forRemoteURL url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum GitCommitPolicy {
    static func arguments(message: String, paths: [String]) -> [String]? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !paths.isEmpty, paths.allSatisfy(isSafeRelativePath) else { return nil }
        return ["commit", "--only", "-m", trimmed, "--"] + paths
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path != ".",
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
              !path.hasPrefix(":("),
              !path.hasPrefix(":/"), !path.hasPrefix("!"), !path.hasPrefix("^"),
              !path.contains("*"), !path.contains("?"), !path.contains("[") else { return false }
        return !path.split(separator: "/").contains("..")
    }
}

/// Central execution policy for every Git invocation made by the app.
/// Repository-local configuration is untrusted input: fsmonitor, diff
/// drivers, external diff, SSH commands, credential helpers, and protocol
/// helpers can otherwise turn status or diff refreshes into process launches.
enum GitExecutionPolicy {
    private static let globalOptions: [String] = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "diff.external=",
        "-c", "core.sshCommand=",
        "-c", "core.gitProxy=",
        "-c", "credential.helper=",
        "-c", "protocol.ext.allow=never",
        "-c", "protocol.file.allow=never",
        "-c", "protocol.fd.allow=never",
        "-c", "protocol.http.allow=never",
        "-c", "protocol.git.allow=always",
        "-c", "protocol.https.allow=always",
        "-c", "protocol.ssh.allow=always"
    ]

    static let environment: [String: String] = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        // Ignore user/system SSH configuration, including ProxyCommand and
        // Match exec directives. The direct transport remains available, but
        // all child-process behavior is fixed to the system ssh binary.
        "GIT_SSH_COMMAND": "/usr/bin/ssh -F /dev/null -o BatchMode=yes",
        "GIT_SSH_VARIANT": "ssh"
    ]

    static func invocationArguments(_ arguments: [String]) -> [String] {
        guard let command = arguments.first else { return globalOptions }
        let commandOptions: [String]
        switch command {
        case "diff": commandOptions = ["--no-ext-diff", "--no-textconv"]
        default: commandOptions = []
        }
        return globalOptions + [command] + commandOptions + Array(arguments.dropFirst())
    }
}

enum GitPushPolicy {
    static func arguments(identity: GitWorkspaceIdentity) -> [String]? {
        guard let remote = identity.remote, !remote.isEmpty,
              let remoteFingerprint = identity.remoteFingerprint, !remoteFingerprint.isEmpty,
              let upstream = identity.upstream,
              let branch = identity.branch, !branch.isEmpty,
              !identity.isDetached,
              let separator = upstream.firstIndex(of: "/") else { return nil }
        let upstreamBranch = String(upstream[upstream.index(after: separator)...])
        guard !upstreamBranch.isEmpty else { return nil }
        return ["push", remote, "HEAD:refs/heads/\(upstreamBranch)"]
    }

    /// Only explicit HTTPS or SSH transports are accepted for a push. Git's
    /// `ext::`, `file://`, helper, and local transports can execute arbitrary
    /// programs or write outside the intended remote boundary.
    static func isSafeRemoteURL(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate == value,
              !candidate.contains("\0"),
              !candidate.contains("\n"),
              !candidate.hasPrefix("-") else { return false }
        let lowered = candidate.lowercased()
        if lowered.hasPrefix("ext::") || lowered.hasPrefix("file:") || lowered.hasPrefix("fd:") || lowered.hasPrefix("rsync:") || lowered.hasPrefix("ftp:") {
            return false
        }
        if candidate.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+:[^\s]+$"#, options: .regularExpression) != nil {
            return true
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["https", "ssh"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil else { return false }
        return true
    }

    static func arguments(identity: GitWorkspaceIdentity, remoteURL: String) -> [String]? {
        guard let base = arguments(identity: identity), isSafeRemoteURL(remoteURL) else { return nil }
        return [base[0], remoteURL] + base.dropFirst(2)
    }
}

extension GitWorkspaceIdentity {
    var isDetached: Bool { branch == nil || head == nil }
}
