import Foundation

enum CodexCLIResolver {
    /// ChatGPT's bundled Codex CLI moved under `codex-cli/bin` in newer
    /// desktop releases. Keep the legacy path as a compatibility fallback,
    /// but prefer the currently shipped executable before machine-wide CLI
    /// installs so the app-server protocol matches the installed ChatGPT.
    static let bundledChatGPTCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex"
    ]

    static func candidatePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var candidates: [String] = []
        if let configured = environment["CODEX_CLI_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(contentsOf: bundledChatGPTCandidates)
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        candidates.append(contentsOf: [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ])
        return candidates
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> String? {
        candidatePaths(environment: environment)
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
    }
}
