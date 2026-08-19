import Foundation

enum CodexCLIResolver {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> String? {
        var candidates: [String] = []
        if let configured = environment["CODEX_CLI_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ])
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }
}
