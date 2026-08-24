import AppKit
import Combine
import Foundation

@MainActor
final class GitWorkspaceCoordinator: ObservableObject {
    @Published private(set) var resolution = CodexWorkspaceResolution(processID: nil, workspaceURL: nil, reason: "尚未解析", windowSignature: nil)
    @Published private(set) var snapshot: GitWorkspaceSnapshot?
    @Published private(set) var operationState: GitWorkspaceOperationState = .idle
    @Published private(set) var confirmation: GitWorkspaceConfirmation?
    @Published private(set) var diffPreview: String?
    @Published var selectedPaths: Set<String> = []
    @Published var commitMessage = ""

    let resolver: CodexWorkspaceResolver
    let service: GitWorkspaceService
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var epoch = UUID()
    private var lastRefreshAt: Date?
    private var lastProcessID: pid_t?
    private var lastWindowSignature: String?

    init(service: GitWorkspaceService = GitWorkspaceService()) {
        self.service = service
        self.resolver = CodexWorkspaceResolver(gitService: service)
    }

    var isWorkspaceKnown: Bool { resolution.isKnown && snapshot != nil }
    var branchLabel: String {
        guard let snapshot else { return "—" }
        if snapshot.isDetached { return "detached" }
        return snapshot.identity.branch ?? "—"
    }

    var compactStatusLabel: String {
        guard let snapshot else { return "⑂ —" }
        let prefix = snapshot.hasConflicts ? "⚠" : (snapshot.changes.isEmpty ? "✓" : "⑂")
        let count = snapshot.changes.isEmpty ? "" : " · \(snapshot.changes.count)"
        return "\(prefix) \(branchLabel)\(count)"
    }

    func refreshIfNeeded(force: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication, CodexWorkspaceResolver.isCodexApplication(app) else {
            invalidate(reason: "Codex 不在前景")
            return
        }
        let now = Date()
        let windowSignature = resolver.focusedWindowSignature(for: app)
        if !force, let lastRefreshAt,
           windowSignature != nil,
           now.timeIntervalSince(lastRefreshAt) < 8,
           lastProcessID == app.processIdentifier,
           lastWindowSignature == windowSignature { return }
        let focusedIdentityChanged = windowSignature == nil || lastProcessID != app.processIdentifier || lastWindowSignature != windowSignature
        if focusedIdentityChanged {
            operationTask?.cancel()
            operationTask = nil
            confirmation = nil
            selectedPaths.removeAll()
            diffPreview = nil
        }
        lastRefreshAt = now
        lastProcessID = app.processIdentifier
        lastWindowSignature = windowSignature
        refreshTask?.cancel()
        let taskEpoch = UUID()
        epoch = taskEpoch
        operationState = .resolving
        refreshTask = Task { [weak self, resolver] in
            let result = await resolver.resolve(frontmostApplication: app)
            guard !Task.isCancelled else { return }
            guard let current = NSWorkspace.shared.frontmostApplication,
                  current.processIdentifier == app.processIdentifier,
                  CodexWorkspaceResolver.isCodexApplication(current),
                  resolver.focusedWindowSignature(for: current) == windowSignature else { return }
            await self?.applyResolution(result, epoch: taskEpoch)
        }
    }

    func refreshNow() { refreshIfNeeded(force: true) }

    func requestCommitConfirmation() {
        guard let snapshot, !selectedPaths.isEmpty, !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            operationState = .error("請選擇檔案並輸入提交訊息")
            return
        }
        confirmation = snapshot.changes.contains { selectedPaths.contains($0.path) && $0.isSensitive } ? .sensitiveCommit : .commit
    }

    func requestPushConfirmation() {
        guard let snapshot, GitPushPolicy.arguments(identity: snapshot.identity) != nil else {
            operationState = .error("目前工作區沒有可安全推送的 upstream")
            return
        }
        confirmation = .push
    }

    func cancelConfirmation() { confirmation = nil }

    func confirmCommit() {
        guard confirmation == .commit || confirmation == .sensitiveCommit,
              let snapshot, let root = resolution.workspaceURL else { return }
        let selected = Array(selectedPaths).sorted()
        guard let frozenProcessID = resolution.processID,
              isCodexFrontmost(processID: frozenProcessID) else {
            confirmation = nil
            operationState = .error("Codex 不在前景，已停止 Git 操作")
            return
        }
        guard selected.allSatisfy(GitCommitPolicy.isSafeRelativePath) else {
            confirmation = nil
            operationState = .error("選取的路徑無效")
            return
        }
        confirmation = nil
        operationState = .committing
        let taskEpoch = epoch
        operationTask?.cancel()
        let frozenMessage = commitMessage
        operationTask = Task { [weak self, service] in
            do {
                let current = try await service.readStatus(at: root)
                guard let self,
                      self.isCodexFrontmost(processID: frozenProcessID),
                      current.identity == snapshot.identity,
                      Set(selected).isSubset(of: Set(current.changes.map(\.path))) else {
                    await self?.finish(nil, state: .error("Codex 或 Git 狀態已變更，請重新確認"), epoch: taskEpoch)
                    return
                }
                guard self.isCodexFrontmost(processID: frozenProcessID) else {
                    await self.finish(nil, state: .error("Codex 不在前景，已停止 Git 操作"), epoch: taskEpoch)
                    return
                }
                let updated = try await service.commit(at: root, snapshot: current, paths: selected, message: frozenMessage)
                guard !Task.isCancelled else { return }
                await self.finish(updated, state: .success("Commit 完成"), epoch: taskEpoch)
            } catch {
                await self?.finish(nil, state: .error(Self.safeMessage(error)), epoch: taskEpoch)
            }
        }
    }

    func confirmPush() {
        guard confirmation == .push, let snapshot, let root = resolution.workspaceURL else { return }
        guard let frozenProcessID = resolution.processID,
              isCodexFrontmost(processID: frozenProcessID) else {
            confirmation = nil
            operationState = .error("Codex 不在前景，已停止 Git 操作")
            return
        }
        confirmation = nil
        operationState = .pushing
        let frozen = snapshot.identity
        let taskEpoch = epoch
        operationTask?.cancel()
        operationTask = Task { [weak self, service] in
            do {
                let current = try await service.readStatus(at: root)
                guard let self,
                      self.isCodexFrontmost(processID: frozenProcessID),
                      current.identity == frozen else {
                    await self?.finish(nil, state: .error("Codex 或 Git 狀態已變更，請重新確認"), epoch: taskEpoch)
                    return
                }
                guard self.isCodexFrontmost(processID: frozenProcessID) else {
                    await self.finish(nil, state: .error("Codex 不在前景，已停止 Git 操作"), epoch: taskEpoch)
                    return
                }
                let updated = try await service.push(at: root, identity: frozen)
                guard !Task.isCancelled else { return }
                await self.finish(updated, state: .success("Push 完成"), epoch: taskEpoch)
            } catch {
                await self?.finish(nil, state: .error(Self.safeMessage(error)), epoch: taskEpoch)
            }
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        // Invalidate every callback already spawned by the cancelled task.
        // Without a new epoch, a late cancellation/error continuation could
        // overwrite the ready state or a subsequent operation.
        epoch = UUID()
        confirmation = nil
        if operationState.isBusy { operationState = .ready }
    }

    func toggleSelection(path: String) {
        guard let snapshot, snapshot.changes.contains(where: { $0.path == path }) else { return }
        if selectedPaths.contains(path) { selectedPaths.remove(path) } else { selectedPaths.insert(path) }
    }

    func loadDiff(path: String) {
        guard let root = resolution.workspaceURL, let change = snapshot?.changes.first(where: { $0.path == path }), !change.isSensitive else {
            diffPreview = nil
            return
        }
        let taskEpoch = epoch
        diffTask?.cancel()
        diffTask = Task { [weak self, service] in
            let diff = try? await service.readDiff(at: root, path: path)
            guard !Task.isCancelled else { return }
            await self?.applyDiff(diff, epoch: taskEpoch)
        }
    }

    private func applyResolution(_ result: CodexWorkspaceResolution, epoch taskEpoch: UUID) async {
        guard epoch == taskEpoch else { return }
        let identityChanged = resolution.workspaceURL != result.workspaceURL
            || resolution.processID != result.processID
            || resolution.windowSignature != result.windowSignature
        resolution = result
        if identityChanged {
            selectedPaths.removeAll()
            diffPreview = nil
            confirmation = nil
            operationTask?.cancel()
        }
        guard let root = result.workspaceURL else {
            snapshot = nil
            operationState = .unavailable(result.reason)
            return
        }
        do {
            let next = try await service.readStatus(at: root)
            guard epoch == taskEpoch else { return }
            snapshot = next
            operationState = .ready
        } catch {
            guard epoch == taskEpoch else { return }
            snapshot = nil
            operationState = .error(Self.safeMessage(error))
        }
    }

    private func applyDiff(_ diff: String?, epoch taskEpoch: UUID) async {
        guard epoch == taskEpoch else { return }
        diffPreview = diff
    }

    private func finish(_ updated: GitWorkspaceSnapshot?, state: GitWorkspaceOperationState, epoch taskEpoch: UUID) async {
        guard epoch == taskEpoch else { return }
        if let updated { snapshot = updated }
        operationState = state
        selectedPaths.removeAll()
    }

    private func invalidate(reason: String) {
        refreshTask?.cancel()
        refreshTask = nil
        operationTask?.cancel()
        operationTask = nil
        diffTask?.cancel()
        diffTask = nil
        confirmation = nil
        lastProcessID = nil
        lastWindowSignature = nil
        epoch = UUID()
        if !resolution.isKnown || resolution.reason != reason {
            resolution = CodexWorkspaceResolution(processID: nil, workspaceURL: nil, reason: reason, windowSignature: nil)
            snapshot = nil
            selectedPaths.removeAll()
        }
        operationState = .unavailable(reason)
    }

    private func isCodexFrontmost(processID: pid_t) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == processID else { return false }
        return CodexWorkspaceResolver.isCodexApplication(app)
    }

    private static func safeMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return "Git 操作失敗，請重新整理"
    }
}
