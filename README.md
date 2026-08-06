# Woow Podman Pi Agent

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![pi-web](https://img.shields.io/badge/pi--web-0.8.4-blue)](https://www.npmjs.com/package/@agegr/pi-web)
[![acceptance](https://img.shields.io/badge/acceptance-25%20passed%20%C2%B7%200%20failed-brightgreen)](docs/VERIFICATION.md)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

`@agegr/pi-web` and the `pi` coding agent, packaged to run on **rootless Podman** and supervised by **systemd via Quadlet**. It is the Podman sibling of [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) — the same application surface, rebuilt for a single-host container runtime instead of a Kubernetes cluster.

The deployment has been run and measured, not just designed: 25 structural checks, six conversations against a real provider, and a per-property comparison against the k3s deployment. See the [acceptance record](docs/VERIFICATION.md).

> **There is no authentication in front of this deployment.** Whoever can reach the published port gets a coding agent with a `bash` tool running as your user — and can read your provider API key in cleartext. Both were confirmed on a live deployment. Read [Security posture](#security-posture) before exposing it beyond a trusted LAN.

---

## What you get

| | |
|---|---|
| **Web UI** | `http://<host>:30142` — chat, model configuration, skills, plugins, file browser |
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
| `ttyd` sidecar + password Secret | *(removed)* | On Kubernetes a browser terminal was the only practical route to a shell in the pod. Under Podman, `podman exec -it pi-web bash` is the native answer. The sidecar was an unauthenticated shell on a published port; deleting it removes an entire attack surface. |
| `kubectl`, `s6-overlay`, `bashio` in the image | *(removed)* | systemd supervises. There is no second init to reconcile. |
| three Kubernetes probes (`startup`/`readiness`/`liveness`) | one native `HEALTHCHECK` | Podman honours `HEALTHCHECK` and reports it in `podman ps`. No need to emulate a model the runtime does not have. |
| runs as real `root` on the node | rootless — container `root` maps to host uid 1000 | A container escape lands on an unprivileged user instead of the host root. This is the single biggest security improvement of the Podman version. |
| Helm chart, `NetworkPolicy`, PVC | Quadlet `.container` / `.network` / `.volume` | Native units, readable by `systemctl --user`, no templating layer between you and the runtime. |
| Cloudflare Tunnel sidecar | *(removed)* | The Podman host already runs its own tunnel container for every service. Adding a second one here would duplicate it. |

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
  -t ghcr.io/woowtech/woow-podman-pi-agent:latest -f Containerfile .

# Install the units and start. Do NOT use sudo — rootless is the design.
./scripts/install.sh
```

`install.sh` refuses to run as root, verifies the Quadlet generator is present, enables `loginctl` lingering, installs `config/nginx.conf` to `~/.config/pi-agent/`, drops the four units into `~/.config/containers/systemd/`, then waits for the container to report `healthy`.

First boot on a fresh volume downloads roughly 720MB of video tooling in the background. **The UI is usable throughout** — the download does not gate startup.

### Slim build

`--build-arg VIDEO_TOOLS=0` gives a ~700MB image with no ffmpeg, Chromium libraries, CJK fonts or rclone. **Set `VIDEO_PIPELINE_ENABLED=false` in `quadlet/pi-web.container` when you do**, or the entrypoint keeps invoking a bootstrap that cannot succeed on that image.

### Uninstall

```bash
./scripts/uninstall.sh           # stops and removes the units, KEEPS the data volume
./scripts/uninstall.sh --purge   # also deletes pi-agent-data (sessions, skills, keys)
```

---

## First run

1. Open `http://<host-ip>:30142`.
2. Go to **Models**, add your provider (OpenRouter, Anthropic, OpenAI …) and paste the API key. The key is written to `models.json` on the volume with mode `600`.
3. Start a chat. The agent's working directory must be an *allowed root*: either an existing session cwd, or `$HOME/pi-cwd-YYYYMMDD` — pi-web creates and accepts those by pattern.

Configuring the provider through the UI rather than an environment variable is deliberate: the key then lives on the volume with the rest of the state, and rotating it does not mean editing a unit file and restarting.

---

## Layout

```
Containerfile              debian:bookworm-slim + Node 22 + pi-web, with build-time assertions
config/nginx.conf          the Host/Origin shim — see Architecture
quadlet/
  pi-agent.network         private bridge, aardvark-dns resolves container names
  pi-agent-data.volume     the single named volume
  pi-web.container         the agent; publishes no host port
  nginx.container          the only published port (30142)
patches/
  fix-unicode-space-paths.mjs   the CJK path fix, asserts every hunk
rootfs/usr/local/bin/
  pi                       launcher — resolves the transitively-installed CLI
  pi-agent-env.sh          the one definition of the runtime environment
  pi-web-start.sh          entrypoint: umask, permissions, skills bridge, TZ, video bootstrap
  video-tools-init.sh      sentinel-guarded, self-healing first-run install
scripts/install.sh         rootless installer
scripts/uninstall.sh       removal, volume kept by default
tests/acceptance.sh        the no-LLM acceptance suite
tests/chat.mjs             conversation harness — drives a real chat over pi-web's own API
docs/ARCHITECTURE.md       diagrams and the reasoning behind each decision
docs/VERIFICATION.md       what the deployment actually did, with numbers
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

Run the structural suite with a plain `podman exec`, **not** `bash -l`. That is the point: the image bakes the runtime environment so a non-login shell lands where the server lives, and running it under a login shell would hide a regression in exactly that.

`chat.mjs` asserts on `toolCalls[]`, not on the assistant's prose. A model that says "I successfully created the file" is not evidence; the tool result is. It defaults to `deepseek/deepseek-v4-flash` over OpenRouter — override with `PI_TEST_MODEL` / `PI_TEST_PROVIDER`.

Both suites are comparable with the k3s deployment: same properties, same order. A difference between the two rounds is therefore a porting defect, not a difference in how they were measured. The [acceptance record](docs/VERIFICATION.md) has the per-property comparison.

---

## Operating

```bash
podman ps --format '{{.Names}}\t{{.Status}}'   # health is reported here
journalctl --user -u pi-web -f                 # supervision events
podman logs -f pi-web                          # application output
podman exec -it pi-web bash                    # a shell in the agent's world
podman exec -it pi-web pi                      # the agent TUI
systemctl --user restart pi-web                # nginx follows automatically (PartOf=)
```

To rebuild the video toolchain: set `RESET_VIDEO_TOOLS=true` in `pi-web.container`, `systemctl --user daemon-reload && systemctl --user restart pi-web`, wait for the reinstall, then set it back to `false`. Left `true`, it re-downloads ~720MB on every restart.

---

## Security posture

Stated plainly, because the honest version is short.

**What this deployment does well.** It is rootless, so the agent's `bash` tool runs as an unprivileged host user rather than as node root. It sets `NoNewPrivileges`. pi-web itself publishes no host port. Credential files are mode `600` from birth, not repaired after the fact.

**What it does not do.** There is no authentication, anywhere. And `GET /api/models-config` returns the provider API key in cleartext to an unauthenticated caller — measured through the published port, not inferred:

```
$ curl -H 'Host: pi.example.com' http://<host>:30142/api/models-config
{"providers":{"openrouter":{"apiKey":"sk-or-v1-…","baseUrl":…
```

Upstream pi-web also has no path confinement, no approval gate, and no `canUseTool` hook — the agent can read and write anywhere the container user can, and run any command. These are upstream properties; no amount of packaging fixes them. What this package does is narrow *where* the endpoint can be reached from, which is not the same as protecting it.

**Therefore.** Treat port 30142 as equivalent to handing out a shell and your API key together. For anything beyond a trusted LAN, put an authenticating proxy in front of it — the Podman host's existing Cloudflare Tunnel plus Cloudflare Access is the intended path, which is exactly why this package ships no tunnel of its own. To make it local-only, change `PublishPort` in `quadlet/nginx.container` to `127.0.0.1:30142:30142`.

---

## Documentation

- [Architecture and design decisions](docs/ARCHITECTURE.md) — topology, the trust-guard problem, boot sequence, storage, k3s↔Podman mapping
- [Acceptance record](docs/VERIFICATION.md) — what was measured, the defects it found, and what remains exposed
- [繁體中文說明](README_zh-TW.md)

## License

MIT
