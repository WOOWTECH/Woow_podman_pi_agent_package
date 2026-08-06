# Woow Podman Pi Agent

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![pi-web](https://img.shields.io/badge/pi--web-0.8.4-blue)](https://www.npmjs.com/package/@agegr/pi-web)
[![acceptance](https://img.shields.io/badge/%E9%A9%97%E6%94%B6-25%20%E9%80%9A%E9%81%8E%20%C2%B7%200%20%E5%A4%B1%E6%95%97-brightgreen)](docs/VERIFICATION_zh-TW.md)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

把 `@agegr/pi-web` 與 `pi` coding agent 打包成在 **rootless Podman** 上執行、由 **systemd（Quadlet）** 監管的服務。它是 [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) 的 Podman 版本——相同的應用層，為單機容器執行環境重新建置，而非 Kubernetes 叢集。

這套部署是跑過、量過的，不只是設計過：25 項結構面檢查、六輪對真實供應商的對話、以及與 k3s 版本的逐項對照。見[驗收紀錄](docs/VERIFICATION_zh-TW.md)。

> **這套部署前面沒有任何身分驗證。** 只要能連到發佈出去的連接埠，就等於拿到一個有 `bash` 工具、以你的帳號身分執行的 coding agent——而且可以明文讀到你的供應商 API 金鑰。兩件事都已在線上實測確認。在把它開放到可信任區網以外之前，請先讀[安全性現況](#安全性現況)。

---

## 提供什麼

| | |
|---|---|
| **Web UI** | `http://<host>:30142` — 對話、模型設定、技能、外掛、檔案瀏覽 |
| **Agent** | `@earendil-works/pi-coding-agent` 0.83.0，由 pi-web 以函式庫方式載入（沒有獨立 daemon） |
| **CLI** | 容器內 `PATH` 上有 `pi` — `podman exec -it pi-web pi` 即可操作 TUI |
| **持久化** | 單一具名 volume `pi-agent-data`，存放 sessions、skills、設定與 `$HOME` |
| **影片工具鏈** | ffmpeg、Playwright-Chromium、edge-tts、rclone、Noto CJK 字型（建置時可選） |
| **監管** | Quadlet 產生的 `systemd --user` unit，並啟用 lingering，登出與重開機後仍會運行 |

---

## 為什麼這不是「把 k3s 映像的 Kubernetes 部分刪掉」

兩套部署跑的是相同的 npm 套件，但只要執行環境不同，打包決策就跟著不同。以下每一項都是刻意的差異，不是遺漏：

| k3s 版本 | Podman 版本 | 原因 |
|---|---|---|
| `ttyd` sidecar + 密碼 Secret | *（移除）* | 在 Kubernetes 上，瀏覽器終端機幾乎是唯一實務可行的進 pod 途徑。在 Podman 上 `podman exec -it pi-web bash` 才是原生做法。那個 sidecar 本質上是一個發佈在外、沒有驗證的 shell，拿掉它等於少一整個攻擊面。 |
| 映像內含 `kubectl`、`s6-overlay`、`bashio` | *（移除）* | 由 systemd 監管，不需要第二套 init 互相協調。 |
| 三種 Kubernetes probe（`startup`/`readiness`/`liveness`） | 一個原生 `HEALTHCHECK` | Podman 原生支援 `HEALTHCHECK` 並顯示在 `podman ps`。不需要去模擬執行環境根本沒有的模型。 |
| 以節點上真正的 `root` 執行 | rootless — 容器內 `root` 對應到主機 uid 1000 | 容器逃逸後落到的是一般使用者，而不是主機 root。這是 Podman 版本最大的安全性提升。 |
| Helm chart、`NetworkPolicy`、PVC | Quadlet `.container` / `.network` / `.volume` | 原生 unit，`systemctl --user` 直接讀得到，你和執行環境之間少一層樣板。 |
| Cloudflare Tunnel sidecar | *（移除）* | 這台 Podman 主機本來就有自己的 tunnel 容器在服務所有站台，這裡再放一個只是重複。 |

**刻意保持完全一致**的部分：`pi` 啟動器包裝、CJK 路徑修補、skills 路徑橋接、`HOME` 釘在 volume 的配置，以及驗收測試套件。這些是應用層的修正，兩套部署之間不能漂移。

---

## 安裝

需要 Podman ≥ 4.4（Quadlet）、rootless，並以擁有 Podman storage 的那個帳號執行。

```bash
git clone https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git
cd Woow_podman_pi_agent_package

# --format=docker 是必須的。SHELL 與 HEALTHCHECK 在 OCI 格式裡沒有對應欄位，
# 預設格式建出來的映像會完全不回報健康狀態，`podman ps` 的 STATUS 也是空的。
podman build --format=docker \
  -t ghcr.io/woowtech/woow-podman-pi-agent:latest -f Containerfile .

# 安裝 unit 並啟動。不要用 sudo — rootless 就是設計本身。
./scripts/install.sh
```

`install.sh` 會拒絕以 root 執行、確認 Quadlet generator 存在、啟用 `loginctl` lingering、把 `config/nginx.conf` 安裝到 `~/.config/pi-agent/`、將四個 unit 放進 `~/.config/containers/systemd/`，然後等待容器回報 `healthy`。

在全新 volume 上第一次啟動，背景會下載約 720MB 的影片工具。**這段期間 UI 照常可用**——下載不會擋住啟動。

### 精簡版建置

`--build-arg VIDEO_TOOLS=0` 會產生約 700MB、沒有 ffmpeg、Chromium 函式庫、CJK 字型與 rclone 的映像。**這時要同時把 `quadlet/pi-web.container` 的 `VIDEO_PIPELINE_ENABLED` 設為 `false`**，否則 entrypoint 會一直去呼叫一個在該映像上不可能成功的 bootstrap。

### 移除

```bash
./scripts/uninstall.sh           # 停止並移除 unit，保留資料 volume
./scripts/uninstall.sh --purge   # 連 pi-agent-data 一起刪除（sessions、skills、金鑰）
```

---

## 首次使用

1. 開啟 `http://<host-ip>:30142`。
2. 進 **Models** 頁面，新增供應商（OpenRouter、Anthropic、OpenAI…）並貼上 API key。金鑰會以 `600` 權限寫入 volume 上的 `models.json`。
3. 開始對話。Agent 的工作目錄必須是*允許的根目錄*：既有 session 的 cwd，或 `$HOME/pi-cwd-YYYYMMDD` — pi-web 依照這個樣式建立與接受。

透過 UI 而不是環境變數設定供應商是刻意的：金鑰因此和其他狀態一起放在 volume 上，之後要輪替也不必改 unit 檔再重啟。

---

## 目錄結構

```
Containerfile              debian:bookworm-slim + Node 22 + pi-web，含建置時斷言
config/nginx.conf          Host/Origin 轉寫層 — 見架構文件
quadlet/
  pi-agent.network         私有橋接網路，aardvark-dns 負責容器名稱解析
  pi-agent-data.volume     單一具名 volume
  pi-web.container         Agent 本體；不發佈任何主機連接埠
  nginx.container          唯一對外的連接埠（30142）
patches/
  fix-unicode-space-paths.mjs   CJK 路徑修補，逐段斷言
rootfs/usr/local/bin/
  pi                       啟動器 — 解析以相依方式安裝的 CLI
  pi-agent-env.sh          執行環境的唯一定義來源
  pi-web-start.sh          進入點：umask、權限、skills 橋接、時區、影片工具啟動
  video-tools-init.sh      sentinel 守衛、可自愈的首次安裝
scripts/install.sh         rootless 安裝腳本
scripts/uninstall.sh       移除，預設保留 volume
tests/acceptance.sh        不需 LLM 的驗收測試
tests/chat.mjs             對話測試工具 — 走 pi-web 自己的 API 進行真實對話
docs/ARCHITECTURE.md       架構圖與每個決策的理由
docs/VERIFICATION_zh-TW.md 這套部署實際做到了什麼，附數字
```

---

## 驗收部署

兩套測試，便宜的先跑。`tests/` 沒有包進映像，要先拷貝進去。

```bash
# 1. 結構面 — 不呼叫模型、零成本。檢查執行環境、持久化配置、HTTP
#    介面、CJK 回歸測試、影片工具鏈與信任守衛。
podman cp tests/. pi-web:/opt/tests/
podman exec pi-web bash /opt/tests/acceptance.sh

# 2. 功能面 — 走 pi-web 自己的 HTTP API 進行真實對話，
#    以 agent 實際發出的工具呼叫作為判準。
printf '在目前目錄建立 notes.md，內容為一行 hello。\n' > /tmp/p.txt
podman cp /tmp/p.txt pi-web:/tmp/p.txt
podman exec pi-web node /opt/tests/chat.mjs /tmp/p.txt --json /tmp/out.json
```

結構面測試請用普通 `podman exec` 跑，**不要**加 `bash -l`。這正是重點：映像把執行環境烘進去，就是為了讓非 login shell 也落在伺服器所在的環境；用 login shell 跑會把這一項的回歸蓋掉。

`chat.mjs` 判斷依據是 `toolCalls[]`，不是助理的叙述文字。模型說「我已成功建立檔案」不構成證據，工具執行結果才是。預設使用 OpenRouter 上的 `deepseek/deepseek-v4-flash`，可用 `PI_TEST_MODEL` / `PI_TEST_PROVIDER` 覆寫。

兩套測試與 k3s 版本逐項對齊：相同的檢查項目、相同的順序。因此兩輪之間的差異可以被判定為移植缺陷，而不是量測方式不同造成的。逐項對照表在[驗收紀錄](docs/VERIFICATION_zh-TW.md)裡。

---

## 日常操作

```bash
podman ps --format '{{.Names}}\t{{.Status}}'   # 健康狀態顯示在這裡
journalctl --user -u pi-web -f                 # 監管層事件
podman logs -f pi-web                          # 應用程式輸出
podman exec -it pi-web bash                    # 進入 agent 的環境
podman exec -it pi-web pi                      # Agent TUI
systemctl --user restart pi-web                # nginx 會自動跟著重啟（PartOf=）
```

要重建影片工具鏈：把 `pi-web.container` 的 `RESET_VIDEO_TOOLS` 設為 `true`，執行 `systemctl --user daemon-reload && systemctl --user restart pi-web`，等重新安裝完成後再改回 `false`。維持 `true` 會導致每次重啟都重新下載約 720MB。

---

## 安全性現況

直說，因為誠實版本很短。

**這套部署做得好的地方。** 它是 rootless 的，agent 的 `bash` 工具以一般主機使用者身分執行，而不是節點 root。有設 `NoNewPrivileges`。pi-web 本身不發佈任何主機連接埠。憑證檔從建立那一刻就是 `600`，不是事後補救。

**沒有做到的地方。** 任何位置都沒有身分驗證。而且 `GET /api/models-config` 會把供應商 API 金鑰以明文回傳給未驗證的呼叫者——這是經發佈連接埠實測到的，不是推論：

```
$ curl -H 'Host: pi.example.com' http://<host>:30142/api/models-config
{"providers":{"openrouter":{"apiKey":"sk-or-v1-…","baseUrl":…
```

上游 pi-web 另外沒有路徑限制、沒有核可關卡、也沒有 `canUseTool` hook——agent 可以讀寫容器使用者能觸及的任何位置，並執行任何指令。這些是上游的性質，打包方式再怎麼調整都無法解決。本套件能做的只是縮小那個端點**從哪裡**可以被觸及，這跟保護它不是同一件事。

**所以。** 請把 30142 埠視同直接把 shell 跟 API 金鑰一起發出去。若要超出可信任區網使用，前面必須放一層有身分驗證的 proxy——這台 Podman 主機既有的 Cloudflare Tunnel 加 Cloudflare Access 就是預期路徑，這也正是本套件刻意不自帶 tunnel 的原因。若只要本機可用，把 `quadlet/nginx.container` 的 `PublishPort` 改成 `127.0.0.1:30142:30142`。

---

## 文件

- [架構與設計決策](docs/ARCHITECTURE.md) — 拓樸、信任守衛問題、啟動流程、儲存、k3s↔Podman 對照
- [驗收紀錄](docs/VERIFICATION_zh-TW.md) — 量了什麼、找到哪些缺陷、還剩下什麼暴露
- [English README](README.md)

## 授權

MIT
