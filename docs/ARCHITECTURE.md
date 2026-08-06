# Architecture

How the Podman deployment is put together, and why each piece is shaped the way it is. Where a decision differs from [the k3s deployment](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package), the reason is stated rather than left as an unexplained divergence.

This document is the design. [VERIFICATION.md](VERIFICATION.md) is the measurement — what the deployment did when it was run, including the five defects that only appeared under a live workload.

---

## 1. Topology

Two containers on a private bridge. Exactly one host port is published, and it is not the agent's.

```mermaid
graph TB
    subgraph LAN["LAN"]
        BROWSER["Browser<br/>http://host:30142"]
        TUNNEL["Cloudflare Tunnel<br/><i>(separate container,<br/>not shipped here)</i>"]
    end

    subgraph HOST["Podman host — rootless, uid 1000"]
        subgraph NET["pi-agent network (netavark + aardvark-dns)"]
            NGINX["<b>pi-agent-nginx</b><br/>nginx:1.27-alpine<br/>listen 30142"]
            PIWEB["<b>pi-web</b><br/>woow-podman-pi-agent<br/>listen 30141<br/><i>no published port</i>"]
        end
        VOL[("pi-agent-data<br/>named volume")]
        SD["systemd --user<br/>(Quadlet-generated units)"]
    end

    subgraph EXT["External"]
        OR["OpenRouter / Anthropic / OpenAI"]
        MCP["MCP servers over HTTP"]
    end

    BROWSER -->|":30142"| NGINX
    TUNNEL -.->|"optional"| NGINX
    NGINX -->|"proxy_pass http://pi-web:30141<br/><b>Host: localhost</b><br/><b>Origin: (blank)</b>"| PIWEB
    PIWEB --- VOL
    PIWEB -->|"HTTPS"| OR
    PIWEB -->|"agent shells out: curl + JSON-RPC"| MCP
    SD -.->|"supervises, restarts"| NGINX
    SD -.->|"supervises, restarts"| PIWEB

    classDef pub fill:#fde68a,stroke:#b45309,color:#000
    classDef priv fill:#bfdbfe,stroke:#1d4ed8,color:#000
    class NGINX pub
    class PIWEB priv
```

**pi-web publishes no host port.** This is the load-bearing decision of the whole layout. `GET /api/models-config` returns the configured provider API key **unredacted and unauthenticated** — confirmed on a live deployment, not inferred from source. Publishing pi-web directly would mean anything that can reach the host on that port can read the key. Keeping it namespace-internal means the only way in is through nginx, which at least gives one place to attach authentication later.

**A network, not a pod.** The k3s deployment put everything in one pod because `ttyd` had to share `localhost` with pi-web. With ttyd gone there is nothing to co-locate, and a plain bridge is both simpler and more portable — Podman 4.9 has no `.pod` Quadlet unit type, so a pod would have meant hand-written unit files.

---

## 2. The trust guard — why nginx exists at all

nginx is not here for TLS, load balancing, or caching. It exists to rewrite two headers.

pi-web's `isApiRequestAllowed()` rejects:
- any `Host` that is not a loopback **name** or a **raw IP**, and
- any `Origin` that does not match the request.

Reaching the UI by raw LAN IP happens to satisfy the `Host` half on its own. But the moment a **hostname** is involved — a Cloudflare Tunnel, a reverse proxy, an internal DNS name — both halves fail, and every auth-gated route answers `403 Untrusted API request`. The symptom is distinctive and easy to misdiagnose: **the UI loads and renders, and then does nothing.**

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant N as nginx :30142
    participant P as pi-web :30141

    Note over B,P: Without the shim — hostname in front
    B->>P: GET /api/models<br/>Host: pi.example.com<br/>Origin: https://pi.example.com
    P-->>B: 403 Untrusted API request
    Note right of P: UI renders, every data route fails

    Note over B,P: With the shim
    B->>N: GET /api/models<br/>Host: pi.example.com<br/>Origin: https://pi.example.com
    N->>P: GET /api/models<br/>Host: localhost<br/>Origin: (empty)
    P-->>N: 200 { models: [...] }
    N-->>B: 200
```

Both halves were measured, with identical headers: **200 through nginx, 403 sent directly at pi-web.** The 403 is the more interesting number — it is what proves the shim is load-bearing rather than decorative, and `tests/acceptance.sh` asserts on it for that reason. A regression that quietly removed the header rewriting would still pass a suite that only checked the success path, while every named route in the browser broke.

Nothing else can blank the `Origin` header. A tunnel's `httpHostHeader` option covers `Host` only. That asymmetry is why this container stops being optional the moment any name is put in front of the deployment.

### Startup-time DNS, and the coupling it forces

`nginx.conf` uses a static `proxy_pass http://pi-web:30141` with **no `resolver` directive**. Podman's DNS does not live at Docker's `127.0.0.11`, and hardcoding any address breaks the moment the network is recreated. So nginx resolves the name once, at startup, through the container's own `resolv.conf`.

The cost is a stale address if pi-web is ever replaced. The fix is in the unit, not the config: `nginx.container` declares `Requires=pi-web.service` and `PartOf=pi-web.service`, so systemd restarts nginx whenever pi-web restarts and the address is re-read. nginx starts in well under a second, so the coupling is free.

---

## 3. Boot sequence

```mermaid
sequenceDiagram
    autonumber
    participant SD as systemd --user
    participant C as pi-web container
    participant S as pi-web-start.sh
    participant V as pi-agent-data
    participant W as pi-web (node)

    SD->>C: start (TimeoutStartSec=900)
    C->>S: tini → pi-web-start.sh
    S->>S: umask 077
    S->>V: mkdir sessions/ skills/ home/
    S->>V: chmod 600 models.json, auth.json (repair pass)
    S->>S: HOME=/data/pi-agent/home, TZ=Asia/Taipei
    S->>V: symlink $HOME/.pi/agent/skills → /data/pi-agent/skills
    Note right of S: the skills bridge — without it,<br/>`pi install` succeeds and the skill<br/>never appears in a session
    alt video toolchain present and enabled
        S-->>V: background: venv + Playwright-Chromium + edge-tts (~720MB)
        Note right of V: does NOT gate startup;<br/>writes .video-tools-installed when done
    end
    S->>W: exec pi-web
    W-->>C: listening on 0.0.0.0:30141
    C->>C: HEALTHCHECK /api/home (start-period 120s)
    C-->>SD: healthy
    SD->>SD: nginx.service starts (Requires=)
```

`TimeoutStartSec=900` and `--start-period=120s` exist for the same reason: a cold volume plus the bootstrap can take minutes before `/api/home` answers, and neither systemd nor the healthcheck should give up during that window.

The `umask 077` is first for a reason. It is what makes the credential files private from birth; the chmod that follows only repairs volumes written by an older image. Ordering the other way round — repair first, umask later — is what the original version effectively did, and it left `models.json` at 0644 for the entire period it held an API key.

---

## 4. Persistence

One volume. Everything that must survive a container replacement lives under it, including `$HOME`.

```mermaid
graph LR
    VOL[("pi-agent-data")] --> H["home/"]
    VOL --> SE["sessions/"]
    VOL --> SK["skills/"]
    VOL --> MJ["models.json<br/><i>mode 600 — holds the API key</i>"]
    VOL --> AJ["auth.json<br/><i>mode 600</i>"]
    VOL --> ST["settings.json"]
    VOL --> VE["venv/"]
    VOL --> PC["playwright-cache/"]
    VOL --> SENT[".video-tools-installed"]

    H --> CWD["pi-cwd-YYYYMMDD/<br/><i>the allowed-root pattern</i>"]
    H --> PID[".pi/agent/skills → skills/<br/><i>the bridge symlink</i>"]

    classDef secret fill:#fecaca,stroke:#b91c1c,color:#000
    class MJ,AJ secret
```

**Pinning `HOME` into the volume** is what makes the CLI and the web UI agree on state. Left at `/root`, `pi install <skill>` from a shell would write inside the container's ephemeral layer and vanish on the next restart, while the UI kept reading the volume — an especially confusing failure, because the install reports success. The value is baked as image ENV rather than exported from `/etc/profile.d` alone, because profile.d reaches login shells only and `podman exec -it pi-web bash` is not one.

**Allowed cwd roots.** pi-web only accepts a working directory that is either an existing session's cwd or matches `^pi-cwd-\d{8}$` under `$HOME`. A fresh volume has neither, which is why `/api/models` answers `403` before any directory exists — that is normal fresh-install state, not a broken trust guard. The acceptance suite creates the dated directory before probing, precisely so this does not get misread as a failure.

---

## 5. The fixes that must not drift

The first two are carried identically by the k3s and Podman images — they are properties of the upstream packages, not of the runtime. The third is specific to this image, and is included here because it is the same class of mistake.

### The `pi` launcher

`@earendil-works/pi-coding-agent` is a **transitive** dependency of pi-web, so npm never links its `bin`. Without intervention there is no `pi` on `PATH` — every terminal workflow, every CLI-installed skill, and the whole TUI configuration path is simply dead. `rootfs/usr/local/bin/pi` resolves the nested `dist/cli.js` at runtime across four candidate paths with a `find` fallback, and the Containerfile asserts `pi --version` at build time so a layout change fails the build rather than shipping a broken image.

### The CJK path patch

Upstream `normalizeToolPath` folds U+00A0, U+2000–200A, U+202F, U+205F and **U+3000** to an ASCII space on every read, write and edit — and builds the read fallback chain from the already-folded path. Two consequences, both silent:

- a write to `台灣　報告.txt` (ideographic space) lands at `台灣 報告.txt` while reporting success;
- two files differing only by space type **cross-read** — you ask for one and get the other's contents.

For a zh-TW deployment this is data loss with a success message. `patches/fix-unicode-space-paths.mjs` handles both upstream shapes and asserts every hunk, so an upstream version bump fails the build instead of quietly dropping the fix. `tests/acceptance.sh` section 4 re-verifies it at runtime, because a patch that applied at build time and a patch that is live in the running image are not the same claim.

### The venv predicate

`video-tools-init.sh` judges an existing virtualenv by `bin/pip`, not by `bin/python3`. A venv whose ensurepip step failed — which is what happens on an image built with `VIDEO_TOOLS=0` — still has `bin/python3`. Testing that file made a half-built venv read as complete: creation was skipped, the next line called a pip that did not exist, the failure path exited 0, the sentinel was never written, and the identical sequence repeated on every boot with no way to recover short of deleting the tree by hand.

The general shape is worth naming, because all three fixes above are instances of it: **the obvious predicate is often not the one that determines whether the next step works.** `bin/python3` exists, `pi` is a declared dependency, a path is "the same path" after normalisation — each is true, and each is the wrong thing to check.

---

## 6. k3s ↔ Podman mapping

```mermaid
graph LR
    subgraph K3S["k3s"]
        HELM["Helm chart"] --> DEP["Deployment<br/>3 containers"]
        DEP --> C1["pi-web"]
        DEP --> C2["nginx"]
        DEP --> C3["ttyd"]
        DEP --> PVC[("PVC")]
        NP["NetworkPolicy"] -.-> DEP
        CFD["cloudflared Deployment"] -.-> DEP
    end

    subgraph POD["Podman"]
        QD["Quadlet units"] --> Q1[".container pi-web"]
        QD --> Q2[".container nginx"]
        QD --> Q3[".network"]
        QD --> Q4[".volume"]
        Q1 --> PV[("pi-agent-data")]
    end

    C1 ==>|"same image content"| Q1
    C2 ==>|"same header shim"| Q2
    C3 ==>|"replaced by<br/>podman exec"| SHELL["podman exec -it pi-web bash"]
    PVC ==> PV
    NP ==>|"replaced by<br/>not publishing the port"| Q1
    CFD ==>|"host's existing<br/>tunnel container"| EXT["(out of scope)"]
```

| Concern | k3s | Podman |
|---|---|---|
| Orchestration | Helm → Deployment | Quadlet → `systemd --user` |
| Shell access | ttyd sidecar on a published port | `podman exec` |
| Ingress restriction | `NetworkPolicy` limited to 30141/30142/7681 | pi-web simply publishes nothing |
| Health | startup + readiness + liveness probes | one `HEALTHCHECK`, surfaced in `podman ps` |
| Storage | PVC (`local-path`) | named volume |
| Privilege | real root on the node | rootless; container root → host uid 1000 |
| Restart policy | `restartPolicy: Always` | `Restart=always` + `enable-linger` |
| External access | cloudflared sidecar + Cloudflare Access | the host's existing tunnel container |

`enable-linger` deserves a note: `systemd --user` services stop at logout and do not start at boot without it. This host's container runtime has restarted unprompted before; without lingering the stack would have stayed silently down afterwards.

The per-property acceptance comparison — which of these were actually exercised, and with what result — is in [VERIFICATION.md](VERIFICATION.md#3-k3s--podman-per-property).

---

## 7. What is not solved here

Honest boundaries, so nobody assumes coverage that does not exist. The last column separates what was observed on a running deployment from what is read from upstream code — both are real, but they are not equally strong claims.

| Gap | Where it lives | Consequence | Basis |
|---|---|---|---|
| No authentication | this package | Port 30142 is a shell for anyone who reaches it | by construction |
| `/api/models-config` returns the key unredacted | upstream pi-web | Anything that reaches the published port can read the provider key | **measured** — unauthenticated request, key in cleartext |
| No path confinement | upstream pi-coding-agent | The agent reads and writes anywhere the container user can | read from upstream |
| No approval gate / no `canUseTool` hook | upstream pi-coding-agent | No opportunity to intercept a tool call before it executes | read from upstream |
| No native MCP client (0.83.0) | upstream | MCP works only because the model drives the protocol by hand over `curl` | **measured** — full handshake completed, 38 tools listed |

The first is addressable by putting an authenticating proxy in front — which is exactly why this package deliberately ships no tunnel of its own, leaving that layer to the host's existing Cloudflare Tunnel and Access. The rest are upstream properties and are listed so they are decided about rather than discovered.

The MCP row is worth reading twice. It passed — but it passed because the *model* implemented the protocol correctly on every call, not because the runtime did. That is a capability with a different failure mode: a weaker model does not produce a connection error, it produces a wrong answer.
