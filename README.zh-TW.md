# Codex Usage Status

**繁體中文** · [English](README.md)

Codex Usage Status 是 macOS 選單列用量 HUD，用來監控本機 Codex App Server 回報的配額。它會在你使用 Codex 時持續顯示用量摘要，不修改 Codex 主視窗，也不呼叫私有網路端點。

## 下載

請從 GitHub Releases 下載最新的已簽章 App：

<https://github.com/SaiHoninbo/CodexUsageStatus/releases/latest>

最新版安裝檔直連：

<https://github.com/SaiHoninbo/CodexUsageStatus/releases/latest/download/CodexUsageStatus.app.zip>

請不要下載 repository 的 source archive 來安裝。Source archive 不是可直接執行的 macOS App。

## 系統需求

- macOS 14.0 或更新版本
- Apple Silicon Mac（目前發布的 App 是 arm64 版本）
- 本機可啟動 Codex／ChatGPT App Server，並支援：

  ```text
  codex app-server --listen stdio://
  ```

## 安裝

1. 從 Releases 頁面下載 `CodexUsageStatus.app.zip`。
2. 雙擊 ZIP，解壓出 `CodexUsageStatus.app`。
3. 將 App 移到 `/Applications`。
4. 第一次啟動時，對 `CodexUsageStatus.app` 按右鍵並選擇「打開」。
5. 如果 macOS 阻擋啟動，開啟「系統設定 → 隱私權與安全性」，在安全性提示中選擇「仍要打開」。
6. 啟動 Codex Usage Status；它會出現在選單列，也可以在 Codex 旁顯示浮動 HUD。

目前 App 使用 ad-hoc signing，尚未經 Apple notarization，因此第一次啟動可能需要右鍵「打開」。建議固定放在 `/Applications`，讓登入啟動註冊使用穩定的 App 路徑。

## 權限

大部分監控功能不需要「輔助使用」權限。只有使用 HUD 的剪貼簿控制時才需要開啟：

- **貼上剪貼簿**：對前景 Codex 視窗送出 `⌘V`。
- **貼上並送出**：送出 `⌘V`，等待內容貼上完成後，再送出一次 Return／Enter。

請到「系統設定 → 隱私權與安全性 → 輔助使用」，啟用 `CodexUsageStatus.app`。如果你更換或重新解壓 App，macOS 可能會建立新的權限項目；請移除舊路徑，並啟用目前正在執行的 App。

通知權限是選用的。即使拒絕通知，用量與 Token Activity 仍會正常運作。

## 顯示內容

- Primary／secondary 剩餘配額百分比
- 重置倒數與 stale／offline 狀態
- 低用量通知與選單列顏色狀態
- Token Activity 摘要與每日 token buckets
- 最近 30 天的本機 quota／token 歷史
- 帳號健康狀態與受管多帳號 profile
- 各帳號獨立 quota 與 Token Activity 總覽
- 跨螢幕跟隨 Codex 視窗的 HUD 位置
- 「只貼上」與「貼上並送出」按鈕
- HUD 任意位置按右鍵可開啟原生操作選單（重新整理、帳號範圍、更新頻率、剪貼簿、更新檢查與位置重設）
- GitHub Releases 更新檢查

選單列主文字固定以目前作用中帳號的 quota 為主，例如 `Codex 78%`。Token Activity 與 reset credit 詳情會留在 popover，不會取代最重要的 quota 摘要。

## 帳號與隱私邊界

App 透過 stdio 介面連接本機 Codex App Server，不使用私有網路端點、不注入 Codex UI，也不管理 API key。

- 公開 repository、Release ZIP、history、Token Activity、profile index 與 log 都不會包含 ChatGPT credential 或 token。受管 profile 可能會把 `auth.json` 保存在使用者本人可讀寫的 Application Support 專屬 `CODEX_HOME`，讓本機 App Server 執行；這些資料不會上傳、打包、提交或複製到公開 Release。
- Prompt、對話文字、thread title 與 App Server 原始認證資料不會寫入歷史檔案。
- 本機歷史、Token Activity 與受管帳號認證資料保存在使用者的 Application Support 目錄，檔案權限限制為使用者本人可讀寫。
- 受管 profile 使用獨立的 `CODEX_HOME` 與獨立 App Server process。
- 系統 `~/.codex` profile 不會被複製進 App bundle 或 Release ZIP。

## 更新

App 啟動時以及執行期間會定期檢查 GitHub 的 `latest release`。發現新版本時：

1. Popover 顯示更新狀態，並可能對該版本顯示一次通知。
2. 由使用者按下「下載更新」。
3. ZIP 下載到使用者的 Application Support updates 目錄。
4. 如果 GitHub 提供 digest，App 會驗證 ZIP checksum；解壓後也會執行 strict code-signature verification。
5. 使用者按下「安裝並重新啟動」後，背景安裝器會等待目前 process 結束，再重新驗證、替換目前 App 路徑並重新啟動。

Updater 不會把認證資料或使用者資料送到 GitHub，也不會碰 Codex auth/history 目錄。如果替換失敗，會嘗試還原原本的 App bundle。

### 維護者發布規則

Updater 預期 GitHub Release 具備：

- Semantic-version tag，例如 `v2.4.27`
- 名稱完全一致的 asset：`CodexUsageStatus.app.zip`
- ZIP 內包含已簽章的 App bundle
- 不包含 `._*`、`__MACOSX`、source、tests、auth、token 或 history 檔案

目前 `2.4.27 / build 47` 安裝包的已驗證 SHA-256：

```text
7c4df8003615c7116d218cce635f417d755e632942eb56b789a28e356e20b6fb
```

如果 GitHub 尚未建立正式 Release，Updater 會正確顯示目前沒有可用的正式版本；只把 ZIP 提交到 `main` 並不會自動建立 Release 更新。

## 從原始碼建置

請使用你自行 clone 的 repository 根目錄。以下指令都以 repository 根目錄為相對路徑，
不依賴特定電腦上的使用者名稱或資料夾。

```text
<repository-root>
```

使用 Swift Package Manager 建置 macOS executable：

```bash
swift build --disable-sandbox -c release
```

若要產生公開或可分發的安裝包，請改用打包腳本。腳本會移除可能包含本機建置路徑的 release debug 資訊：

```bash
./script/build_and_run.sh package
```

打包腳本會建立 ad-hoc signed App、驗證 bundle，並將唯一正式產出寫入：

```text
outputs/CodexUsageStatus.app.zip
```

執行核心測試：

```bash
./script/run_core_tests.sh
```

## 疑難排解

### 看不到 HUD

確認 Codex 正在執行，而且本機 App Server 可以啟動。透過選單列項目開啟 popover，按下「Refresh」。只有 App 能辨識 Codex 視窗時，HUD 才會跟隨該視窗。

### 剪貼簿貼上一直要求權限

確認目前真正執行的 `CodexUsageStatus.app` 已在「輔助使用」清單中啟用。如果你替換過 App，請重新啟用新的路徑，然後重開 App 再按貼上按鈕。

### 更新檢查顯示沒有正式版本

維護者必須先建立 GitHub Release，而且 Release 必須包含名稱完全一致的 `CodexUsageStatus.app.zip`。Commit 或 source ZIP 都不算正式 Release。

### macOS 顯示無法打開 App

先對 App 按右鍵選「打開」。如果仍被阻擋，前往「系統設定 → 隱私權與安全性 → 仍要打開」。

## 授權

本專案採用 MIT License，詳見 [LICENSE](LICENSE)。

安全與隱私邊界請參考 [SECURITY.md](SECURITY.md)。
## 外部重置公告

App 可選擇追蹤使用者提供的 RSS／Atom Feed，將可能的重置時間以「僅供參考」
公告顯示在 HUD 與「公告」分頁。用量與正式重置時間仍完全以 App Server 為準，
Feed 推測不會覆寫 `UsageSnapshot` 或用量歷史；功能預設關閉，可手動或定期更新。

本 App 不使用 X API、不讀取瀏覽器 Cookie，也不建立或管理 X token。完整 HTTPS
Feed URL 會保存在 owner-only Application Support；若供應商將 credential 放在 URL
query 中，該值會隨 URL 保存，但不會寫入 log、通知、錯誤訊息或 analytics。
