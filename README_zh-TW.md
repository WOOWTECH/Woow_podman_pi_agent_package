# Woow Podman Pi Agent

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![pi-web](https://img.shields.io/badge/pi--web-0.8.4-blue)](https://www.npmjs.com/package/@agegr/pi-web)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

把 `@agegr/pi-web` 與 `pi` coding agent 打包成在 **rootless Podman** 上執行、由 **systemd（Quadlet）** 監管的服務。它是 [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) 的 Podman 版本——相同的應用層，為單機容器執行環境重新建置。

> **本套件只出 pi-web。身分驗證與 Host/Origin 轉寫都交給區網共用 nginx（Nginx Proxy Manager 或同機 nginx）處理。** 契約細節在 [docs/downstream-nginx.md](docs/downstream-nginx.md)：兩個必設的 header，以及必須開的驗證機制。兩者少一個，不是 UI 全部 auth-gated route 回 403，就是供應商 API 金鑰可以被明文抓走。

---

## 提供什麼

| | |
|---|---|
| **Loopback 端點** | Podman 主機上的 `http://127.0.0.1:30141` — 沒有驗證，只給同機 reverse proxy 使用 |
| **Agent** | `@earendil-works/pi-coding-agent` 0.83.0，由 pi-web 以函式庫方式載入（沒有獨立 daemon） |
| **CLI** | 容器內 `PATH` 上有 `pi` — `podman exec -it pi-web pi` 即可操作 TUI |
| **持久化** | 單一具名 volume `pi-agent-data`，存放 sessions、skills、設定與 `$HOME` |
| **影片工具鏈** | ffmpeg、Playwright-Chromium、edge-tts、rclone、Noto CJK 字型（建置時可選） |
| **監管** | Quadlet 產生的 `systemd --user` unit，啟用 lingering，登出/重開機後仍運行 |

---

## 為什麼這不是「把 k3s 映像的 Kubernetes 部分刪掉」

兩套部署跑的是相同的 npm 套件，但執行環境不同，打包決策就不同。每一項都是刻意差異：

| k3s 版本 | Podman 版本 | 原因 |
|---|---|---|
| `ttyd` sidecar + 密碼 Secret | *（移除）* | Podman 上 `podman exec -it pi-web bash` 就是原生做法。 |
| 映像內含 `kubectl`、`s6-overlay`、`bashio` | *（移除）* | systemd 監管，不需第二套 init。 |
| 三種 Kubernetes probe | 一個原生 `HEALTHCHECK` | Podman 原生支援，顯示在 `podman ps`。 |
| 以節點上真正的 `root` 執行 | rootless — 容器內 `root` 對應到主機 uid 1000 | 逃逸落到一般使用者而不是 root。 |
| Helm chart、`NetworkPolicy`、PVC | Quadlet `.container` / `.network` / `.volume` | 原生 unit，`systemctl --user` 直接讀得到。 |
| Cloudflare Tunnel sidecar | *（移除）* | 主機本來就有共用 tunnel 容器。 |
| **Host/Origin + 驗證用的 nginx sidecar** | ***（移除——交給主機共用 reverse proxy）*** | 這台 Podman 主機本來就有 nginx / NPM 在服務其他站台，本套件再包一個等於重複那層、再多維護一組帳號密碼。契約見 [docs/downstream-nginx.md](docs/downstream-nginx.md)。 |

**刻意保持完全一致**：`pi` 啟動器包裝、CJK 路徑修補、skills 路徑橋接、`HOME` 釘在 volume 的配置、驗收測試套件。這些是應用層修正，兩套部署之間不能漂移。

---

## 安裝

需要 Podman ≥ 4.4（Quadlet）、rootless、以擁有 Podman storage 的帳號執行。

```bash
git clone https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git
cd Woow_podman_pi_agent_package

# --format=docker 是必須的。SHELL 與 HEALTHCHECK 在 OCI 格式沒有對應欄位，
# 預設格式建出來的映像不會回報健康狀態，podman ps 的 STATUS 是空的。
podman build --format=docker \
  -t localhost/woow-podman-pi-agent-host:latest -f Containerfile.host-control .

# 安裝 unit 並啟動。不要 sudo — rootless 就是設計。
./scripts/install.sh
```

`install.sh` 會拒絕以 root 執行、確認 Quadlet generator 存在、啟用 `loginctl` lingering，將三個 unit（`pi-agent.network`、`pi-agent-data.volume`、`pi-web.container`）與兩個健康檢查 unit 分別放到 `~/.config/containers/systemd/` 與 `~/.config/systemd/user/`，然後等待容器回報 `healthy`。**不會**幫你設 reverse proxy——那步驟看 [docs/downstream-nginx.md](docs/downstream-nginx.md)。

全新 volume 首次啟動，背景會下載約 720MB 影片工具。**UI 全程可用**——下載不擋啟動。

### 精簡版建置

`--build-arg VIDEO_TOOLS=0` 給你約 700MB、沒有 ffmpeg / Chromium / CJK 字型 / rclone 的映像。**同時把 `quadlet/pi-web.container` 的 `VIDEO_PIPELINE_ENABLED` 設為 `false`**，不然 entrypoint 會一直去呼叫在該映像上不可能成功的 bootstrap。

### 移除

```bash
./scripts/uninstall.sh           # 停止並移除 unit，保留資料 volume
./scripts/uninstall.sh --purge   # 連 pi-agent-data 一起刪除
```

下游 proxy 的 Proxy Host / server 區塊要自己清。

---

## 首次使用

1. 把同機 nginx / NPM 指到 `127.0.0.1:30141`，加上 [docs/downstream-nginx.md](docs/downstream-nginx.md) 裡的兩行 `proxy_set_header`，並在該 proxy 上開驗證。
2. 用 proxy 對外的 hostname 開 UI。
3. 進 **Models** 頁，新增供應商並貼 API key。金鑰以 `600` 權限寫入 volume 上的 `models.json`。
4. 開始對話。Agent 的工作目錄必須是*允許的根目錄*：既有 session 的 cwd，或 `$HOME/pi-cwd-YYYYMMDD`。

供應商透過 UI 而不是環境變數設定是刻意的：金鑰放在 volume 上，輪替不必改 unit。

---

## 目錄結構

```
Containerfile              debian:bookworm-slim + Node 22 + pi-web，含建置時斷言
Containerfile.host-control OpenClaw 主機用的映像（build 為 localhost/woow-podman-pi-agent-host:latest）
quadlet/
  pi-agent.network         私有橋接網路，aardvark-dns 負責容器名稱解析
  pi-agent-data.volume     單一具名 volume
  pi-web.container         Agent 本體；發佈 127.0.0.1:30141 給同機 reverse proxy
systemd/
  pi-web-health.service    oneshot：podman healthcheck run pi-web
  pi-web-health.timer      每 30s 觸發
patches/
  fix-unicode-space-paths.mjs   CJK 路徑修補，逐段斷言
rootfs/usr/local/bin/
  pi                       啟動器 — 解析以相依方式安裝的 CLI
  pi-agent-env.sh          執行環境的唯一定義來源
  pi-web-start.sh          進入點：umask、權限、skills 橋接、時區、影片工具啟動
  video-tools-init.sh      sentinel 守衛、可自愈的首次安裝
scripts/install.sh         rootless 安裝腳本（不設 auth，不設 proxy）
scripts/uninstall.sh       移除，預設保留 volume
tests/acceptance.sh        不需 LLM 的驗收測試
tests/chat.mjs             對話測試工具 — 走 pi-web 自己的 API
tests/host-profile.sh      OpenClaw host-profile 形狀的靜態斷言
docs/ARCHITECTURE.md       架構圖與每個決策的理由
docs/downstream-nginx.md   同機 reverse proxy 必須滿足的契約
docs/plans/                塑造本套件形狀的每次重構之設計筆記
```

---

## 驗收部署

兩套測試，便宜的先跑。`tests/` 沒有包進映像，要先拷貝進去。

```bash
# 1. 結構面 — 不呼叫模型、零成本。檢查執行環境、持久化配置、HTTP 介面、
#    CJK 回歸測試、影片工具鏈與信任守衛。
podman cp tests/. pi-web:/opt/tests/
podman exec pi-web bash /opt/tests/acceptance.sh

# 2. 功能面 — 走 pi-web 自己的 HTTP API 進行真實對話。
printf '在目前目錄建立 notes.md，內容為一行 hello。\n' > /tmp/p.txt
podman cp /tmp/p.txt pi-web:/tmp/p.txt
podman exec pi-web node /opt/tests/chat.mjs /tmp/p.txt --json /tmp/out.json
```

結構面用普通 `podman exec` 跑，**不要**加 `bash -l`。這是重點：映像把執行環境烘進去，非 login shell 也要落在伺服器所在環境；login shell 會把這一項的回歸蓋掉。

測試不再走 proxy 路徑（本 repo 沒有 proxy）。但仍會斷言上游 Host/Origin 守衛還在拒絕 hostname——回歸的話下游 proxy operator 可能誤以為不用轉頭就能上線，等哪天上游又收緊就當場壞掉。

---

## 日常操作

```bash
podman ps --format '{{.Names}}\t{{.Status}}'   # 健康狀態在這
journalctl --user -u pi-web -f                 # 監管層事件
podman logs -f pi-web                          # 應用輸出
podman exec -it pi-web bash                    # 進入 agent 環境
podman exec -it pi-web pi                      # Agent TUI
systemctl --user restart pi-web                # 重啟容器
```

要重建影片工具鏈：把 `pi-web.container` 的 `RESET_VIDEO_TOOLS` 設為 `true`，`systemctl --user daemon-reload && systemctl --user restart pi-web`，等重裝完成再改回 `false`。維持 `true` 會每次重啟都重下載約 720MB。

---

## 安全性現況

直說。

**做得好的地方。** rootless，agent 的 `bash` 工具以一般使用者身分執行，不是 node root。有設 `NoNewPrivileges`。pi-web 只發佈 `127.0.0.1`。憑證檔從建立那一刻就是 `600`。

**沒做的地方。** 本 repo 沒有任何身分驗證。而且 `GET /api/models-config` 會把供應商 API 金鑰以明文回傳給任何能連到 loopback 端點的呼叫者——實測，不是推論：

```
$ curl -H 'Host: localhost' http://127.0.0.1:30141/api/models-config
{"providers":{"openrouter":{"apiKey":"sk-or-v1-…","baseUrl":…
```

上游 pi-web 也沒有路徑限制、沒有核可關卡、沒有 `canUseTool` hook——agent 可讀寫容器使用者能觸及的任何位置、跑任何指令。這些是上游性質，打包再怎麼調都改不了。

**所以。** 把 `127.0.0.1:30141` 當成 shell + API 金鑰整組發出去。憑證邊界在同機 reverse proxy——見 [docs/downstream-nginx.md](docs/downstream-nginx.md)。Proxy 必須轉寫 Host / Origin、必須開驗證（Basic、CF Access、mTLS 自選）、也應該終結 TLS 讓憑證別以 base64 過網段。

**不要**為了「臨時測一下」把 `PublishPort` 改成 `0.0.0.0`。端點沒驗證且會吐 API 金鑰，一開就是外面的爬取目標。

---

## 文件

- [下游 reverse-proxy 契約](docs/downstream-nginx.md) — 兩個 header、驗證要求、以及 nginx + NPM 的樣板
- [架構與設計決策](docs/ARCHITECTURE.md) — 拓樸、信任守衛問題、啟動流程、儲存、k3s↔Podman 對照
- [English README](README.md)

## 授權

MIT
