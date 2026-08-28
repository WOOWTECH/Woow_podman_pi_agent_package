# Woow Podman Pi Agent

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![pi-web](https://img.shields.io/badge/pi--web-0.8.4-blue)](https://www.npmjs.com/package/@agegr/pi-web)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

`@agegr/pi-web` and the `pi` coding agent, packaged to run on **rootless
Podman** and supervised by **systemd via Quadlet**. It is the Podman sibling
of [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package)
— the same application surface, rebuilt for a single-host container runtime
instead of a Kubernetes cluster.

> **This package ships pi-web only. Authentication and Host/Origin rewriting
> are the responsibility of a same-host reverse proxy** — the shared nginx or
> Nginx Proxy Manager instance the deployment already runs for its other
> services. See [Downstream reverse-proxy contract](docs/downstream-nginx.md)
> for the two headers that MUST be set and the auth mechanism you MUST turn
> on. Without both, either the UI loads and every data route returns 403, or
> the provider API key is scrape-able in cleartext.

---

## What you get

| | |
|---|---|
| **Loopback endpoint** | `http://127.0.0.1:30141` on the Podman host — unauthenticated, reverse-proxy-only |
| **Agent** | `@earendil-works/pi-coding-agent` 0.83.0, imported as a library by pi-web (no separate daemon) |
| **CLI** | `pi` on `PATH` inside the container — `podman exec -it pi-web pi` drives the TUI |
| **Persistence** | one named volume, `pi-agent-data`, holding sessions, skills, config and `$HOME` |
| **Video pipeline** | ffmpeg, Playwright-Chromium, edge-tts, rclone, Noto CJK fonts (optional at build time) |
| **Supervision** | `systemd --user` units generated from Quadlet, with lingering so they survive logout and reboot |

---

## Why this is not "the k3s image with the Kubernetes parts deleted"

The two deployments run the same npm packages, but the packaging decisions differ where the runtime differs. Each of these is a deliberate divergence, not an omission:

| k3s package | Podman package | Reason |
|---|---|---|
| `ttyd` sidecar + password Secret | *(removed)* | On Kubernetes a browser terminal was the only practical route to a shell in the pod. Under Podman, `podman exec -it pi-web bash` is the native answer. |
| `kubectl`, `s6-overlay`, `bashio` in the image | *(removed)* | systemd supervises. There is no second init to reconcile. |
| three Kubernetes probes | one native `HEALTHCHECK` | Podman honours `HEALTHCHECK` and reports it in `podman ps`. |
| runs as real `root` on the node | rootless — container `root` maps to host uid 1000 | A container escape lands on an unprivileged user instead of the host root. |
| Helm chart, `NetworkPolicy`, PVC | Quadlet `.container` / `.network` / `.volume` | Native units, no templating layer between you and the runtime. |
| Cloudflare Tunnel sidecar | *(removed)* | The Podman host already runs its own tunnel container for every service. |
| **nginx sidecar for Host/Origin + auth** | ***(removed — moved to the host's shared reverse proxy)*** | The Podman host already runs an nginx / NPM in front of every other service. Shipping our own inside the package meant duplicating that layer and running a second credential store. See [docs/downstream-nginx.md](docs/downstream-nginx.md). |

What is **identical** on purpose: the `pi` launcher wrapper, the CJK path patch, the skills path bridge, the `HOME`-pinned-to-volume layout, and the acceptance suite. Those are application-level fixes; they must not drift between the two deployments.

---

## Install

Requires Podman ≥ 4.4 (Quadlet), rootless, on the user account that owns the Podman storage.

```bash
git clone https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git
cd Woow_podman_pi_agent_package

# --format=docker is REQUIRED. SHELL and HEALTHCHECK have no OCI equivalent,
# so a default-format build silently produces an image whose health is never
# reported and whose `podman ps` status column stays blank.
podman build --format=docker \
  -t localhost/woow-podman-pi-agent-host:latest -f Containerfile.host-control .

# Install the units and start. Do NOT use sudo — rootless is the design.
./scripts/install.sh
```

`install.sh` refuses to run as root, verifies the Quadlet generator is
present, enables `loginctl` lingering, drops three units into
`~/.config/containers/systemd/` (`pi-agent.network`,
`pi-agent-data.volume`, `pi-web.container`) plus the two health-check
units under `~/.config/systemd/user/`, then waits for the container to
report `healthy`. It does **not** configure a proxy — that step is
[docs/downstream-nginx.md](docs/downstream-nginx.md).

First boot on a fresh volume downloads roughly 720MB of video tooling in the
background. **The UI is usable throughout** — the download does not gate
startup.

### Slim build

`--build-arg VIDEO_TOOLS=0` gives a ~700MB image with no ffmpeg, Chromium
libraries, CJK fonts or rclone. **Set `VIDEO_PIPELINE_ENABLED=false` in
`quadlet/pi-web.container` when you do**, or the entrypoint keeps invoking
a bootstrap that cannot succeed on that image.

### Uninstall

```bash
./scripts/uninstall.sh           # stops and removes the units, KEEPS the data volume
./scripts/uninstall.sh --purge   # also deletes pi-agent-data (sessions, skills, keys)
```

The downstream proxy's Proxy Host / server block is your job to clean up.

---

## First run

1. Point your same-host nginx / NPM at `127.0.0.1:30141` with the two
   required `proxy_set_header` lines from
   [docs/downstream-nginx.md](docs/downstream-nginx.md), then put
   authentication on that proxy.
2. Open the UI at whatever hostname the proxy serves.
3. Go to **Models**, add your provider (OpenRouter, Anthropic, OpenAI …) and
   paste the API key. The key is written to `models.json` on the volume
   with mode `600`.
4. Start a chat. The agent's working directory must be an *allowed root*:
   either an existing session cwd, or `$HOME/pi-cwd-YYYYMMDD` — pi-web
   creates and accepts those by pattern.

Configuring the provider through the UI rather than an environment variable
is deliberate: the key then lives on the volume with the rest of the state,
and rotating it does not mean editing a unit file and restarting.

---

## Layout

```
Containerfile              debian:bookworm-slim + Node 22 + pi-web, with build-time assertions
Containerfile.host-control OpenClaw host image built as localhost/woow-podman-pi-agent-host:latest
quadlet/
  pi-agent.network         private bridge, aardvark-dns resolves container names
  pi-agent-data.volume     the single named volume
  pi-web.container         the agent; publishes 127.0.0.1:30141 for a same-host reverse proxy
systemd/
  pi-web-health.service    oneshot: podman healthcheck run pi-web
  pi-web-health.timer      every 30s
patches/
  fix-unicode-space-paths.mjs   the CJK path fix, asserts every hunk
rootfs/usr/local/bin/
  pi                       launcher — resolves the transitively-installed CLI
  pi-agent-env.sh          the one definition of the runtime environment
  pi-web-start.sh          entrypoint: umask, permissions, skills bridge, TZ, video bootstrap
  video-tools-init.sh      sentinel-guarded, self-healing first-run install
scripts/install.sh         rootless installer (no auth, no proxy)
scripts/uninstall.sh       removal, volume kept by default
tests/acceptance.sh        the no-LLM acceptance suite
tests/chat.mjs             conversation harness — drives a real chat over pi-web's own API
tests/host-profile.sh      static assertions on the OpenClaw host-profile shape
docs/ARCHITECTURE.md       diagrams and the reasoning behind each decision
docs/downstream-nginx.md   the contract the same-host reverse proxy MUST satisfy
docs/plans/                dated design notes for the refactors that shaped this package
```

---

## Verifying a deployment

Two suites, cheap one first. `tests/` is not baked into the image, so copy it in.

```bash
# 1. Structural — no model calls, no cost. Runtime, persistence layout, HTTP
#    surface, the CJK regression test, the video pipeline, and the trust guard.
podman cp tests/. pi-web:/opt/tests/
podman exec pi-web bash /opt/tests/acceptance.sh

# 2. Functional — a real conversation through pi-web's own HTTP API,
#    asserting on the tool calls the agent actually made.
printf 'Create notes.md in the current directory containing the line "hello".\n' > /tmp/p.txt
podman cp /tmp/p.txt pi-web:/tmp/p.txt
podman exec pi-web node /opt/tests/chat.mjs /tmp/p.txt --json /tmp/out.json
```

Run the structural suite with a plain `podman exec`, **not** `bash -l`.
That is the point: the image bakes the runtime environment so a non-login
shell lands where the server lives, and running it under a login shell would
hide a regression in exactly that.

The suite no longer exercises the proxy path (there is no proxy in this
repo). What it still asserts is that the upstream Host/Origin guard is
refusing hostnames — a regression there would silently let a downstream
proxy operator ship a working deployment without the header rewrites and
break the moment upstream tightens the check again.

---

## Operating

```bash
podman ps --format '{{.Names}}\t{{.Status}}'   # health is reported here
journalctl --user -u pi-web -f                 # supervision events
podman logs -f pi-web                          # application output
podman exec -it pi-web bash                    # a shell in the agent's world
podman exec -it pi-web pi                      # the agent TUI
systemctl --user restart pi-web                # restart the container
```

To rebuild the video toolchain: set `RESET_VIDEO_TOOLS=true` in
`pi-web.container`, `systemctl --user daemon-reload && systemctl --user
restart pi-web`, wait for the reinstall, then set it back to `false`.
Left `true`, it re-downloads ~720MB on every restart.

---

## Security posture

Stated plainly.

**What this deployment does well.** It is rootless, so the agent's `bash`
tool runs as an unprivileged host user rather than as node root. It sets
`NoNewPrivileges`. pi-web publishes on `127.0.0.1` only. Credential files
are mode `600` from birth, not repaired after the fact.

**What it does not do.** There is no authentication in this repo. And
`GET /api/models-config` returns the provider API key in cleartext to any
caller that reaches the loopback endpoint. Measured, not inferred:

```
$ curl -H 'Host: localhost' http://127.0.0.1:30141/api/models-config
{"providers":{"openrouter":{"apiKey":"sk-or-v1-…","baseUrl":…
```

Upstream pi-web also has no path confinement, no approval gate, and no
`canUseTool` hook — the agent can read and write anywhere the container
user can, and run any command. These are upstream properties; no amount of
packaging fixes them.

**Therefore.** Treat `127.0.0.1:30141` as equivalent to a shell plus your
API key. The same-host reverse proxy is the credential boundary — see
[docs/downstream-nginx.md](docs/downstream-nginx.md). The proxy MUST rewrite
Host and Origin, MUST enforce authentication (Basic auth, CF Access, mTLS,
your choice), and SHOULD terminate TLS so the credentials do not cross the
LAN in base64.

Do NOT change `PublishPort` to `0.0.0.0` to "just test something". The
endpoint is unauthenticated and returns the provider key on demand; a widened
publish is a scrape target the second it exists.

---

## Documentation

- [Downstream reverse-proxy contract](docs/downstream-nginx.md) — the two
  headers, the auth requirement, and sample config for plain nginx + NPM
- [Architecture and design decisions](docs/ARCHITECTURE.md) — topology,
  the trust-guard problem, boot sequence, storage, k3s↔Podman mapping
- [繁體中文說明](README_zh-TW.md)

## License

MIT
