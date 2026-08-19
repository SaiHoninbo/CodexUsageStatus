# Codex Usage Status 2.1 多帳號模式

這一版把 Codex Usage Status 擴充成 Cockpit-style 的多帳號狀態管理器。宿主仍然是本機 Codex App Server；每個受管帳號各自啟動一條 codex app-server --listen stdio:// 連線。

## 加入帳號

在 popover 的「帳號管理」中：

1. 按「新增帳號」建立受管 profile。
2. 按該 profile 的「登入」，啟動官方 codex login --device-auth。
3. 或按「匯入 Codex profile」，選取既有 profile 目錄或 auth.json。

登入與匯入資料只會放在該 profile 專屬的：

    ~/Library/Application Support/com.openai.codex-usage-status/accounts/<profile-id>/codex-home/

App 不會把 credentials 放進 app bundle、history、Token Activity、profile index 或 log。

## 切換與同步

- 「目前帳號」會切換選單列與詳細面板的 active profile。
- 「全部帳號」只作為 overview；quota 會逐帳號列出，不會相加。
- Token Activity 可按日期聚合。
- 每個帳號使用自己的 App Server 與 CODEX_HOME。
- 帳號背景同步預設每 5 分鐘，可在「同步設定」中調整；Quota、Token Activity 與帳號切換偵測也可分別設定。
- 同步並行數受限，避免大量帳號同時刷新造成認證衝突。

切換不會改動系統 ~/.codex，也不會重啟其他 profile 的 worker。現有 Codex／ChatGPT 工作流程不會被這個工具強制換帳號。

## 主 Codex App 外部切帳號

如果使用者是在主 Codex／ChatGPT App 內切換帳號，而不是在本工具的帳號管理器切換，背景工具也會同步：

- 只監看目前使用中的 `CODEX_HOME/auth.json` 檔案 metadata（修改時間、大小與 inode），不讀取 token 內容。
- 偵測到登入檔被更新、替換或重新建立時，先清除選單列上的舊 quota，暫時顯示 `Codex —`。
- 停止舊的 app-server，重新初始化同一個 `CODEX_HOME`，再依序讀取 account、rate limits 與 Token Activity。
- 新帳號的完整 snapshot 回來後，才恢復百分比、歷史與通知；舊帳號資料不會套到新帳號。
- 受管 profile 使用自己的隔離 `CODEX_HOME`；主 App 的 `~/.codex` 變更不會覆蓋受管 profile。

## 同步設定

popover 的「同步設定」可分別調整：

- Quota／Primary／Secondary：預設每 60 秒，可設定 30 秒至 60 分鐘。
- 目前帳號身份：預設每 5 分鐘，可設定 1 至 60 分鐘。
- Token Activity：預設每 15 分鐘，可設定 5 分鐘至 2 小時。
- 帳號切換偵測：預設每 15 秒，可設定 5 至 120 秒。

變更後會立即套用到目前的 App Server 排程；受管帳號會重新建立自己的 worker，避免舊排程仍在背景執行。打開 popover、App 重新取得焦點或按 `Refresh` 仍會立即同步，不受排程間隔影響。

## 安全界線

- Reset Credit 只在「目前帳號」模式可操作。
- 「全部帳號」模式不允許任何會改變帳號狀態的操作。
- 未識別登入模式會標示為「未識別帳號」，不會因 auth mode 相同而自動合併。
- raw Email 只存在目前記憶體中的 account health snapshot，不會寫入檔案。
- 刪除 profile 前會先停止該帳號 App Server，再刪除受管資料。

這是本機 ad-hoc signed App，首次啟動可能需要在 Finder 右鍵選「開啟」，或到「系統設定 → 隱私權與安全性」允許。
