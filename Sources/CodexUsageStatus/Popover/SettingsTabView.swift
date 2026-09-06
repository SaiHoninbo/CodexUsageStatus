import AppKit
import SwiftUI

/// Settings owns account management and all low-frequency controls. Disclosure
/// state remains view-local so this surface stays compact without creating a
/// persistent product preference.
extension UsagePopoverView {
    var settingsTab: some View {
        VStack(alignment: .leading, spacing: 7) {
            accountManagementSection
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

    var accountManagementSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("帳號管理", systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.accountProfiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.id == model.currentProfileID ? "checkmark.circle.fill" : "person.crop.circle")
                            .foregroundStyle(profile.id == model.currentProfileID ? HUDColorPalette.continueAction : HUDColorPalette.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.accountProfileDisplay(for: profile).title)
                                .font(.caption.weight(.semibold))
                            Text(model.accountProfileDisplay(for: profile).subtitle)
                                .font(.caption2)
                                .foregroundStyle(HUDColorPalette.tertiaryText)
                            Text(model.profileStatusText(profile))
                                .font(.caption2)
                                .foregroundStyle(HUDColorPalette.tertiaryText)
                        }
                        Spacer()
                        if profile.isManaged {
                            Button("登入") { model.startOfficialLogin(for: profile.id) }
                                .buttonStyle(.link)
                                .font(.caption2)
                                .disabled(model.loginStates[profile.id]?.hasPrefix("正在") == true)
                            Button(role: .destructive) {
                                profilePendingRemoval = profile
                                showRemoveProfileConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("刪除受管帳號")
                        }
                    }
                    if let state = model.loginStates[profile.id] {
                        Text(state)
                            .font(.caption2)
                            .foregroundStyle(state.contains("失敗") || state.contains("找不到") ? HUDColorPalette.warning : HUDColorPalette.secondaryText)
                            .padding(.leading, 26)
                    }
                    if profile.id != model.accountProfiles.last?.id {
                        Rectangle()
                            .fill(HUDColorPalette.divider)
                            .frame(height: 0.6)
                            .padding(.leading, 26)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        _ = model.createManagedProfile()
                    } label: {
                        Label("新增帳號", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        model.importProfileForCurrentAccount()
                    } label: {
                        Label("匯入 Codex profile", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("每個帳號使用獨立 CODEX_HOME 與 App Server；切換不會改動系統 ~/.codex。")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
        }
        .padding(9)
        .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    func disclosureSection<Content: View>(
        title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 6)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HUDColorPalette.primaryText)
        }
        .padding(9)
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
            Toggle("通知顯示 Turn 內容", isOn: Binding(
                get: { model.showTurnContentInNotifications },
                set: { model.setTurnContentInNotifications($0) }
            ))
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
                    Button("開啟系統設定") { openNotificationSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                } else if model.notificationAuthorizationStatus == .notDetermined {
                    Button("允許通知") { model.requestNotificationPermission() }
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
            Button("重設 HUD 位置") { resetHUDPosition() }
                .buttonStyle(.link)
                .font(.caption)
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
                    Text("正在檢查 GitHub 更新…")
                        .font(.body)
                        .foregroundStyle(HUDColorPalette.secondaryText)
                    Spacer()
                    Button("取消") { model.cancelUpdateCheck() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            case .upToDate:
                Text("目前已是最新版本。")
                    .font(.body)
                    .foregroundStyle(HUDColorPalette.continueAction)
            case .available(let release):
                updateReleaseDetails(release)
                Button("開啟 Release") { model.openUpdateReleasePage() }
                    .buttonStyle(.link)
                    .font(.subheadline)
            case .error(let message):
                Text(message)
                    .font(.body)
                    .foregroundStyle(HUDColorPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重試") { model.checkForUpdates() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                    Button("開啟 GitHub") { model.openUpdateReleasePage() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch model.updateState {
        case .checking:
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
            Button("Refresh") { model.refresh() }
            Button("Open Codex") { openCodex() }
            Spacer()
            Button("Quit") { quit() }
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
