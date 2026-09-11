# Woow Podman Pi Agent

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![pi-web](https://img.shields.io/badge/pi--web-0.9.0-blue)](https://www.npmjs.com/package/@agegr/pi-web)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

`@agegr/pi-web` and the `pi` coding agent, packaged to run on **rootless
Podman** and supervised by **systemd via Quadlet**. It is the Podman sibling
of [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package)
— the same application surface, rebuilt for a single-host container runtime
instead of a Kubernetes cluster.

> **Read [Security posture](#security-posture) before you expose anything.**
> Since pi-web 0.9.0 the UI contains a browser terminal. Whoever reaches
> `127.0.0.1:30141` gets a shell that is equivalent to the account running
> the container, with that account's home directory mounted read-write.
> This package ships **no authentication**: a same-host reverse proxy with
> authentication must sit in front of it ([docs/downstream-nginx.md](docs/downstream-nginx.md)).

---

## What you get

| | |
|---|---|
| **Loopback endpoint** | `http://127.0.0.1:30141` on the Podman host — unauthenticated, reverse-proxy-only |
| **Agent** | `@earendil-works/pi-coding-agent` 0.85.1, imported as a library by pi-web 0.9.0 (no separate daemon) |
| **Browser terminal** | `/api/terminal` (node-pty, `SHELL=/bin/bash`) — a login shell inside the container |
| **CLI** | `pi` on `PATH` inside the container — `podman exec -it pi-web pi` drives the TUI |
| **Persistence** | one named volume, `pi-agent-data`, holding sessions, skills, config and `$HOME` |
| **Video pipeline** | ffmpeg, Playwright-Chromium, edge-tts, rclone, Noto CJK fonts (optional, see [Settings](#settings)) |
| **Supervision** | `systemd --user` units generated from Quadlet, `Restart=always`, lingering so they survive logout and reboot |

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

Requires rootless Podman ≥ 4.4 (Quadlet; tested with 4.9.3 on Ubuntu 24.04),
run as the account that owns the containers. Never use `sudo`.

```bash
git clone https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git
cd Woow_podman_pi_agent_package
./scripts/install.sh
```

That is the whole install. `scripts/install.sh`:

1. refuses root, checks Podman and the Quadlet generator, enables lingering;
2. creates `~/.config/pi-agent/pi-agent.env` from `config/pi-agent.env.example`
   (mode 0600) on the first run;
3. renders the units from `quadlet/` and `systemd/` with those settings and
   checks them with the Quadlet generator (`quadlet -dryrun`) and
   `systemd-analyze --user verify`;
4. **builds both images locally**: `Containerfile` as
   `localhost/woow-podman-pi-agent:<tag>`, then `Containerfile.host-control`
   on top of it as `localhost/woow-podman-pi-agent-host:<tag>`, always with
   `--format=docker` (the `SHELL` and `HEALTHCHECK` instructions have no OCI
   equivalent). A cold build takes 5-20 minutes and needs network; a rebuild of
   the same revision is fully cached;
5. installs `pi-agent.network`, `pi-agent-data.volume` and `pi-web.container`
   into `~/.config/containers/systemd/` and the health units into
   `~/.config/systemd/user/`, writing only files that changed;
6. starts what is new and **restarts pi-web when its unit or its image
   changed** (an unchanged re-run restarts nothing), waits for `healthy`, and
   runs `tests/smoke.sh`.

Every image is built before any unit is touched, so a failed build never
causes downtime. `./scripts/install.sh --build-only` builds the images and
stops, which is the way to prepare ahead of a maintenance window.

The tag is `<pi-web version>-r<package revision>` (today `0.9.0-r1`) and is
pinned in `quadlet/pi-web.container`; `Pull=never`, because the images exist
only on the host that built them. The base image is not published to any
registry; publishing it to GHCR (so hosts can skip the base build) is future
work.

First boot on a fresh volume downloads roughly 720MB of video tooling in the
background. **The UI is usable throughout.**

### Settings

`~/.config/pi-agent/pi-agent.env` is read by the install and upgrade scripts
only. They render the values into the installed units; systemd and Podman never
read the file. Change a value, then run `./scripts/install.sh` again.

| Key | Default | Effect |
|---|---|---|
| `PI_TZ` | `Asia/Taipei` | container timezone (`Environment=TZ=`) |
| `PI_VIDEO_TOOLS` | `true` | `false` builds the slim image (`--build-arg VIDEO_TOOLS=0`, about 700MB, no ffmpeg / Chromium libraries / CJK fonts / rclone), tags it `…-slim` and sets `VIDEO_PIPELINE_ENABLED=false` |

Everything account-specific in the unit uses systemd specifiers: `%h` for the
home directory and `%t` for `XDG_RUNTIME_DIR`. The same unit works for any user
and any uid; nothing needs hand-editing.

### Profiles

| Profile | Status | What pi-web gets |
|---|---|---|
| **host-control** (default, the only one today) | shipped | the owning account's home at `/host$HOME` (rw), its rootless Podman socket, its user systemd bus. The agent can manage every container of that account. |
| slim / no host-control | planned | the base image without the host mounts. |

### Upgrade

```bash
git pull
./scripts/upgrade.sh           # hot data export, build, switch, smoke; automatic rollback
```

`upgrade.sh` exports `pi-agent-data`, builds the newly pinned tag while the old
pi-web keeps serving, installs, and runs the smoke test. If the new image does
not come up healthy it puts the previous units back and restarts on the
previous image, which is kept until `./scripts/upgrade.sh --prune`.
`--no-backup` skips the export.

### Backup and restore

```bash
./scripts/backup.sh                 # cold: stops pi-web for the export, then starts it
./scripts/backup.sh --hot           # no stop; a session written meanwhile may be torn
./scripts/restore.sh ~/backups/pi-agent/pi-agent-data-<ts>.tar
```

Backups land in `~/backups/pi-agent/` as 0600 files in a 0700 directory, each
with a `.sha256`. **They contain `models.json`, and therefore the provider API
key.** `restore.sh` verifies the checksum, asks for confirmation, exports the
current contents first, then replaces the volume and runs the smoke test.

### Uninstall

```bash
./scripts/uninstall.sh                 # stops and removes the units; KEEPS the data volume
./scripts/uninstall.sh --purge --yes   # also deletes pi-agent-data, after a final export
```

The env file, the images and the reverse-proxy configuration are never deleted.

### Converging a hand-edited install

Hosts installed with an earlier version of this repo (toypark1234, openclaw)
have `pi-web.container` copied verbatim and sometimes edited by hand
(`/home/<user>` in two lines). Converge them with:

```bash
cd Woow_podman_pi_agent_package && git pull
./scripts/install.sh --build-only   # optional, ahead of time: no service impact
./scripts/install.sh                # adopts the old units, keeps copies, restarts pi-web once
```

The old files are copied to `~/.local/state/woow-quadlet/pi-agent/` (`replaced/`,
`adopted/`) before they are overwritten. Mounts, environment, network, volume
and port stay the same; only the image tag changes (`:latest` → `:0.9.0-r1`)
and the auto-update label goes. To roll back, copy the old files back and run
`systemctl --user daemon-reload && systemctl --user restart pi-web.service`;
the old `:latest` image is still there.

---

## First run

1. Put a reverse proxy **with authentication** in front of pi-web. On a host
   running [Woow_podman_nginxpm](https://github.com/WOOWTECH/Woow_podman_nginxpm),
   set `NPM_PI_WEB_FRONT=true` there, then create a proxy host with Forward
   Hostname `pi-web`, port `30141` and an access list. Plain nginx: see
   [docs/downstream-nginx.md](docs/downstream-nginx.md).
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
Containerfile              debian:bookworm-slim + Node 22 + pi-web 0.9.0, multi-stage node-pty build
Containerfile.host-control host-control layer (podman + systemd clients) on the local base
config/pi-agent.env.example   per-host settings, installed to ~/.config/pi-agent/pi-agent.env
quadlet/
  pi-agent.network         private bridge; aardvark-dns resolves container names
  pi-agent-data.volume     the single named volume
  pi-web.container         the agent; publishes 127.0.0.1:30141 for a same-host reverse proxy
  render-vars              the only variables install.sh may substitute into the units
systemd/
  pi-web-health.service    oneshot: podman healthcheck run pi-web
  pi-web-health.timer      every 30s (needed where podman's own health timer never registers)
patches/
  fix-unicode-space-paths.mjs   the CJK path fix, asserts every hunk
rootfs/usr/local/bin/      pi launcher, runtime environment, entrypoint, video bootstrap
scripts/
  install.sh               build images, render, install, restart on change, smoke
  upgrade.sh               backup, build, switch, smoke, automatic rollback
  backup.sh restore.sh     pi-agent-data export / import
  uninstall.sh             removal, volume kept unless --purge
  render-args.sh           values computed from the env file (shared with tests/dryrun.sh)
  lib/quadlet-lib.sh       vendored WOOWTECH Quadlet library (do not edit; CI checks its hash)
tests/
  dryrun.sh                render + quadlet -dryrun + systemd-analyze verify (CI)
  dryrun.local.sh          pi-agent invariants on the generated podman command (CI)
  host-profile.sh          static checks on the host-control profile (CI)
  smoke.sh                 post-install checks on a real host
  acceptance.sh chat.mjs   the no-LLM acceptance suite and the conversation harness
docs/                      architecture, downstream proxy contract, Armbian notes, history
```

CI (`.github/workflows/quadlet-ci.yml`, ubuntu-24.04 with podman 4.9.3) runs
`tests/dryrun.sh` and `shellcheck`, and verifies the vendored library's hash.

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
bash tests/smoke.sh                            # post-install checks
```

To rebuild the video toolchain once: set `RESET_VIDEO_TOOLS=true` in the
**installed** `~/.config/containers/systemd/pi-web.container`, run
`systemctl --user daemon-reload && systemctl --user restart pi-web`, wait for
the reinstall, then run `./scripts/install.sh`: it puts the rendered unit back
(`RESET_VIDEO_TOOLS=false`, with a copy of your edit kept) and restarts.

---

## Security posture

Stated plainly.

**The browser terminal is a root-equivalent shell for the account.** pi-web
0.9.0 added `/api/terminal`, which spawns a login shell through node-pty. The
shell runs as root *inside* the container; rootless Podman maps that to the
host account that runs the unit. With the host-control mounts that account's
entire home directory is mounted read-write at `/host$HOME`, its rootless
Podman socket is reachable (every container of the account, this one included)
and so is its user systemd. In practice, anyone who reaches the terminal can:

- read and change every file the account owns: `~/.ssh`, other services' data
  and volumes under `~/.local/share/containers`, tunnel tokens;
- start, stop, exec into and replace every container of that account;
- install persistent user units;
- read the provider API key: `GET /api/models-config` returns it in cleartext,
  and so does `cat /data/pi-agent/models.json`.

If the account is in `sudo`, one password away from host root. None of this is
a bug the packaging can fix: upstream pi-web has no authentication, no path
confinement, no approval gate and no `canUseTool` hook.

**Therefore authentication must be enforced downstream**, by the same-host
reverse proxy, on every path:

- NPM ([Woow_podman_nginxpm](https://github.com/WOOWTECH/Woow_podman_nginxpm)
  with `NPM_PI_WEB_FRONT=true`) plus an access list with Basic auth, and
- for a public hostname, **Cloudflare Access** in front of it as a second,
  independent layer. Basic auth alone is one password between the Internet
  and a shell.

`PI_WEB_PASSWORD` (pi-web's own Basic auth) stays unwired on purpose: the
owner's decision is that authentication lives downstream.

**Any path to 127.0.0.1:30141 that skips the proxy is an unauthenticated
shell.** That includes a tailnet `tailscale serve` forward to
`127.0.0.1:30141` (every tailnet member gets a shell), an `ssh -L` shared with
other people, and another container on the host that can reach the host's
loopback. `scripts/install.sh` warns about a non-loopback listener on 30141 and
about a woow-tailscale serve forward to it. Never change `PublishPort` to
`0.0.0.0` "just to test something".

**What this deployment does well.** It is rootless, so a container escape
lands on an unprivileged account rather than host root. `NoNewPrivileges` is
set. pi-web publishes on `127.0.0.1` only. The image carries no compiler.
Credential files are mode `600` from birth, and backups are 0600 in 0700
directories.

---

## Documentation

- [Downstream reverse-proxy contract](docs/downstream-nginx.md) — the two
  headers, the auth requirement, the NPM pi-web front and a plain-nginx sample
- [Architecture and design decisions](docs/ARCHITECTURE.md) — topology,
  the trust-guard problem, boot sequence, storage, k3s↔Podman mapping
- [Armbian / arm64 notes](docs/armbian-arm64-deployment.md) — podman-static
  under `/usr/local`, cgroupfs, health timer
- [繁體中文說明](README_zh-TW.md)

## License

MIT
