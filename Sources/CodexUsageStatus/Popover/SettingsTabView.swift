import AppKit
import SwiftUI

/// Settings owns account management and all low-frequency controls. Disclosure
/// state remains view-local so this surface stays compact without creating a
/// persistent product preference.
extension UsagePopoverView {
    var settingsTab: some View {
        VStack(alignment: .leading, spacing: 7) {
            settingsAlertSummary
            disclosureSection(
                title: "通知",
                systemImage: "bell.badge",
                isExpanded: $isNotificationsExpanded
            ) {
                settingsSectionContent
            }
            disclosureSection(
                title: "HUD",
                systemImage: "rectangle.inset.filled",
                isExpanded: $isHUDExpanded
            ) {
                hudSettingsSectionContent
            }
            disclosureSection(
                title: "同步",
                systemImage: "arrow.triangle.2.circlepath",
                isExpanded: $isSyncExpanded
            ) {
                syncSettingsSectionContent
            }
            disclosureSection(
                title: "軟體更新",
                systemImage: "arrow.down.circle",
                isExpanded: $isUpdateExpanded
            ) {
                updateSectionContent
            }
            disclosureSection(
                title: "關於與操作",
                systemImage: "info.circle",
                isExpanded: $isMetadataExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    metadataSection
                    actions
                }
            }
        }
    }

    @ViewBuilder
    var settingsAlertSummary: some View {
        let alerts = settingsAlerts
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("需要處理", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HUDColorPalette.warning)

                ForEach(alerts) { alert in
                    settingsAlertRow(alert)
                }
            }
            .padding(10)
            .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HUDColorPalette.warning.opacity(0.45), lineWidth: 0.8) }
        }
    }

    var settingsAlerts: [SettingsAlertPresentation] {
        model.currentSettingsAlerts
    }

    private func settingsAlertRow(_ alert: SettingsAlertPresentation) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: alert.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(alert.severity == .error ? HUDColorPalette.error : HUDColorPalette.warning)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.caption.weight(.semibold))
                Text(alert.message)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let actionTitle = alert.actionTitle {
                Button(actionTitle) {
                    handleSettingsAlert(alert)
                }
                .buttonStyle(.link)
                .font(.caption2.weight(.semibold))
                .fixedSize()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func handleSettingsAlert(_ alert: SettingsAlertPresentation) {
        guard let action = alert.action else { return }
        acknowledgeAction("已接受：\(alert.title)", control: "alert.\(alert.id)")
        PopoverInteractionTrace.started("alert.\(alert.id)")
        switch action {
        case .accounts:
            selectionController.select(.accounts)
        case .accessibility:
            isHUDExpanded = true
            model.openAccessibilitySettings()
        case .notifications:
            isNotificationsExpanded = true
            if model.notificationAuthorizationStatus == .notDetermined {
                model.requestNotificationPermission()
            } else {
                openNotificationSettings()
            }
        case .update:
            isUpdateExpanded = true
            model.checkForUpdates()
        case .refresh:
            model.refresh()
        }
    }

    func disclosureSection<Content: View>(
        title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                acknowledgeAction(isExpanded.wrappedValue ? "\(title)已收合" : "\(title)已展開", control: "disclosure.\(title)")
                PopoverInteractionTrace.started("disclosure.\(title)")
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 12)
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HUDColorPalette.primaryText)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverImmediateButtonStyle(controlID: "disclosure.\(title)"))
            .accessibilityValue(isExpanded.wrappedValue ? "已展開" : "已收合")

            if isExpanded.wrappedValue {
                content()
                    .padding(.horizontal, 9)
                    .padding(.bottom, 9)
            }
        }
        .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    var settingsSectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("啟用用量通知", isOn: Binding(
                get: { model.notificationsEnabled },
                set: { model.setNotificationsEnabled($0) }
            ))
            Toggle("Primary／secondary 分開提醒", isOn: Binding(
                get: { model.separateWindowNotifications },
                set: { model.setSeparateWindowNotifications($0) }
            ))
            Toggle("播放提示音", isOn: Binding(
                get: { model.notificationSoundEnabled },
                set: { model.setNotificationSoundEnabled($0) }
            ))
            Toggle("Turn 完成通知", isOn: Binding(
                get: { model.notifyOnTurnSuccess },
                set: { model.setTurnSuccessNotifications($0) }
            ))
            Toggle("Turn 失敗通知", isOn: Binding(
                get: { model.notifyOnTurnFailure },
                set: { model.setTurnFailureNotifications($0) }
            ))
            Toggle("Turn 中斷通知", isOn: Binding(
                get: { model.notifyOnTurnInterrupted },
                set: { model.setTurnInterruptedNotifications($0) }
            ))
            Toggle("長時間 Turn 通知", isOn: Binding(
                get: { model.notifyOnLongRunningTurn },
                set: { model.setLongRunningTurnNotifications($0) }
            ))
            Toggle("計畫進度通知", isOn: Binding(
                get: { model.notifyOnPlanProgress },
                set: { model.setPlanProgressNotifications($0) }
            ))
            Text("只在目前計畫跨過 25%、50%、75% 時通知；每個 Turn 最多三次，不包含目前步驟或 ETA。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("通知顯示 Turn 內容", isOn: Binding(
                get: { model.showTurnContentInNotifications },
                set: { model.setTurnContentInNotifications($0) }
            ))
            .disabled(!model.turnContentNotificationSupported)
            Text(model.turnContentNotificationSupported
                 ? "通知內容功能由目前的 Turn 來源提供。"
                 : "本機 rollout 只提供 Turn metadata；為保護 prompt 與對話內容，這個選項目前停用。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("帳號切換通知", isOn: Binding(
                get: { model.notifyOnAccountSwitch },
                set: { model.setAccountSwitchNotifications($0) }
            ))
            Text("提醒門檻")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HUDColorPalette.secondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                ForEach([50, 25, 20, 10, 5], id: \.self) { threshold in
                    Toggle("剩餘 \(threshold)%", isOn: Binding(
                        get: { model.notificationThresholds.contains(threshold) },
                        set: { model.setThreshold(threshold, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }

            HStack {
                Text("通知權限：\(model.notificationAuthorizationText)")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                Spacer()
                if model.notificationAuthorizationStatus == .denied {
                    Button("開啟系統設定") {
                        acknowledgeAction("正在開啟通知設定", control: "settings.notificationSettings")
                        PopoverInteractionTrace.started("settings.notificationSettings")
                        openNotificationSettings()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                } else if model.notificationAuthorizationStatus == .notDetermined {
                    Button("允許通知") {
                        acknowledgeAction("通知權限請求已送出", control: "settings.requestNotifications")
                        PopoverInteractionTrace.started("settings.requestNotifications")
                        model.requestNotificationPermission()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.top, 2)
        }
    }

    var hudSettingsSectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("顯示 Codex 浮動用量 HUD", isOn: Binding(
                get: { model.floatingHUDEnabled },
                set: { model.setFloatingHUDEnabled($0) }
            ))
            Text("只在 Codex 視窗位於前景時顯示；這是獨立浮動面板，不會修改 Codex 主視窗。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Token Reel 音效", isOn: Binding(
                get: { model.tokenReelSoundEnabled },
                set: { model.setTokenReelSoundEnabled($0) }
            ))
            Text("只有真正增加的 Token 才播放一次 Reel 音效；不會因啟動、切帳號或重新整理重播。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("試聽 Reel 音效") {
                acknowledgeAction("試聽已接受", control: "settings.previewReel")
                PopoverInteractionTrace.started("settings.previewReel")
                model.previewTokenReelSound()
            }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!model.tokenReelSoundEnabled)
            Button("重設 HUD 位置") {
                acknowledgeAction("HUD 位置已重設", control: "settings.resetHUD")
                PopoverInteractionTrace.started("settings.resetHUD")
                resetHUDPosition()
            }
                .buttonStyle(.link)
                .font(.caption)
            HStack(spacing: 8) {
                Label("輔助功能", systemImage: model.accessibilityPermissionState == .trusted ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(model.accessibilityPermissionState == .trusted ? HUDColorPalette.continueAction : HUDColorPalette.warning)
                Text(model.accessibilityPermissionState.displayName)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                Spacer(minLength: 0)
                if model.accessibilityPermissionState != .trusted {
                    Button("開啟設定") {
                        acknowledgeAction("正在開啟輔助功能設定", control: "settings.accessibilitySettings")
                        PopoverInteractionTrace.started("settings.accessibilitySettings")
                        model.openAccessibilitySettings()
                    }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Text(model.accessibilityPermissionState == .trusted
                ? "已可使用 HUD 剪貼簿操作。"
                : "只有需要替你把內容貼到 Codex 時才需要；正式簽章更新通常會保留此權限。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var syncSettingsSectionContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            syncIntervalPicker(
                title: "Quota／Primary／Secondary",
                value: model.quotaRefreshIntervalSeconds,
                options: [30, 60, 120, 300, 600, 1800, 3600],
                setter: model.setQuotaRefreshInterval
            )
            syncIntervalPicker(
                title: "目前帳號身份",
                value: model.globalSyncIntervalSeconds,
                options: [60, 300, 600, 900, 1800, 3600],
                setter: model.setGlobalSyncInterval
            )
            syncIntervalPicker(
                title: "Token Activity",
                value: model.tokenActivityRefreshIntervalSeconds,
                options: [300, 900, 1800, 3600, 7200],
                setter: model.setTokenActivityRefreshInterval
            )
            syncIntervalPicker(
                title: "帳號切換偵測",
                value: model.credentialWatchIntervalSeconds,
                options: [5, 15, 30, 60, 120],
                setter: model.setCredentialWatchInterval
            )
            Text("帳號切換偵測只檢查 auth.json 的修改時間、大小與檔案編號，不讀取或保存 token。變更後會重新啟動對應的本機 App Server。")
                .font(.caption2)
                .foregroundStyle(HUDColorPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    func syncIntervalPicker(
        title: String,
        value: Int,
        options: [Int],
        setter: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Picker(title, selection: Binding(
                get: { value },
                set: setter
            )) {
                ForEach(options, id: \.self) { option in
                    Text(formatInterval(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }

    func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分鐘" }
        return "\(minutes / 60) 小時"
    }

    var updateSectionContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("軟體更新", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                updateStatusLabel
            }

            switch model.updateState {
            case .idle:
                Text("啟動後會檢查 GitHub Release。")
                    .font(.body)
                    .foregroundStyle(HUDColorPalette.secondaryText)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在檢查更新…")
                        .font(.body)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                    Spacer()
                }
            case .upToDate:
                Text("目前已是最新版本。")
                    .font(.body)
                    .foregroundStyle(HUDColorPalette.continueAction)
            case .available(let release):
                updateReleaseDetails(release)
                HStack(spacing: 10) {
                    Button(AppUpdatePresentationPolicy.installButtonTitle) {
                        acknowledgeAction("正在下載並覆蓋更新", control: "settings.installUpdate")
                        PopoverInteractionTrace.started("settings.installUpdate")
                        model.installUpdate(release)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(AppUpdatePresentationPolicy.releaseButtonTitle) {
                        acknowledgeAction("正在開啟更新內容", control: "settings.release")
                        PopoverInteractionTrace.started("settings.release")
                        model.openUpdateReleasePage()
                    }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            case .downloading(let release):
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在下載 Codex Usage Status \(release.version)…")
                        .font(.body)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                }
            case .installing(let release):
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在覆蓋並重新啟動 \(release.version)…")
                        .font(.body)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                }
            case .error(let message):
                Text(message)
                    .font(.body)
                    .foregroundStyle(HUDColorPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重試") {
                        acknowledgeAction("已接受：重新檢查更新", control: "settings.retryUpdate")
                        PopoverInteractionTrace.started("settings.retryUpdate")
                        model.checkForUpdates()
                    }
                        .buttonStyle(.link)
                        .font(.subheadline)
                    Button("開啟 GitHub") {
                        acknowledgeAction("正在開啟 GitHub", control: "settings.github")
                        PopoverInteractionTrace.started("settings.github")
                        model.openUpdateReleasePage()
                    }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch model.updateState {
        case .checking, .downloading, .installing:
            Text("處理中").font(.subheadline).foregroundStyle(HUDColorPalette.secondaryText)
        case .available:
            Text("有新版").font(.subheadline).foregroundStyle(HUDColorPalette.sevenDay)
        case .upToDate:
            Text("最新").font(.subheadline).foregroundStyle(HUDColorPalette.continueAction)
        case .error:
            Text("檢查失敗").font(.subheadline).foregroundStyle(HUDColorPalette.warning)
        case .idle:
            EmptyView()
        }
    }

    private func updateReleaseDetails(_ release: AppUpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("版本 \(release.version)")
                .font(.body.weight(.semibold))
            if let publishedAt = release.publishedAt {
                Text("發布：\(publishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }
            if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(release.notes)
                    .font(.subheadline)
                    .foregroundStyle(HUDColorPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var metadataSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            metadataRow("方案", model.snapshot?.planType ?? "—")
            metadataRow("Limit", model.snapshot?.limitName ?? model.snapshot?.limitId ?? "—")
            metadataRow("最後更新", model.lastUpdatedText)
            metadataRow("登入啟動", model.loginItemManager.statusText)
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var actions: some View {
        HStack {
            Button("Refresh") {
                acknowledgeAction("重新整理已接受", control: "settings.refresh")
                PopoverInteractionTrace.started("settings.refresh")
                model.refresh()
            }
            Button("Open Codex") {
                acknowledgeAction("正在開啟 Codex", control: "settings.openCodex")
                PopoverInteractionTrace.started("settings.openCodex")
                openCodex()
            }
            Spacer()
            Button("Quit") {
                PopoverInteractionTrace.accepted("settings.quit")
                quit()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(HUDColorPalette.tertiaryText)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") else { return }
        NSWorkspace.shared.open(url)
    }
}
