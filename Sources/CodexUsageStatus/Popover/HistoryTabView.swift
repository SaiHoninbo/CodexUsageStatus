import Charts
import SwiftUI

/// History owns the complete historical surface: Token summary, daily buckets,
/// range controls, and local quota history. It is intentionally stable and
/// does not participate in HUD-only Token feedback animation.
extension UsagePopoverView {
    var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            tokenActivitySection
            Rectangle()
                .fill(HUDColorPalette.divider)
                .frame(height: 0.6)
            historySection
        }
        .padding(12)
        .background(HUDColorPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HUDColorPalette.border, lineWidth: 0.7) }
    }

    var tokenActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token 歷史摘要")
                    .font(.headline)
                Spacer()
                Text(model.tokenActivityState.displayName)
                    .font(.caption)
                    .foregroundStyle(model.tokenActivityState == .loaded ? HUDColorPalette.continueAction : HUDColorPalette.secondaryText)
            }
            if let activity = model.displayedTokenActivity {
                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        metric(TokenActivityPresentation.lifetimeLabel, tokenCount(activity.lifetimeTokens))
                        metric(TokenActivityPresentation.peakLabel, tokenCount(activity.peakDailyTokens))
                        metric(TokenActivityPresentation.longestTurnLabel, durationText(activity.longestRunningTurnSec))
                    }
                    Rectangle().fill(HUDColorPalette.divider).frame(height: 0.6)
                    HStack(spacing: 0) {
                        metric(TokenActivityPresentation.currentStreakLabel, daysText(activity.currentStreakDays))
                        metric(TokenActivityPresentation.longestStreakLabel, daysText(activity.longestStreakDays))
                    }
                }
                HStack {
                    Text("每日 token")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Picker("範圍", selection: $model.tokenActivityRange) {
                        ForEach(TokenActivityRange.allCases) { range in Text(range.title).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                let buckets = model.visibleTokenBuckets
                if buckets.isEmpty {
                    Text("目前沒有每日 token bucket")
                        .font(.caption)
                        .foregroundStyle(HUDColorPalette.tertiaryText)
                } else {
                    Chart(buckets) { bucket in
                        BarMark(
                            x: .value("日期", bucket.startDate),
                            y: .value("token", bucket.tokens)
                        )
                        .foregroundStyle(HUDColorPalette.token.gradient)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 130)
                }
                Text("最後抓取：\(model.tokenActivityFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")\(model.tokenActivityIsStale ? " · 資料較舊" : "")")
                    .font(.caption2)
                    .foregroundStyle(model.tokenActivityIsStale ? HUDColorPalette.warning : HUDColorPalette.secondaryText)
            } else {
                Text(model.tokenActivityErrorMessage ?? "尚未取得 Token Activity。按 Refresh 讀取。")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.secondaryText)
            }
            if let error = model.tokenActivityErrorMessage, model.tokenActivity != nil {
                Text(error).font(.caption2).foregroundStyle(HUDColorPalette.warning)
            }
            if model.tokenActivityState == .loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在更新 Token Activity…").font(.caption)
                }
            } else {
                Button("Refresh Token Activity") { model.refreshTokenActivity() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(HUDColorPalette.tertiaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func tokenCount(_ value: Int64?) -> String {
        TokenActivityPresentation.tokenCount(value)
    }

    private func daysText(_ value: Int64?) -> String {
        TokenActivityPresentation.daysText(value)
    }

    var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("用量歷史")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("範圍", selection: $model.historyRange) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            let samples = model.visibleHistorySamples()
            let resetDates = Array(Set(samples.flatMap { sample in
                [sample.primaryResetsAt, sample.secondaryResetsAt]
            }.compactMap { timestamp in
                timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            })).sorted()
            if samples.contains(where: { $0.connectionState == .connected && ($0.primaryUsedPercent != nil || $0.secondaryUsedPercent != nil) }) {
                Chart {
                    ForEach(samples) { sample in
                        if sample.connectionState == .connected, let used = sample.primaryUsedPercent {
                            LineMark(
                                x: .value("時間", sample.receivedAt),
                                y: .value("已用", min(100, max(0, used)))
                            )
                            .foregroundStyle(by: .value("窗口", "Primary"))
                        }
                        if sample.connectionState == .connected, let used = sample.secondaryUsedPercent {
                            LineMark(
                                x: .value("時間", sample.receivedAt),
                                y: .value("已用", min(100, max(0, used)))
                            )
                            .foregroundStyle(by: .value("窗口", "Secondary"))
                        }
                    }
                    ForEach(resetDates, id: \.self) { resetDate in
                        RuleMark(x: .value("重置", resetDate))
                            .foregroundStyle(HUDColorPalette.sevenDay.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }
                    ForEach(model.notificationThresholds, id: \.self) { threshold in
                        RuleMark(y: .value("剩餘 \(threshold)%", 100 - threshold))
                            .foregroundStyle(HUDColorPalette.warning.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartForegroundStyleScale([
                    "Primary": HUDColorPalette.fiveHour,
                    "Secondary": HUDColorPalette.sevenDay
                ])
                .frame(height: 160)
                Text("圖表顯示已用百分比；灰色／離線區段不納入即時提醒。")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            } else {
                Text("尚未累積足夠的歷史資料")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("本機保存最近 30 天")
                    .font(.caption)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
                Spacer()
                Button("清除歷史", role: .destructive) {
                    showClearHistoryConfirmation = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let error = model.historyErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.warning)
            }
            if model.accountScope == .all {
                Text("此區塊仍顯示目前帳號歷史；全部帳號的聚合摘要與每日 token 請查看本頁的帳號歷史摘要。")
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.tertiaryText)
            }
            if let error = model.profileStoreErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(HUDColorPalette.warning)
            }
        }
    }
}
