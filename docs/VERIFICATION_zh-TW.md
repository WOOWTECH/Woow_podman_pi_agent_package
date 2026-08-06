# 驗收紀錄

[English](VERIFICATION.md) · **繁體中文**

這套部署實際做到了什麼。時間 2026-08-06，rootless Podman 主機。下面的數字來自實測，不是來自設計文件；沒量到的都有註明。

| | |
|---|---|
| 主機 | rootless Podman，區網發佈於 `:30142` |
| 映像 | `ghcr.io/woowtech/woow-podman-pi-agent:latest`，以 `--format=docker` 建置 |
| 元件 | pi-web 0.8.4 · pi-coding-agent 0.83.0 · Node v22.23.2 · Next.js 16.2.12 |
| 供應商 | OpenRouter — discover 到 340 個模型 |
| 測試模型 | `deepseek/deepseek-v4-flash`（選便宜的；所有判準都取自工具執行結果，不取自模型的叙述） |
| 結構面測試 | **25 項通過、0 項失敗、2 項註記** |

---

## 1. 結構面檢查

`tests/acceptance.sh`，以普通 `podman exec` 執行——刻意**不加** `bash -l`，因為把環境變數烘進 image 的目的，就是讓非 login shell 也落在跟伺服器相同的環境。

| 分組 | 驗證什麼 | 結果 |
|---|---|---|
| 執行環境 | `pi` 在 PATH 上 | 0.83.0 |
| | 非 login shell 中 `HOME` 釘在 volume | `/data/pi-agent/home` |
| | 不經 profile.d 也有 `PI_CODING_AGENT_DIR` | 已設定 |
| | 時區已套用 | CST |
| 持久化 | `sessions/`、`skills/`、`home/` | 全部存在 |
| | skills 橋接是指向 volume 的 symlink | `$HOME/.pi/agent/skills → /data/pi-agent/skills` |
| | `models.json` / `auth.json` 權限 | 600 |
| HTTP | `/api/home`、`/api/models`、`/api/skills`、`/api/plugins` | 200 × 4 |
| | 供應商已設定 | openrouter |
| 中文路徑 | U+3000 檔名讀到自己的內容 | 正確 |
| | 兩種空白字元版本並存為不同檔案 | 2 個檔 |
| 影片工具 | sentinel、venv 可用、ffmpeg、Playwright cache | 存在 · 656 MB cache · Chromium 151 |
| 信任守衛 | 帶 hostname 的 `Host`+`Origin` **經過** nginx | 200 |
| | 相同標頭**直接**打 pi-web | 403 |

那兩項註記是第 5 節的常態暴露。它們每次執行都會印出來，而不是歸檔一次就算——只寫在文件裡的安全性質等於沒人再檢查。

---

## 2. 對話測試

六輪，全部走 pi-web 自己的 HTTP API——跟瀏覽器呼叫的是同一組端點，所以通過代表真實路徑可行。所有判定取自 `tool_execution_end` 結果與磁碟狀態，沒有一項取自助理的總結：模型說「我已成功建立檔案」不構成證據。

| # | 測什麼 | 工具呼叫 | 耗時 | Token | 判定 |
|---|---|---|---|---|---|
| 1 | write → read → bash 完整迴圈 | 3 | 25.1 秒 | 2,400 | 檔案落地 17 bytes，內容精確 |
| 2 | 技能觸發 | 4 | 31.2 秒 | 2,594 | 讀 SKILL.md → 執行 `date` → 寫出檔案 → 回傳兩個標記 token |
| 3 | **反向對照** | 1 | 14.2 秒 | 1,856 | 無關提問**未**觸發技能 |
| 4 | 用 agent 自己的工具讀寫中文檔名 | 4 | 24.1 秒 | 2,408 | U+3000 檔 17 B、U+0020 檔 11 B，各自讀回自己的內容 |
| 5 | 手動走 MCP over HTTP | 7 | 112.2 秒 | 20,490 | 見下方 |
| 6 | 外掛提供的技能 | 1 | 24.1 秒 | 1,940 | 套件內的技能被讀取並執行 |

第 3 輪跟第 2 輪一樣重要。什麼都觸發的技能不是能用的技能，而只測「有觸發」的測試分辨不出這兩者。

### MCP over HTTP

pi 0.83.0 沒有內建 MCP client，所以直接要求 agent 用 `bash` 加 `curl` 自己走完協定。它獨力完成了整個握手：

1. `initialize` → HTTP 200，從回應標頭取出 `mcp-session-id: 7a9643f7…`
2. `notifications/initialized` → HTTP 202
3. `tools/list` → SSE 回應，自行剥掉 `data:` 前綴，列出 **38 個 tool**
4. `tools/call health_check` → `Odoo MCP Server 1.28.1`，38 tools / 4 resources / 11 prompts
5. 把整個過程寫成 3,930 bytes 的報告放進工作目錄

這件事能在沒有 client library 的情況下成功，值得說白：這裡的 MCP 是**模型**的能力，不是執行環境的能力。它有多可靠，就跟模型有多可靠一樣，這跟內建 client 是不同的風險型態。

### 檔案與文件介面

不經模型直接驗證：`/api/file-index` 把兩種 Unicode 空白版本列為兩筆；`/api/files?type=list`、`?type=read`、`?type=download` 兩個檔案都回傳正確內容與位元組數。

發現一個上游的外觀缺陷：`?type=list` 對每一筆都回傳 `size: 0` 與空的 `modified`，包括明顯非空的檔案。僅影響顯示，讀取與下載的資料是對的。

### 持久性

容器重啟後：9 個 session 檔、2 個技能（一個使用者、一個來自套件）、外掛仍為 `loaded`、供應商金鑰與 3 個已設定模型完好、所有工作檔案都在。沒有任何一項需要手動重建。

---

## 3. k3s ↔ Podman 逐項對照

兩套部署用同一套測試、同一順序量測，因此差異可以被归因為移植缺陷，而不是量測方式不同。

| 項目 | k3s | Podman | 註 |
|---|---|---|---|
| `pi` 在 PATH | 通過 | 通過 | 同一個啟動器 |
| 用 UI 設定模型 | 通過 | 通過 | 金鑰存在 volume，不在 unit 檔 |
| 技能觸發 + 反向對照 | 通過 | 通過 | |
| Skills 橋接 | 通過 | 通過 | |
| 外掛安裝 → UI → 對話 | 通過 | 通過 | |
| 中文路徑處理 | 通過 | 通過 | 同一份修補，建置時與執行時各驗一次 |
| 檔案顯示 / 讀取 / 下載 | 通過 | 通過 | |
| 重啟後的儲存持久性 | 通過 | 通過 | PVC vs 具名 volume |
| MCP over HTTP | 通過 | 通過 | 兩邊都是 agent 驅動 |
| 影片工具鏈 | 通過 | 通過 | 656 MB cache、Chromium 151 |
| Shell 存取 | ttyd sidecar，對外發佈且無驗證 | `podman exec` | Podman 較佳——少一個暴露面 |
| 權限 | 節點上的真 root | rootless，容器 root → 主機 uid 1000 | Podman 較佳 |
| 健康回報 | 3 種 Kubernetes probe | 一個 `HEALTHCHECK`，顯示於 `podman ps` | 等效且更簡單 |
| 入口限制 | `NetworkPolicy` 限 30141/30142/7681 | pi-web 根本不發佈連接埠 | 等效 |
| 多節點排程 | 有 | 無 | 僅 k3s；本場景未使用 |

功能面完全對齊。Podman 版在權限與攻擊面上領先；k3s 版領先的那一項，這個工作負載用不到。

---

## 4. 找到並修正的缺陷

五個全部是跑出來的，不是讀出來的。沒有一個在 review 階段看得出來。

| # | 缺陷 | 為什麼重要 |
|---|---|---|
| 1 | `HOME` 只對 login shell 生效 | `podman exec -it pi-web bash`——README 原本寫的那行——拿到的是 `HOME=/root`。從那個 shell `pi install` 會寫進暫存層，UI 則讀 volume：安裝回報成功，技能永遠不出現。正是 skills 橋接要防的那個失敗。現已烘進 image ENV 並加上 `BASH_ENV`。 |
| 2 | `models.json` 在含金鑰期間是 0644 | entrypoint 只在開機 chmod，但每次在 Models 頁存檔 pi-web 都用 0644 重建。實測：設完供應商後是 644，重啟後才變回 600——它含有金鑰的整段期間都是可讀的。以 `umask 077` 修正。 |
| 3 | Quadlet 會去 pull 只存在於本機的 image | 對一個從未推過的 tag 設 `AutoUpdate=registry` 只是純粋的失敗面。已改 `Pull=never` + `AutoUpdate=local`。 |
| 4 | **測試工具自己製造出一個 bug** | 工具結果按抵達順序配對，但 agent 是平行發工具呼叫的。紀錄上顯示 `read "台灣 報告.txt"` 回傳另一個檔的內容——正是這個 image 所修補的上游 cross-read 的特徵。磁碟狀態證明兩個檔都是對的。現已改用 `toolCallId` 配對。一個會製造出自己要檢測的那個失敗的測試，比沒有測試更糟。 |
| 5 | 影片 bootstrap 無法自愈 | 所有判斷式都測 `bin/python3`，但 ensurepip 失敗的 venv 仍然有它，只缺 `bin/pip`。建立被跳過、下一行呼叫不存在的 pip、失敗路徑 `exit 0`、sentinel 永遠不寫，每次開機重複一模一樣的序列。現改以 `bin/pip` 判定，且無效的 venv 會先刪除再重建。 |

第 4 項的影響超出本倉庫：k3s 那輪用的是同一份配對邏輯，所以那輪凡是從平行工具批次得出的結論，應以磁碟狀態重讀，而不是以紀錄為準。

---

## 5. 尚未解決的暴露

沒修，因為打包端修不掉。列出來是為了讓它們被決定，而不是被發現。

**供應商金鑰可被任何連得到連接埠的人讀走。** 實測確認，不是推論：經發佈的連接埠發一個不帶憑證的 `GET /api/models-config`，回傳 `"apiKey":"sk-or-v1-…"` 明文。本套件的緩解措施——pi-web 不發佈自己的連接埠、磁碟上 600——只縮小了這個端點能**從哪裡**被觸及，擋不住已經連到 `:30142` 的人。

**任何位置都沒有身分驗證。** 30142 埠等同直接發放 shell。超出可信任區網就必須在前面放一層有驗證的 proxy，或把 `PublishPort` 綁到 `127.0.0.1`。

**Agent 沒有路徑限制、沒有核可關卡、也沒有 `canUseTool` hook。** 它可以讀寫容器使用者能觸及的任何位置，執行任何指令。Rootless 把爆炸半徑限縮到一個非特權主機帳號，但不會在那個帳號內部產生邊界。

**MCP 依賴模型。** 沒有原生 client，協定正確性每一次都是模型的責任。有能力的模型可以獨力完成，弱一點的不一定，而且失敗時看起來會像是「回答很差」而不是「連線錯誤」。

---

## 重跑方式

```bash
podman cp tests/. pi-web:/opt/tests/
podman exec pi-web bash /opt/tests/acceptance.sh          # 結構面，零成本

printf '建立 notes.md，內容為一行 hello。\n' > /tmp/p.txt
podman cp /tmp/p.txt pi-web:/tmp/p.txt
podman exec pi-web node /opt/tests/chat.mjs /tmp/p.txt --json /tmp/out.json
```

結構面測試不花錢，每次重建映像後都應該跑。對話測試要花 token，在映像、pi-web 版本或供應商改變時跑。
