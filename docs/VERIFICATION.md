# Acceptance record

**English** · [繁體中文](VERIFICATION_zh-TW.md)

What this deployment actually did, on 2026-08-06, on a rootless Podman host. Numbers are from the run, not from the design. Anything not measured is marked as such.

| | |
|---|---|
| Host | rootless Podman, LAN-published on `:30142` |
| Image | `ghcr.io/woowtech/woow-podman-pi-agent:latest`, built `--format=docker` |
| Components | pi-web 0.8.4 · pi-coding-agent 0.83.0 · Node v22.23.2 · Next.js 16.2.12 |
| Provider | OpenRouter — 340 models discovered |
| Test model | `deepseek/deepseek-v4-flash` (chosen for cost; every check is tool-result-based, not prose-based) |
| Structural suite | **25 passed, 0 failed, 2 notes** |

---

## 1. Structural checks

`tests/acceptance.sh`, run with a plain `podman exec` — deliberately **not** `bash -l`, since the point of the baked image ENV is that a non-login shell lands in the same environment as the server.

| Group | Asserted | Result |
|---|---|---|
| Runtime | `pi` resolves on PATH | 0.83.0 |
| | `HOME` pinned to the volume in a non-login shell | `/data/pi-agent/home` |
| | `PI_CODING_AGENT_DIR` set without sourcing profile.d | set |
| | timezone applied | CST |
| Persistence | `sessions/`, `skills/`, `home/` present | all present |
| | skills bridge is a symlink to the volume | `$HOME/.pi/agent/skills → /data/pi-agent/skills` |
| | `models.json` / `auth.json` mode | 600 |
| HTTP | `/api/home`, `/api/models`, `/api/skills`, `/api/plugins` | 200 × 4 |
| | provider configured | openrouter |
| CJK | U+3000 filename reads its own content | correct |
| | both space variants coexist as distinct files | 2 files |
| Video | sentinel, venv usable, ffmpeg, Playwright cache | present · 656 MB cache · Chromium 151 |
| Trust guard | hostname `Host`+`Origin` **through** nginx | 200 |
| | same headers **direct** to pi-web | 403 |

The two notes are the standing exposures in section 5. They are printed on every run rather than filed once, because a security property that is only written down stops being checked.

---

## 2. Conversations

Six runs through pi-web's own HTTP API — the same endpoints the browser calls, so a pass means the real path works. Every verdict is taken from `tool_execution_end` results and from on-disk state, never from the assistant's summary: a model saying "I successfully created the file" is not evidence.

| # | What it exercises | Tool calls | Duration | Tokens | Verdict |
|---|---|---|---|---|---|
| 1 | write → read → bash round trip | 3 | 25.1 s | 2,400 | file on disk, 17 bytes, contents exact |
| 2 | skill triggering | 4 | 31.2 s | 2,594 | read SKILL.md → ran `date` → wrote the artefact → emitted both marker tokens |
| 3 | **negative control** | 1 | 14.2 s | 1,856 | unrelated prompt did **not** activate the skill |
| 4 | CJK write/read through the agent's own tools | 4 | 24.1 s | 2,408 | U+3000 file 17 B, U+0020 file 11 B, each read returned its own content |
| 5 | MCP over HTTP, by hand | 7 | 112.2 s | 20,490 | see below |
| 6 | plugin-provided skill | 1 | 24.1 s | 1,940 | package skill read and executed |

Run 3 matters as much as run 2. A skill that fires on everything is not a working skill, and a suite that only tests activation cannot tell the difference.

### MCP over HTTP

pi 0.83.0 has no native MCP client, so the agent was asked to speak the protocol itself with `bash` and `curl`. It completed the full handshake unaided:

1. `initialize` → HTTP 200, `mcp-session-id: 7a9643f7…` recovered from the response headers
2. `notifications/initialized` → HTTP 202
3. `tools/list` → SSE response, `data:` prefixes stripped, **38 tools** enumerated
4. `tools/call health_check` → `Odoo MCP Server 1.28.1`, 38 tools / 4 resources / 11 prompts
5. wrote a 3,930-byte report of the exchange to the working directory

That this works without a client library is worth stating plainly: MCP here is a capability of the *model*, not of the runtime. It will be as reliable as the model is, which is a different risk profile from a built-in client.

### File and document surface

Checked directly, no model involved: `/api/file-index` listed both Unicode-space variants as separate entries; `/api/files?type=list`, `?type=read` and `?type=download` each returned the correct file and byte count for both.

One upstream cosmetic defect observed: `?type=list` reports `size: 0` and an empty `modified` for every entry, including files that are demonstrably non-empty. Display only — reads and downloads return correct data.

### Persistence

After a container restart: 9 session files, 2 skills (one user, one from a package), the plugin still `loaded`, the provider key and all 3 configured models intact, every working file present. Nothing was reconstructed by hand.

---

## 3. k3s ↔ Podman, per property

Both deployments were measured with the same suite, in the same order, so a difference is a porting defect rather than a difference in method.

| Property | k3s | Podman | Note |
|---|---|---|---|
| `pi` on PATH | pass | pass | same launcher |
| Model configuration via the UI | pass | pass | key stored on the volume, not in a unit file |
| Skill triggering + negative control | pass | pass | |
| Skills bridge | pass | pass | |
| Plugin install → UI → conversation | pass | pass | |
| CJK path handling | pass | pass | same patch, asserted at build and at runtime |
| File display / read / download | pass | pass | |
| Storage persistence across restart | pass | pass | PVC vs named volume |
| MCP over HTTP | pass | pass | agent-driven in both |
| Video pipeline | pass | pass | 656 MB cache, Chromium 151 |
| Shell access | ttyd sidecar, published, unauthenticated | `podman exec` | Podman better — one fewer exposed surface |
| Privilege | real root on the node | rootless, container root → host uid 1000 | Podman better |
| Health reporting | 3 Kubernetes probes | one `HEALTHCHECK` in `podman ps` | equivalent, simpler |
| Ingress restriction | `NetworkPolicy` on 30141/30142/7681 | pi-web publishes nothing | equivalent |
| Multi-node scheduling | yes | no | k3s only; unused in this deployment |

Functionally aligned. The Podman deployment is ahead on privilege and on attack surface; the k3s deployment is ahead only on a capability this workload does not use.

---

## 4. Defects found, and fixed

All five were found by running the deployment, not by reading it. None were visible in review.

| # | Defect | Why it mattered |
|---|---|---|
| 1 | `HOME` reached login shells only | `podman exec -it pi-web bash` — the command the README gave — ran with `HOME=/root`. A `pi install` from there writes into the ephemeral layer while the UI reads the volume: the install reports success and the skill never appears. Exactly the failure the skills bridge exists to prevent. Now baked as image ENV plus `BASH_ENV`. |
| 2 | `models.json` was 0644 while it held a key | The entrypoint chmodded at boot, but pi-web recreates the file at 0644 every time the Models page is saved. Measured: 644 immediately after configuring the provider, 600 again only after a restart — world-readable for precisely the period it contained a key. Fixed with `umask 077`. |
| 3 | Quadlet tried to pull a local-only image | `AutoUpdate=registry` on a tag that was never pushed is pure failure surface. Now `Pull=never` + `AutoUpdate=local`. |
| 4 | **The harness manufactured a bug** | Tool results were paired by arrival order, but the agent issues calls in parallel. The transcript showed `read "台灣 報告.txt"` returning the *other* file's contents — the exact signature of the upstream cross-read this image patches. On-disk state proved both files correct. Now correlated by `toolCallId`. A test that fabricates the failure it exists to detect is worse than no test. |
| 5 | The video bootstrap could not self-heal | Every guard tested `bin/python3`, but a venv that fails at ensurepip still has it — only `bin/pip` is missing. Creation was skipped, the next line called a pip that did not exist, the failure path exited 0, the sentinel was never written, and the identical sequence repeated on every boot. Now judged by `bin/pip`, and an invalid venv is deleted before recreating. |

Defect 4 has a consequence beyond this repo: the k3s round used the same correlation, so conclusions drawn there from a parallel tool batch should be re-read from disk state rather than from the transcript.

---

## 5. What remains exposed

Not fixed, because packaging cannot fix them. Listed so they are decided about rather than discovered.

**The provider key is readable by anyone who can reach the port.** Confirmed live, not inferred: an unauthenticated `GET /api/models-config` through the published port returned `"apiKey":"sk-or-v1-…"` in cleartext. Mitigations in this package — pi-web publishing no port of its own, mode 600 on disk — narrow *where* the endpoint can be reached from. They do not stop anyone who reaches `:30142`.

**There is no authentication anywhere.** Port 30142 is equivalent to handing out a shell. Put an authenticating proxy in front for anything beyond a trusted LAN, or bind `PublishPort` to `127.0.0.1`.

**The agent has no path confinement, no approval gate, and no `canUseTool` hook.** It reads and writes anywhere the container user can, and runs any command. Rootless narrows the blast radius to one unprivileged host account; it does not create a boundary inside that account.

**MCP depends on the model.** With no native client, protocol correctness is the model's responsibility on every call. A capable model handled it unaided; a weaker one may not, and the failure would look like a bad answer rather than a connection error.

---

## Reproducing

```bash
podman cp tests/. pi-web:/opt/tests/
podman exec pi-web bash /opt/tests/acceptance.sh          # structural, free

printf 'Create notes.md containing the line "hello".\n' > /tmp/p.txt
podman cp /tmp/p.txt pi-web:/tmp/p.txt
podman exec pi-web node /opt/tests/chat.mjs /tmp/p.txt --json /tmp/out.json
```

The structural suite costs nothing and should be run after every image rebuild. The conversation suite costs tokens; run it when the image, the pi-web version, or the provider changes.
