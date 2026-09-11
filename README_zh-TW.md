# Woow Podman Pi Agent

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![pi-web](https://img.shields.io/badge/pi--web-0.9.0-blue)](https://www.npmjs.com/package/@agegr/pi-web)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

把 `@agegr/pi-web` 與 `pi` coding agent 打包成在 **rootless Podman** 上執行、由 **systemd（Quadlet）** 監管的服務。它是 [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) 的 Podman 版本——相同的應用層，為單機容器執行環境重新建置。

> **對外開放任何東西之前，先讀 [安全性現況](#安全性現況)。**
> pi-web 0.9.0 起 UI 內建瀏覽器終端機。能連到 `127.0.0.1:30141` 的人，就拿到一個等同於執行容器那個帳號的 shell，而且該帳號的家目錄以讀寫方式掛在容器裡。本套件**不提供任何身分驗證**：前面必須有一台同機、開了驗證的 reverse proxy（見 [docs/downstream-nginx.md](docs/downstream-nginx.md)）。

---

## 提供什麼

| | |
|---|---|
| **Loopback 端點** | Podman 主機上的 `http://127.0.0.1:30141` — 沒有驗證，只給同機 reverse proxy 使用 |
| **Agent** | `@earendil-works/pi-coding-agent` 0.85.1，由 pi-web 0.9.0 以函式庫方式載入（沒有獨立 daemon） |
| **瀏覽器終端機** | `/api/terminal`（node-pty，`SHELL=/bin/bash`）— 容器內的 login shell |
| **CLI** | 容器內 `PATH` 上有 `pi` — `podman exec -it pi-web pi` 即可操作 TUI |
| **持久化** | 單一具名 volume `pi-agent-data`，存放 sessions、skills、設定與 `$HOME` |
| **影片工具鏈** | ffmpeg、Playwright-Chromium、edge-tts、rclone、Noto CJK 字型（可選，見[設定](#設定)） |
| **監管** | Quadlet 產生的 `systemd --user` unit，`Restart=always`，啟用 lingering，登出/重開機後仍運行 |

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

需要 rootless Podman ≥ 4.4（Quadlet；已在 Ubuntu 24.04 的 4.9.3 測試），以擁有這些容器的帳號執行。不要用 `sudo`。

```bash
git clone https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git
cd Woow_podman_pi_agent_package
./scripts/install.sh
```

安裝就這樣。`scripts/install.sh` 會：

1. 拒絕以 root 執行、確認 Podman 與 Quadlet generator、啟用 lingering；
2. 第一次執行時，從 `config/pi-agent.env.example` 建立 `~/.config/pi-agent/pi-agent.env`（權限 0600）；
3. 用這些設定渲染 `quadlet/` 與 `systemd/` 裡的 unit，並用 Quadlet generator（`quadlet -dryrun`）與 `systemd-analyze --user verify` 檢查；
4. **在本機建置兩個映像**：先把 `Containerfile` 建成 `localhost/woow-podman-pi-agent:<tag>`，再以它為底把 `Containerfile.host-control` 建成 `localhost/woow-podman-pi-agent-host:<tag>`，一律加 `--format=docker`（`SHELL` 與 `HEALTHCHECK` 指令在 OCI 格式沒有對應欄位）。冷建置約 5-20 分鐘且需要網路；同一版本再建一次會完全命中快取；
5. 把 `pi-agent.network`、`pi-agent-data.volume`、`pi-web.container` 裝進 `~/.config/containers/systemd/`，健康檢查 unit 裝進 `~/.config/systemd/user/`，只寫有變動的檔案；
6. 啟動新增的 unit，**pi-web 的 unit 或映像有變時才重啟 pi-web**（沒變的重跑什麼都不重啟），等到 `healthy`，再跑 `tests/smoke.sh`。

所有映像都在動到任何 unit 之前建好，所以建置失敗不會造成停機。`./scripts/install.sh --build-only` 只建映像就結束，適合在維護時段之前先準備。

Tag 是 `<pi-web 版本>-r<套件修訂號>`（目前是 `0.9.0-r1`），釘在 `quadlet/pi-web.container`；`Pull=never`，因為映像只存在於建置它的那台主機。Base 映像沒有發佈到任何 registry；發佈到 GHCR（讓主機可以跳過 base 建置）是之後的工作。

全新 volume 首次啟動時，背景會下載約 720MB 影片工具。**UI 全程可用。**

### 設定

`~/.config/pi-agent/pi-agent.env` 只給安裝與升級腳本讀。腳本把值渲染進安裝好的 unit；systemd 與 Podman 都不會讀這個檔。改完值之後再跑一次 `./scripts/install.sh`。

| Key | 預設 | 作用 |
|---|---|---|
| `PI_TZ` | `Asia/Taipei` | 容器時區（`Environment=TZ=`） |
| `PI_VIDEO_TOOLS` | `true` | `false` 會建精簡映像（`--build-arg VIDEO_TOOLS=0`，約 700MB，沒有 ffmpeg / Chromium 函式庫 / CJK 字型 / rclone），tag 加上 `…-slim`，並設 `VIDEO_PIPELINE_ENABLED=false` |

Unit 裡所有跟帳號有關的路徑都用 systemd specifier：`%h` 是家目錄、`%t` 是 `XDG_RUNTIME_DIR`。同一份 unit 適用任何使用者與 uid，不需要手動修改。

### Profile

| Profile | 狀態 | pi-web 拿到什麼 |
|---|---|---|
| **host-control**（預設，目前唯一） | 已提供 | 擁有者帳號的家目錄掛在 `/host$HOME`（讀寫）、它的 rootless Podman socket、它的 user systemd bus。Agent 能管理這個帳號的每一個容器。 |
| slim / 無 host-control | 規劃中 | 只有 base 映像，不掛主機資源。 |

### 升級

```bash
git pull
./scripts/upgrade.sh           # 熱備份資料、建置、切換、smoke；失敗自動回滾
```

`upgrade.sh` 會先匯出 `pi-agent-data`，在舊的 pi-web 繼續服務的同時建置新釘選的 tag，接著安裝並跑 smoke 測試。新映像沒有變成 healthy 時，會把先前的 unit 放回去並用先前的映像重啟；舊映像會保留到 `./scripts/upgrade.sh --prune`。`--no-backup` 跳過匯出。

### 備份與還原

```bash
./scripts/backup.sh                 # 冷備份：匯出時停掉 pi-web，完成後再啟動
./scripts/backup.sh --hot           # 不停機；匯出期間寫入的 session 可能不完整
./scripts/restore.sh ~/backups/pi-agent/pi-agent-data-<ts>.tar
```

備份放在 `~/backups/pi-agent/`，檔案 0600、目錄 0700，每個檔都附 `.sha256`。**備份裡有 `models.json`，也就是供應商 API 金鑰。** `restore.sh` 會驗 checksum、要求確認、先匯出目前內容，然後才替換 volume 並跑 smoke 測試。

### 移除

```bash
./scripts/uninstall.sh                 # 停止並移除 unit，保留資料 volume
./scripts/uninstall.sh --purge --yes   # 連 pi-agent-data 一起刪除（刪之前會先匯出一份）
```

Env 檔、映像與 reverse proxy 設定永遠不會被刪除。

### 收斂手動修改過的安裝

用本 repo 舊版安裝的主機（toypark1234、openclaw），`pi-web.container` 是原封不動複製過去，有些還手動改過（兩行 `/home/<user>`）。這樣收斂：

```bash
cd Woow_podman_pi_agent_package && git pull
./scripts/install.sh --build-only   # 可選，事先執行：不影響服務
./scripts/install.sh                # 接管舊 unit、保留副本、pi-web 重啟一次
```

舊檔在被覆蓋前會複製到 `~/.local/state/woow-quadlet/pi-agent/`（`replaced/`、`adopted/`）。掛載、環境變數、網路、volume 與連接埠都不變；只有映像 tag 改變（`:latest` → `:0.9.0-r1`），auto-update label 拿掉。要回滾就把舊檔複製回去，再執行 `systemctl --user daemon-reload && systemctl --user restart pi-web.service`；舊的 `:latest` 映像還在。

---

## 首次使用

1. 在 pi-web 前面放一台**有開驗證**的 reverse proxy。主機上跑 [Woow_podman_nginxpm](https://github.com/WOOWTECH/Woow_podman_nginxpm) 的話，在那邊設 `NPM_PI_WEB_FRONT=true`，然後建一個 proxy host：Forward Hostname `pi-web`、port `30141`、掛上 access list。一般 nginx 請看 [docs/downstream-nginx.md](docs/downstream-nginx.md)。
2. 用 proxy 對外的 hostname 開 UI。
3. 進 **Models** 頁，新增供應商並貼 API key。金鑰以 `600` 權限寫入 volume 上的 `models.json`。
4. 開始對話。Agent 的工作目錄必須是*允許的根目錄*：既有 session 的 cwd，或 `$HOME/pi-cwd-YYYYMMDD`。

供應商透過 UI 而不是環境變數設定是刻意的：金鑰放在 volume 上，輪替不必改 unit。

---

## 目錄結構

```
Containerfile              debian:bookworm-slim + Node 22 + pi-web 0.9.0，多階段編譯 node-pty
Containerfile.host-control host-control 層（podman + systemd client），疊在本機 base 上
config/pi-agent.env.example   每台主機的設定，安裝到 ~/.config/pi-agent/pi-agent.env
quadlet/
  pi-agent.network         私有橋接網路，aardvark-dns 負責容器名稱解析
  pi-agent-data.volume     單一具名 volume
  pi-web.container         Agent 本體；發佈 127.0.0.1:30141 給同機 reverse proxy
  render-vars              install.sh 唯一可以代入 unit 的變數清單
systemd/
  pi-web-health.service    oneshot：podman healthcheck run pi-web
  pi-web-health.timer      每 30s（Podman 自己的健康檢查 timer 沒註冊的主機需要它）
patches/
  fix-unicode-space-paths.mjs   CJK 路徑修補，逐段斷言
rootfs/usr/local/bin/      pi 啟動器、執行環境、進入點、影片工具啟動
scripts/
  install.sh               建映像、渲染、安裝、有變才重啟、smoke
  upgrade.sh               備份、建置、切換、smoke、自動回滾
  backup.sh restore.sh     pi-agent-data 匯出 / 匯入
  uninstall.sh             移除，除非 --purge 否則保留 volume
  render-args.sh           由 env 檔計算出的值（與 tests/dryrun.sh 共用）
  lib/quadlet-lib.sh       vendored 的 WOOWTECH Quadlet 函式庫（不要修改；CI 會檢查雜湊）
tests/
  dryrun.sh                渲染 + quadlet -dryrun + systemd-analyze verify（CI）
  dryrun.local.sh          檢查產生出來的 podman 指令是否符合 pi-agent 的不變條件（CI）
  host-profile.sh          host-control profile 的靜態檢查（CI）
  smoke.sh                 真實主機上的安裝後檢查
  acceptance.sh chat.mjs   不需 LLM 的驗收測試與對話測試工具
docs/                      架構、下游 proxy 契約、Armbian 筆記、歷史紀錄
```

CI（`.github/workflows/quadlet-ci.yml`，ubuntu-24.04 + podman 4.9.3）會跑 `tests/dryrun.sh` 與 `shellcheck`，並驗證 vendored 函式庫的雜湊。

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
bash tests/smoke.sh                            # 安裝後檢查
```

要重建一次影片工具鏈：在**已安裝的** `~/.config/containers/systemd/pi-web.container` 把 `RESET_VIDEO_TOOLS` 設為 `true`，執行 `systemctl --user daemon-reload && systemctl --user restart pi-web`，等重裝完成後再跑 `./scripts/install.sh`：它會把渲染好的 unit 放回去（`RESET_VIDEO_TOOLS=false`，你改過的那份會留副本）並重啟。

---

## 安全性現況

直說。

**瀏覽器終端機就是這個帳號的 root 等級 shell。** pi-web 0.9.0 新增的 `/api/terminal` 會透過 node-pty 開一個 login shell。這個 shell 在容器*內*是 root；rootless Podman 把它對應到執行 unit 的主機帳號。加上 host-control 的掛載，這個帳號的整個家目錄以讀寫方式掛在 `/host$HOME`，它的 rootless Podman socket 可以用（這個帳號的每一個容器，包括 pi-web 自己），它的 user systemd 也可以用。實際上，碰得到終端機的人可以：

- 讀取並修改這個帳號擁有的每一個檔案：`~/.ssh`、`~/.local/share/containers` 底下其他服務的資料與 volume、tunnel token；
- 啟動、停止、exec 進去或替換這個帳號的每一個容器；
- 安裝會常駐的 user unit；
- 讀到供應商 API 金鑰：`GET /api/models-config` 會明文回傳，`cat /data/pi-agent/models.json` 也可以。

如果這個帳號在 `sudo` 群組，離主機 root 只差一組密碼。這些都不是打包能修的 bug：上游 pi-web 沒有身分驗證、沒有路徑限制、沒有核可關卡、也沒有 `canUseTool` hook。

**所以身分驗證必須在下游強制執行**，由同機 reverse proxy 對所有路徑套用：

- NPM（[Woow_podman_nginxpm](https://github.com/WOOWTECH/Woow_podman_nginxpm)，設 `NPM_PI_WEB_FRONT=true`）加上有 Basic auth 的 access list，以及
- 公開 hostname 的話，前面再加 **Cloudflare Access** 當第二道獨立防線。只有 Basic auth 等於網際網路和一個 shell 之間只隔一組密碼。

`PI_WEB_PASSWORD`（pi-web 自己的 Basic auth）刻意不接：擁有者的決定是驗證放在下游。

**任何繞過 proxy 通到 127.0.0.1:30141 的路徑，都是一個沒有驗證的 shell。** 包括 tailnet 上 `tailscale serve` 轉發到 `127.0.0.1:30141`（每個 tailnet 成員都拿到 shell）、跟別人共用的 `ssh -L`、以及主機上能連到主機 loopback 的其他容器。`scripts/install.sh` 發現 30141 有非 loopback 的 listener，或 woow-tailscale 的 serve 設定轉發到它時，會發出警告。**不要**為了「臨時測一下」把 `PublishPort` 改成 `0.0.0.0`。

**做得好的地方。** rootless，容器逃逸落到的是一般帳號而不是主機 root。有設 `NoNewPrivileges`。pi-web 只發佈 `127.0.0.1`。映像裡沒有編譯器。憑證檔從建立那一刻就是 `600`，備份是 0700 目錄裡的 0600 檔案。

---

## 文件

- [下游 reverse-proxy 契約](docs/downstream-nginx.md) — 兩個 header、驗證要求、NPM 的 pi-web front 與一般 nginx 樣板
- [架構與設計決策](docs/ARCHITECTURE.md) — 拓樸、信任守衛問題、啟動流程、儲存、k3s↔Podman 對照
- [Armbian / arm64 筆記](docs/armbian-arm64-deployment.md) — `/usr/local` 下的 podman-static、cgroupfs、健康檢查 timer
- [English README](README.md)

## 授權

MIT
