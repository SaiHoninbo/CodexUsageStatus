# Codex Usage Status

**繁體中文** · [English](README.md)

Codex Usage Status 是 macOS 選單列用量 HUD，用來監控本機 Codex App Server 回報的配額。它會在你使用 Codex 時持續顯示用量摘要，不修改 Codex 主視窗，也不呼叫私有網路端點。

## 下載

請從 GitHub Releases 下載最新的 ad-hoc 簽章 App：

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

正式發布 artifact 使用 GitHub Release 的 ad-hoc 簽章流程，不需要外部發佈憑證。
建議固定放在 `/Applications`，讓登入啟動註冊使用穩定的 App 路徑。

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
- 可選的 Repo／Chat 計畫進度通知（25%、50%、75% 里程碑；只代表計畫比例，不含 ETA 或步驟文字）

Popover 固定收斂為四個分頁：「概覽」顯示目前配額與快速操作；「歷史」顯示
quota 與 Token Activity 趨勢；「帳號」負責完整 profile 管理與各帳號本機活動；
「設定」集中全域 HUD、通知、同步與更新。App 不執行直接 Git client，也不再輪詢
第三方 Feed。

選單列主文字固定以目前作用中帳號的 quota 為主，例如 `Codex 78%`。Token Activity 與 reset credit 詳情會留在 popover，不會取代最重要的 quota 摘要。

### Desktop Turn 活動

概覽頁的 Turn 卡片以已知 `CODEX_HOME` 下 Codex Desktop 的本機
rollout／session JSONL 為唯一活動來源。它只觀察開始、目前 turn token、完成、
失敗與中斷等生命週期 metadata；App Server 的私有 Turn callback 仍保留作為
傳輸，但不再與這條可見時間線競爭。觀察器是唯讀的，既有檔案從目前檔尾開始，
也不會建立第二個 Codex process。

這條路徑採 metadata-first：不讀取或保存 prompt、對話文字、agent message
或 rollout 原始內容。為了讓完成通知指出是哪個程序／工作，App 只會唯讀讀取
本機 `session_index.jsonl` 裡對應 thread 的名稱；UsageStatus 不會保存這個名稱。
在安全內容能力存在前，Turn 通知內容選項仍會停用。Quota、帳號身份、Reset
Credit 與其他 App Server 資料仍由本機 App Server 傳輸提供。

## 帳號與隱私邊界

App 透過 stdio 介面連接本機 Codex App Server，不使用私有網路端點、不注入 Codex UI，也不管理 API key。

- 公開 repository、Release ZIP、history、Token Activity、profile index 與 log 都不會包含 ChatGPT credential 或 token。受管 profile 可能會把 `auth.json` 保存在使用者本人可讀寫的 Application Support 專屬 `CODEX_HOME`，讓本機 App Server 執行；這些資料不會上傳、打包、提交或複製到公開 Release。
- Prompt、對話文字、thread title 與 App Server 原始認證資料不會寫入歷史檔案。
- Rollout／session 觀察是唯讀且只含 metadata；只記錄目前 Turn 卡片與本機
  ledger 所需的生命週期識別、時間戳、耗時與 turn-local token 總量。
- 本機歷史、Token Activity 與受管帳號認證資料保存在使用者的 Application Support 目錄，檔案權限限制為使用者本人可讀寫。
- 受管 profile 使用獨立的 `CODEX_HOME` 與獨立 App Server process。
- 系統 `~/.codex` profile 不會被複製進 App bundle 或 Release ZIP。

## 更新

App 啟動時以及執行期間會定期檢查 GitHub 的 `latest release`。發現新版本時：

1. Popover 顯示更新狀態，並可能對該版本顯示一次通知。
2. 使用者按下「下載並覆蓋」後，App 會從官方 GitHub Release 下載固定的
   `CodexUsageStatus.app.zip`，驗證 bundle、版本與 code signature，再關閉舊版、覆蓋並重新啟動新版。
   「查看 Release」仍保留為手動更新 fallback。

只有固定的本 repository GitHub Release asset、相容 bundle identifier、更新版本
與有效 code signature 才會被接受；非官方 URL、危險 archive path 或不相容 App
會拒絕更新。

### 維護者發布規則

維護者發布 GitHub Release 時應具備：

- Semantic-version tag，例如 `v2.4.27`
- 名稱完全一致的 asset：`CodexUsageStatus.app.zip`
- ZIP 內包含已簽章的 App bundle
- 不包含 `._*`、`__MACOSX`、source、tests、auth、token 或 history 檔案

每個正式 artifact 的 checksum 與 ad-hoc signing mode 應記錄在 Release notes 或維護 evidence。只把 ZIP 提交到 `main` 並不會自動建立 App 內的 Release 更新。

上傳 ZIP 前，必須驗證最後要發布的那一份 artifact。驗證器會 fail closed，
只有在 archive 只包含預期 App、使用 ad-hoc code signature、bundle identifier
與 semantic version 正確，並通過 strict bundle verification 時才允許通過：

```bash
./script/validate_release_artifact.sh outputs/CodexUsageStatus.app.zip 2.4.88
```

ZIP 必須先通過這個 validator，才能上傳 GitHub Release。

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

若要產生本機 canonical package archive，請使用打包腳本。腳本會移除可能包含本機建置路徑的 release debug 資訊：

```bash
./script/build_and_run.sh package
```

打包腳本會建立 ad-hoc signed App、驗證 bundle，並將唯一的 repository
canonical artifact 寫入：

```text
outputs/CodexUsageStatus.app.zip
```

`package` mode 會建立可直接提供 GitHub Release 使用的 canonical ad-hoc
signed artifact。將產出的 ZIP 發布到 GitHub Release，仍是維護者另外明確
執行的動作。GitHub Releases 是唯一發布通道。

若要產生一次性的 runtime 或 UI 驗證版本，請使用 `candidate` mode：

```bash
./script/build_and_run.sh candidate
```

`candidate` 會在 `/private/tmp` 下建立暫存 App bundle、執行 ad-hoc signing
與簽章驗證、印出確切的 `.app` 路徑，但不會自動啟動 App。它永遠不會寫入
`outputs/CodexUsageStatus.app.zip`；該 repository canonical artifact 只有明確執行
`package` mode 才會產生。Candidate 不是 release artifact，驗證完成後即可移除。

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

維護者必須先建立 GitHub Release，並提供名稱完全一致的 `CodexUsageStatus.app.zip`；App 只會從固定的官方 asset 下載並驗證更新。Commit 或 source ZIP 都不算正式 Release。

### macOS 顯示無法打開 App

先對 App 按右鍵選「打開」。如果仍被阻擋，前往「系統設定 → 隱私權與安全性 → 仍要打開」。

## 授權

本專案採用 MIT License，詳見 [LICENSE](LICENSE)。

安全與隱私邊界請參考 [SECURITY.md](SECURITY.md)。
