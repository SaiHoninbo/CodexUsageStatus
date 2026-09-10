import Foundation
import UserNotifications

/// Value-semantic projection of actionable product warnings for the Settings
/// surface. Delivery authorities remain separate; this type only decides what
/// the user needs to see and which existing remediation path to open.
struct SettingsAlertPresentation: Identifiable, Equatable {
    enum Severity: Equatable {
        case error
        case warning
    }

    enum Action: Equatable {
        case accounts
        case accessibility
        case notifications
        case update
        case refresh
    }

    let id: String
    let severity: Severity
    let title: String
    let message: String
    let actionTitle: String?
    let action: Action?

    /// One wording and severity authority for update failures shown on both
    /// Overview and Settings. The updater remains the state authority.
    static func updateFailure(message: String) -> Self {
        Self(
            id: "update",
            severity: .warning,
            title: "更新檢查失敗",
            message: message,
            actionTitle: "重試",
            action: .update
        )
    }

    static func updateAvailable(version: String) -> Self {
        Self(
            id: "update-available",
            severity: .warning,
            title: "有新版本可用",
            message: "Codex Usage Status \(version) 可下載並覆蓋。",
            actionTitle: "查看更新",
            action: .update
        )
    }

    static func make(
        accessibilityPermissionState: AccessibilityPermissionState,
        notificationAuthorizationStatus: UNAuthorizationStatus,
        updateState: AppUpdateState,
        connectionState: ConnectionState,
        isStale: Bool,
        dataAgeText: String,
        accountHealthErrorMessage: String?,
        profileStoreErrorMessage: String?,
        loginStates: [UUID: String],
        historyErrorMessage: String?
    ) -> [Self] {
        var alerts: [Self] = []

        if connectionState == .offline || connectionState == .error {
            alerts.append(Self(
                id: "connection",
                severity: .error,
                title: "目前帳號無法連線",
                message: "\(connectionState.displayName)。\(dataAgeText)",
                actionTitle: "重新整理",
                action: .refresh
            ))
        }

        if let accountHealthErrorMessage = nonEmpty(accountHealthErrorMessage) {
            alerts.append(Self(
                id: "account-health",
                severity: .error,
                title: "帳號資料讀取失敗",
                message: accountHealthErrorMessage,
                actionTitle: "查看帳號",
                action: .accounts
            ))
        }

        if let profileStoreErrorMessage = nonEmpty(profileStoreErrorMessage) {
            alerts.append(Self(
                id: "profile-store",
                severity: .error,
                title: "帳號設定需要處理",
                message: profileStoreErrorMessage,
                actionTitle: "查看帳號",
                action: .accounts
            ))
        }

        if let loginError = loginStates.values.first(where: Self.isFailureMessage) {
            alerts.append(Self(
                id: "account-login",
                severity: .error,
                title: "帳號登入需要處理",
                message: loginError,
                actionTitle: "查看帳號",
                action: .accounts
            ))
        }

        if accessibilityPermissionState != .trusted {
            alerts.append(Self(
                id: "accessibility",
                severity: .warning,
                title: "輔助功能尚未允許",
                message: "HUD 的剪貼簿操作目前不可用。",
                actionTitle: "開啟設定",
                action: .accessibility
            ))
        }

        if notificationAuthorizationStatus == .denied {
            alerts.append(Self(
                id: "notifications-denied",
                severity: .warning,
                title: "通知權限已停用",
                message: "用量、Turn 與更新提醒不會顯示。",
                actionTitle: "開啟系統設定",
                action: .notifications
            ))
        } else if notificationAuthorizationStatus == .notDetermined {
            alerts.append(Self(
                id: "notifications-undetermined",
                severity: .warning,
                title: "通知權限尚未決定",
                message: "允許後才能收到系統通知。",
                actionTitle: "允許通知",
                action: .notifications
            ))
        }

        if case .error(let message) = updateState {
            alerts.append(updateFailure(message: message))
        } else if case .available(let release) = updateState {
            alerts.append(updateAvailable(version: release.version))
        }

        if connectionState == .connected, isStale {
            alerts.append(Self(
                id: "stale-data",
                severity: .warning,
                title: "目前資料較舊",
                message: "最後成功觀測：\(dataAgeText)",
                actionTitle: "重新整理",
                action: .refresh
            ))
        }

        if let historyErrorMessage = nonEmpty(historyErrorMessage) {
            alerts.append(Self(
                id: "history",
                severity: .warning,
                title: "歷史資料需要處理",
                message: historyErrorMessage,
                actionTitle: "重新整理",
                action: .refresh
            ))
        }

        return alerts
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isFailureMessage(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("失敗") || normalized.contains("錯誤") || normalized.contains("找不到")
    }
}
