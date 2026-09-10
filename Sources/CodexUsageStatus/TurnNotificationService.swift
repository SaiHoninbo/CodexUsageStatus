import Foundation
import UserNotifications

struct TurnNotificationPreferences: Equatable {
    var notifyOnSuccess: Bool
    var notifyOnFailure: Bool
    var notifyOnInterrupted: Bool
    var notifyOnLongRunning: Bool
    var longRunningThresholdMinutes: Int
    var showContentInNotifications: Bool
    var soundEnabled: Bool
    var notifyOnPlanProgress: Bool = false
}

private struct TurnPlanNotificationIdentity: Hashable {
    let profileID: UUID?
    let physicalRootPath: String
    let threadID: String
    let turnID: String
}

private struct TurnPlanNotificationState {
    var lastPercentage: Int?
    var consumedMilestones: Set<Int> = []
}

final class TurnNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let sentKey = "turn.notification.sentKeys"
    /// `UNUserNotificationCenter.add` completes asynchronously.  Reserve a
    /// terminal notification key before enqueueing so repeated evaluations of
    /// the same Turn cannot race the completion callback and enqueue multiple
    /// banners.  The reservation is process-local only; the existing
    /// persisted `sentKeys` remains the cross-launch dedupe authority.
    private var pendingKeys = Set<String>()
    private let pendingKeysLock = NSLock()
    private var planProgressStates: [TurnPlanNotificationIdentity: TurnPlanNotificationState] = [:]
    private let planProgressLock = NSLock()

    override init() {
        super.init()
        center.delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func evaluate(event: TurnActivitySnapshot, profileID: UUID?, preferences: TurnNotificationPreferences, now: Date = Date()) {
        let eventType: String?
        switch event.state {
        case .completed: eventType = preferences.notifyOnSuccess ? "completed" : nil
        case .failed: eventType = preferences.notifyOnFailure ? "failed" : nil
        case .interrupted: eventType = preferences.notifyOnInterrupted ? "interrupted" : nil
        default: eventType = nil
        }
        if let eventType, let turnID = event.turnID,
           let reservation = reserveIfNeeded(profileID: profileID, turnID: turnID, eventType: eventType) {
            let content = UNMutableNotificationContent()
            content.title = TurnNotificationContentPolicy.title(
                state: event.state,
                programName: event.programName,
                repositoryDisplayName: event.repositoryDisplayName,
                workspaceDisplayName: event.workspaceDisplayName
            )
            if let subtitle = TurnNotificationContentPolicy.subtitle(
                repositoryDisplayName: event.repositoryDisplayName,
                workspaceDisplayName: event.workspaceDisplayName,
                programName: event.programName
            ) {
                content.subtitle = subtitle
            }
            content.body = TurnNotificationContentPolicy.body(
                elapsedSeconds: event.elapsedSeconds,
                tokenTotal: event.tokenTotal,
                content: event.content,
                errorMessage: event.errorMessage,
                contentEnabled: preferences.showContentInNotifications
            )
            content.sound = preferences.soundEnabled ? .default : nil
            let request = UNNotificationRequest(identifier: "codex-turn-\(turnID)-\(eventType)", content: content, trigger: nil)
            center.add(request) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.markSent(profileID: profileID, turnID: turnID, eventType: eventType)
                }
                self.releaseReservation(reservation)
            }
        }

        if event.state == .completed || event.state == .failed || event.state == .interrupted,
           let turnID = event.turnID {
            clearPlanProgress(profileID: profileID, threadID: event.threadID, turnID: turnID)
        }

        if preferences.notifyOnLongRunning, event.state == .active,
           let startedAt = event.startedAt,
           now.timeIntervalSince(startedAt) >= TimeInterval(preferences.longRunningThresholdMinutes * 60),
           let turnID = event.turnID,
           let reservation = reserveIfNeeded(profileID: profileID, turnID: turnID, eventType: "longRunning") {
            let content = UNMutableNotificationContent()
            content.title = "Codex Turn 執行較久"
            content.body = "目前 turn 已執行 \(max(1, Int(now.timeIntervalSince(startedAt) / 60))) 分鐘。"
            content.sound = preferences.soundEnabled ? .default : nil
            center.add(UNNotificationRequest(identifier: "codex-turn-\(turnID)-long", content: content, trigger: nil)) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.markSent(profileID: profileID, turnID: turnID, eventType: "longRunning")
                }
                self.releaseReservation(reservation)
            }
        }
    }

    /// Emits at most one notification for the newest milestone crossed by a
    /// valid full plan snapshot. State is process-local; no persistence,
    /// polling, or timer is introduced. The caller supplies an already scoped
    /// active execution, preserving Repo/Workspace/Chat isolation.
    func evaluatePlanProgress(
        execution: CodexExecutionProjection,
        preferences: TurnNotificationPreferences,
        now: Date = Date()
    ) {
        guard preferences.notifyOnPlanProgress,
              let plan = execution.plan else { return }
        let progress = TurnPlanProgressPolicy.make(from: plan)
        guard progress.hasPlanAuthority, let percentage = progress.percentage else { return }

        let identity = TurnPlanNotificationIdentity(
            profileID: execution.key.profileID,
            physicalRootPath: execution.key.normalizedPhysicalRootPath,
            threadID: execution.key.threadID,
            turnID: execution.key.turnID
        )
        planProgressLock.lock()
        var state = planProgressStates[identity] ?? TurnPlanNotificationState()
        let previousPercentage = state.lastPercentage
        let decision = TurnPlanNotificationPolicy.nextMilestone(
            previousPercentage: previousPercentage,
            currentPercentage: percentage,
            consumed: state.consumedMilestones
        )
        state.lastPercentage = percentage
        if let decision { state.consumedMilestones = decision.consumed }
        planProgressStates[identity] = state
        planProgressLock.unlock()

        guard let decision else { return }
        // A jump can cross multiple milestones but emits only the newest one.
        // Persist the lower crossed milestones as consumed in the existing
        // bounded terminal-notification key store so a later app launch cannot
        // replay them as if the Turn were new.
        for milestone in decision.consumed where milestone != decision.milestone {
            markPlanProgressSent(
                planProgressKey(identity: identity, milestone: milestone)
            )
        }
        let latestKey = planProgressKey(identity: identity, milestone: decision.milestone)
        guard reservePlanProgressIfNeeded(latestKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = TurnNotificationContentPolicy.planProgressTitle(
            repositoryDisplayName: execution.repositoryDisplayName,
            workspaceDisplayName: execution.workspaceDisplayName,
            percentage: percentage
        )
        if let subtitle = TurnNotificationContentPolicy.planProgressSubtitle(programName: execution.chatName) {
            content.subtitle = subtitle
        }
        let elapsed = max(0, Int64(now.timeIntervalSince(execution.startedAt)))
        content.body = TurnNotificationContentPolicy.planProgressBody(
            completedCount: progress.completedCount,
            totalCount: progress.totalCount,
            elapsedSeconds: elapsed
        )
        content.sound = preferences.soundEnabled ? .default : nil
        let identifier = "codex-plan-progress-\(execution.key.turnID)-\(decision.milestone)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.markPlanProgressSent(latestKey)
            } else {
                self.planProgressLock.lock()
                if var state = self.planProgressStates[identity], state.lastPercentage == percentage {
                    state.lastPercentage = previousPercentage
                    state.consumedMilestones.remove(decision.milestone)
                    self.planProgressStates[identity] = state
                }
                self.planProgressLock.unlock()
            }
            self.releaseReservation(latestKey)
        }
    }

    private func planProgressKey(identity: TurnPlanNotificationIdentity, milestone: Int) -> String {
        TurnPlanNotificationPolicy.dedupeKey(
            profileID: identity.profileID,
            physicalRootPath: identity.physicalRootPath,
            threadID: identity.threadID,
            turnID: identity.turnID,
            milestone: milestone
        )
    }

    private func reservePlanProgressIfNeeded(_ notificationKey: String) -> Bool {
        pendingKeysLock.lock()
        defer { pendingKeysLock.unlock() }
        guard !sentKeys.contains(notificationKey), pendingKeys.insert(notificationKey).inserted else {
            return false
        }
        return true
    }

    private func markPlanProgressSent(_ notificationKey: String) {
        pendingKeysLock.lock()
        var keys = sentKeys
        keys.insert(notificationKey)
        defaults.set(Array(keys.sorted().suffix(1000)), forKey: sentKey)
        pendingKeysLock.unlock()
    }

    private func clearPlanProgress(profileID: UUID?, threadID: String?, turnID: String) {
        planProgressLock.lock()
        planProgressStates = planProgressStates.filter { key, _ in
            guard key.profileID == profileID, key.turnID == turnID else { return true }
            if let threadID { return key.threadID != threadID }
            return false
        }
        planProgressLock.unlock()
    }

    func notifyAccountSwitch(profileID: UUID, displayName: String, soundEnabled: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 帳號已切換"
        content.body = "目前使用：\(displayName)"
        content.sound = soundEnabled ? .default : nil
        let request = UNNotificationRequest(identifier: "codex-account-switch-\(profileID.uuidString)-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        center.add(request)
    }

    /// Atomically checks the existing persisted dedupe key and reserves it for
    /// this process.  The returned key is released when UserNotifications
    /// accepts or rejects the request.  Keeping the reservation separate from
    /// `sentKeys` avoids changing the existing persistence or delivery
    /// semantics while closing the async enqueue race.
    private func reserveIfNeeded(profileID: UUID?, turnID: String, eventType: String) -> String? {
        let notificationKey = key(profileID: profileID, turnID: turnID, eventType: eventType)
        pendingKeysLock.lock()
        defer { pendingKeysLock.unlock() }
        guard !sentKeys.contains(notificationKey), pendingKeys.insert(notificationKey).inserted else {
            return nil
        }
        return notificationKey
    }

    private func releaseReservation(_ notificationKey: String) {
        pendingKeysLock.lock()
        pendingKeys.remove(notificationKey)
        pendingKeysLock.unlock()
    }

    private func markSent(profileID: UUID?, turnID: String, eventType: String) {
        var keys = sentKeys
        keys.insert(key(profileID: profileID, turnID: turnID, eventType: eventType))
        defaults.set(Array(keys.sorted().suffix(1000)), forKey: sentKey)
    }

    private var sentKeys: Set<String> { Set(defaults.stringArray(forKey: sentKey) ?? []) }

    private func key(profileID: UUID?, turnID: String, eventType: String) -> String {
        "\(profileID?.uuidString ?? "unknown")|\(turnID)|\(eventType)"
    }
}
