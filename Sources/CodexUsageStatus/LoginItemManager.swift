import Foundation
import Combine
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var message: String?

    var isSupportedBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func registerIfNeeded() {
        guard isSupportedBundle else {
            message = "建置模式不會註冊登入啟動；安裝 app bundle 後會自動啟用。"
            return
        }
        guard status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            refresh()
            message = nil
        } catch {
            refresh()
            message = "無法啟用登入時啟動：\(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupportedBundle else {
            message = "請從 .app bundle 啟動後再設定登入啟動。"
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            message = nil
        } catch {
            refresh()
            message = "無法更新登入啟動設定：\(error.localizedDescription)"
        }
    }

    var statusText: String {
        switch status {
        case .enabled: return "已啟用"
        case .requiresApproval: return "需要系統核准"
        case .notRegistered: return "未啟用"
        case .notFound: return "找不到 app"
        @unknown default: return "未知"
        }
    }
}
