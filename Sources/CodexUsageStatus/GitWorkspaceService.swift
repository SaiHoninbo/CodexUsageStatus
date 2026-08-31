import Foundation

struct GitCommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

enum GitCommandError: Error, LocalizedError {
    case launchFailed(String)
    case failed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed: return "無法啟動 Git"
        case .failed(let message): return message.isEmpty ? "Git 操作失敗" : message
        case .timedOut: return "Git 操作逾時"
        case .cancelled: return "Git 操作已取消"
        }
    }
}

/// Runs `/usr/bin/git` with an argument array and no shell interpolation.
final class GitProcessRunner {
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let continuation: CheckedContinuation<GitCommandResult, Error>

        init(_ continuation: CheckedContinuation<GitCommandResult, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<GitCommandResult, Error>) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            continuation.resume(with: result)
        }

        var isCompleted: Bool {
            lock.lock(); defer { lock.unlock() }
            return completed
        }
    }

    private final class ProcessLifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var gate: CompletionGate?

        func install(process: Process, gate: CompletionGate) {
            lock.lock()
            self.process = process
            self.gate = gate
            lock.unlock()
        }

        private func stopAndFinish(_ error: GitCommandError) {
            lock.lock()
            let process = self.process
            let gate = self.gate
            lock.unlock()
            // Let terminationHandler observe the actual exit status before
            // resuming the caller. This closes the commit-vs-cancel race:
            // a commit that already exited successfully is not mistaken for
            // a failed command whose index should be restored.
            process?.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                if !(gate?.isCompleted ?? true) {
                    gate?.finish(.failure(error))
                }
            }
        }

        func cancel() { stopAndFinish(.cancelled) }
        func timeout() { stopAndFinish(.timedOut) }
    }

    func run(arguments: [String], workingDirectory: URL, timeout: TimeInterval = 15) async throws -> GitCommandResult {
        let lifecycle = ProcessLifecycle()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitCommandResult, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = GitExecutionPolicy.invocationArguments(arguments)
                process.currentDirectoryURL = workingDirectory
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_TERMINAL_PROMPT": "0"]
                if let home = ProcessInfo.processInfo.environment["HOME"] { environment["HOME"] = home }
                environment.merge(GitExecutionPolicy.environment) { _, new in new }
                process.environment = environment

                let gate = CompletionGate(continuation)
                lifecycle.install(process: process, gate: gate)
                process.terminationHandler = { process in
                    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if process.terminationReason == .uncaughtSignal {
                        gate.finish(.failure(GitCommandError.cancelled))
                    } else if process.terminationStatus == 0 {
                        gate.finish(.success(GitCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)))
                    } else {
                        gate.finish(.failure(GitCommandError.failed(Self.safeError(stderr))))
                    }
                }

                guard !Task.isCancelled else {
                    gate.finish(.failure(GitCommandError.cancelled))
                    return
                }
                do {
                    try process.run()
                } catch {
                    gate.finish(.failure(GitCommandError.launchFailed("Git 啟動失敗")))
                    return
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(1, timeout)) {
                    if !gate.isCompleted {
                        lifecycle.timeout()
                    }
                }
            }
        }, onCancel: {
            lifecycle.cancel()
        })
    }

    private static func safeError(_ data: Data) -> String {
        // Git stderr may contain credential-bearing remotes, local paths, or
        // hook output. Keep it out of UI/logging; callers get a retryable,
        // non-sensitive status instead.
        _ = data
        return "Git 操作失敗，請重新整理"
    }
}

final class GitWorkspaceService {
    private let runner: GitProcessRunner

    init(runner: GitProcessRunner = GitProcessRunner()) {
        self.runner = runner
    }

    func repositoryRoot(for candidate: URL, timeout: TimeInterval = 1.0) async -> URL? {
        guard let result = try? await runner.run(arguments: ["rev-parse", "--show-toplevel"], workingDirectory: candidate, timeout: timeout), result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func readStatus(at root: URL, now: Date = Date()) async throws -> GitWorkspaceSnapshot {
        let status = try await runner.run(arguments: ["status", "--porcelain=v2", "--branch", "-z"], workingDirectory: root)
        let parsed = GitStatusPorcelainParser.parse(status.stdout)
        let gitDirectory = try await value(arguments: ["rev-parse", "--git-dir"], root: root)
        let absoluteGitDirectory: String
        if gitDirectory.hasPrefix("/") {
            absoluteGitDirectory = gitDirectory
        } else {
            absoluteGitDirectory = root.appendingPathComponent(gitDirectory).standardizedFileURL.path
        }
        let head = (try? await value(arguments: ["rev-parse", "HEAD"], root: root)).flatMap { $0.isEmpty ? nil : $0 }
        var ahead = parsed.ahead
        var behind = parsed.behind
        if parsed.upstream != nil, let counts = try? await value(arguments: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], root: root) {
            let parts = counts.split(separator: " ")
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? ahead
                behind = Int(parts[1]) ?? behind
            }
        }
        let remote = parsed.upstream?.split(separator: "/", maxSplits: 1).first.map(String.init)
        let remoteURL: String?
        if let remote {
            remoteURL = try? await value(arguments: ["remote", "get-url", "--push", "--", remote], root: root)
        } else {
            remoteURL = nil
        }
        let remoteFingerprint = remoteURL.map(GitWorkspaceIdentity.fingerprint(forRemoteURL:))
        let identity = GitWorkspaceIdentity(repositoryRoot: root.standardizedFileURL.path, gitDirectory: absoluteGitDirectory, branch: parsed.branch, head: head ?? parsed.head, remote: remote, upstream: parsed.upstream, remoteFingerprint: remoteFingerprint)
        return GitWorkspaceSnapshot(identity: identity, changes: parsed.changes, ahead: ahead, behind: behind, isDetached: identity.isDetached, refreshedAt: now)
    }

    func readDiff(at root: URL, path: String) async throws -> String? {
        guard GitCommitPolicy.isSafeRelativePath(path), !GitWorkspaceSensitivity.isSensitive(path: path) else { return nil }
        let gitDirectory = try await value(arguments: ["rev-parse", "--git-dir"], root: root)
        let absoluteGitDirectory = gitDirectory.hasPrefix("/")
            ? gitDirectory
            : root.appendingPathComponent(gitDirectory).standardizedFileURL.path
        guard try await mutationConfigurationIsSafe(at: root, gitDirectory: absoluteGitDirectory) else {
            return nil
        }
        let unstaged = try await runner.run(arguments: ["diff", "--unified=3", "--", path], workingDirectory: root)
        let staged = try await runner.run(arguments: ["diff", "--cached", "--unified=3", "--", path], workingDirectory: root)
        var sections: [String] = []
        let unstagedText = String(decoding: unstaged.stdout, as: UTF8.self)
        let stagedText = String(decoding: staged.stdout, as: UTF8.self)
        if !unstagedText.isEmpty { sections.append(unstagedText) }
        if !stagedText.isEmpty { sections.append("[已 staged]\n" + stagedText) }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n").prefix(12_000).description
    }

    func commit(at root: URL, snapshot: GitWorkspaceSnapshot, paths: [String], message: String) async throws -> GitWorkspaceSnapshot {
        guard try await mutationConfigurationIsSafe(at: root, gitDirectory: snapshot.identity.gitDirectory) else {
            throw GitCommandError.failed("此 Git 工作區含有未允許的可執行設定，已拒絕 commit")
        }
        let selected = Set(paths)
        let untracked = snapshot.changes.filter { change in selected.contains(change.path) && change.kind == .untracked }.map { change in change.path }
        guard let arguments = GitCommitPolicy.arguments(message: message, paths: paths) else { throw GitCommandError.failed("請輸入提交訊息並選擇檔案") }

        // git commit --only isolates the commit contents, but Git still needs
        // an intent-to-add entry for selected untracked paths. Apply that
        // entry to the real index, with a backup restored on every
        // failure/cancellation. This preserves unrelated staged files and
        // leaves the index coherent after a successful commit.
        var backupDirectory: URL?
        var realIndex: URL?
        var hadIndex = false
        var commitSucceeded = false
        if !untracked.isEmpty {
            let indexPath = try await value(arguments: ["rev-parse", "--git-path", "index"], root: root)
            let indexURL = indexPath.hasPrefix("/")
                ? URL(fileURLWithPath: indexPath)
                : root.appendingPathComponent(indexPath)
            realIndex = indexURL
            hadIndex = FileManager.default.fileExists(atPath: indexURL.path)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-git-index-backup-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if hadIndex {
                try FileManager.default.copyItem(at: indexURL, to: directory.appendingPathComponent("index"))
            }
            backupDirectory = directory
        }
        defer {
            if !commitSucceeded, let realIndex, let backupDirectory {
                let backupIndex = backupDirectory.appendingPathComponent("index")
                try? FileManager.default.removeItem(at: realIndex)
                if hadIndex {
                    try? FileManager.default.copyItem(at: backupIndex, to: realIndex)
                }
            } else if !commitSucceeded, let realIndex, !hadIndex {
                try? FileManager.default.removeItem(at: realIndex)
            }
            if let backupDirectory { try? FileManager.default.removeItem(at: backupDirectory) }
        }
        if !untracked.isEmpty {
            _ = try await runner.run(arguments: ["add", "--intent-to-add", "--"] + untracked, workingDirectory: root)
        }
        do {
            _ = try await runner.run(arguments: arguments, workingDirectory: root)
            commitSucceeded = true
        } catch {
            // Cancellation can race with a commit that has already advanced
            // HEAD. The process has been terminated before this continuation
            // resumes, so inspect HEAD while deciding whether index rollback
            // is still safe. If HEAD changed, preserve the successful commit.
            if let currentHead = try? await value(arguments: ["rev-parse", "HEAD"], root: root),
               currentHead != snapshot.identity.head {
                commitSucceeded = true
            }
            throw error
        }
        return try await readStatus(at: root)
    }

    func push(at root: URL, identity: GitWorkspaceIdentity) async throws -> GitWorkspaceSnapshot {
        guard try await mutationConfigurationIsSafe(at: root, gitDirectory: identity.gitDirectory) else {
            throw GitCommandError.failed("此 Git 工作區含有未允許的可執行設定，已拒絕 push")
        }
        guard let remote = identity.remote,
              let remoteURL = try? await value(arguments: ["remote", "get-url", "--push", "--", remote], root: root),
              let arguments = GitPushPolicy.arguments(identity: identity, remoteURL: remoteURL),
              GitWorkspaceIdentity.fingerprint(forRemoteURL: remoteURL) == identity.remoteFingerprint else {
            throw GitCommandError.failed("目前工作區沒有可安全推送的 upstream")
        }
        _ = try await runner.run(arguments: arguments, workingDirectory: root, timeout: 30)
        return try await readStatus(at: root)
    }

    private func value(arguments: [String], root: URL) async throws -> String {
        let result = try await runner.run(arguments: arguments, workingDirectory: root)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mutationConfigurationIsSafe(at root: URL, gitDirectory: String) async throws -> Bool {
        // Read the local config as data only.  The runner has already disabled
        // system/global config; this audit rejects local executable features
        // rather than bypassing hooks or signing policy with --no-verify.
        func entries(from data: Data) -> [(key: String, value: String)] {
            String(decoding: data, as: UTF8.self)
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map(String.init)
                .map { raw in
                    let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let key = parts.first.map(String.init)?.lowercased() ?? ""
                    let value = parts.dropFirst().first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
                    return (key: key, value: value)
                }
        }

        let configResult = try await runner.run(arguments: ["config", "--local", "--includes", "--null", "--list"], workingDirectory: root)
        var configEntries = entries(from: configResult.stdout)
        let forbiddenKeys = [
            "core.hookspath", "core.fsmonitor", "core.sshcommand", "core.gitproxy", "core.askpass",
            "credential.helper", "gpg.program", "diff.external", "filter.", "url."
        ]
        func containsForbidden(_ entries: [(key: String, value: String)]) -> Bool {
            entries.contains(where: { entry in
                let key = entry.key
                if key == "commit.gpgsign" {
                    return ["true", "yes", "on", "1"].contains(entry.value)
                }
                // Includes are executable configuration by proxy: they let a
                // repository select arbitrary files whose effective settings
                // must be audited, and the include directive itself is not a
                // stable trust boundary for mutation.
                if key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path")) {
                    return true
                }
                if forbiddenKeys.contains(where: { key.hasPrefix($0) }) { return true }
                if key.hasPrefix("diff.") && key.hasSuffix(".textconv") { return true }
                guard key.hasPrefix("remote.") else { return false }
                return key.hasSuffix(".uploadpack") || key.hasSuffix(".receivepack") || key.hasSuffix(".proxy") || key.hasSuffix(".vcs") || key.hasSuffix(".helper")
            })
        }

        if containsForbidden(configEntries) { return false }

        // With extensions.worktreeConfig enabled, Git also reads the
        // repository's `.git/config.worktree`. Audit that effective source
        // explicitly; `--local` alone does not include its executable keys.
        let worktreeConfigEnabled = configEntries.contains {
            $0.key == "extensions.worktreeconfig" && ["true", "yes", "on", "1"].contains($0.value)
        }
        if worktreeConfigEnabled {
            let worktreeResult = try await runner.run(arguments: ["config", "--worktree", "--includes", "--null", "--list"], workingDirectory: root)
            configEntries.append(contentsOf: entries(from: worktreeResult.stdout))
            if containsForbidden(configEntries) { return false }
        }

        let gitURL = URL(fileURLWithPath: gitDirectory).standardizedFileURL
        let hookRoot = gitURL.appendingPathComponent("hooks", isDirectory: true)
        let hookNames = ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-push"]
        for name in hookNames {
            let hook = hookRoot.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: hook.path) { return false }
        }
        return true
    }
}
