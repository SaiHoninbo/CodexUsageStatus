import AppKit
import Foundation

enum AccountManagementError: LocalizedError {
    case cliNotFound
    case loginAlreadyRunning
    case unableToLaunch(String)
    case importCancelled

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "找不到 Codex CLI。請設定 CODEX_CLI_PATH 或安裝 ChatGPT.app。"
        case .loginAlreadyRunning: return "這個帳號已有登入流程進行中。"
        case .unableToLaunch(let message): return message
        case .importCancelled: return "使用者取消匯入。"
        }
    }
}

@MainActor
final class AccountManagementService {
    private var loginProcesses: [UUID: Process] = [:]
    private var loginSessionTokens: [UUID: UUID] = [:]
    private let executableResolver: () -> String?
    var onLoginOutput: ((UUID, String) -> Void)?

    var loginProcessIDs: [Int32] {
        loginProcesses.values.filter(\.isRunning).map(\.processIdentifier)
    }

    init(executableResolver: @escaping () -> String? = { CodexCLIResolver.resolve() }) {
        self.executableResolver = executableResolver
    }

    func startOfficialLogin(profile: AccountProfile, codexHomeURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard loginProcesses[profile.id] == nil else {
            completion(.failure(AccountManagementError.loginAlreadyRunning))
            return
        }
        guard let executable = executableResolver() else {
            completion(.failure(AccountManagementError.cliNotFound))
            return
        }
        let process = Process()
        let sessionToken = UUID()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["login", "--device-auth"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard self?.loginSessionTokens[profile.id] == sessionToken else { return }
                self?.onLoginOutput?(profile.id, String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)))
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard self?.loginSessionTokens[profile.id] == sessionToken else { return }
                self?.onLoginOutput?(profile.id, String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)))
            }
        }
        loginProcesses[profile.id] = process
        loginSessionTokens[profile.id] = sessionToken
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard self.loginSessionTokens[profile.id] == sessionToken else { return }
                self.loginSessionTokens[profile.id] = nil
                self.loginProcesses[profile.id] = nil
                if process.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(AccountManagementError.unableToLaunch("官方登入流程結束，請查看 Codex 的登入提示後再試。")))
                }
            }
        }
        do {
            try process.run()
        } catch {
            loginProcesses[profile.id] = nil
            loginSessionTokens[profile.id] = nil
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            completion(.failure(error))
        }
    }

    func stopLogin(profileID: UUID) {
        loginSessionTokens[profileID] = nil
        guard let process = loginProcesses.removeValue(forKey: profileID) else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Stops every outstanding login child and releases its pipe handlers.
    /// App shutdown and profile removal both call this method; it is safe to
    /// invoke repeatedly and prevents orphaned CLI processes retaining a
    /// deleted profile's CODEX_HOME.
    func stopAllLogins() {
        let processes = Array(loginProcesses.values)
        loginProcesses.removeAll(keepingCapacity: false)
        loginSessionTokens.removeAll(keepingCapacity: false)
        for process in processes {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }

    func chooseCodexHome() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "匯入"
        panel.message = "選擇 Codex profile 目錄，或直接選擇 auth.json。"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
