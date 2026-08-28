# Remove the in-repo nginx sidecar

Status: implemented on branch `remove-nginx-sidecar`, 2026-08-29.

## Motivation

The sidecar existed for two reasons: (a) rewriting Host/Origin so pi-web's
`isApiRequestAllowed()` would let a hostname-fronted request through, and
(b) providing HTTP Basic auth in front of an application that has none.

Both jobs are now expected to move to the shared same-host reverse proxy
(nginx / NPM) that this deployment already runs for its other services. The
sidecar is redundant, and shipping our own auth mechanism means two places
where credentials can drift.

## Decisions

1. **Hard removal, no `--with-sidecar` flag.** One deployment currently
   uses this repo; a backward-compat flag would be pure debt.
2. **Keep `pi-agent.network` as the private bridge.** Isolation from other
   containers on the host is worth keeping.
3. **pi-web publishes to `127.0.0.1:30141`.** The downstream proxy runs on
   the same host and reaches it via loopback; nothing on the LAN can reach it.
4. **Delete `scripts/set-password.sh` entirely.** Credential management
   moves to the downstream proxy (NPM has a GUI; plain nginx uses htpasswd).
5. **Health check unchanged.** `pi-web-health.timer` calls
   `podman healthcheck run pi-web`, which is internal to the container and
   has no dependency on any proxy.

## Files changed

Deleted
- `quadlet/nginx.container`
- `config/nginx.conf` (and the now-empty `config/` directory)
- `scripts/set-password.sh`

Modified
- `quadlet/pi-web.container` — comment rewritten, `PublishPort=127.0.0.1:30141:30141` added
- `scripts/install.sh` — removed auth section, `--no-auth` flag, nginx quadlet install, nginx start
- `scripts/uninstall.sh` — removed `nginx.service` stop and `nginx.container` cleanup
- `tests/host-profile.sh` — assertions updated to the sidecar-less shape
- `tests/acceptance.sh` — section 6 rewritten (no proxy tests; guard still asserted)
- `README.md`, `README_zh-TW.md`, `docs/ARCHITECTURE.md` — sidecar language removed, downstream contract linked

Added
- `docs/downstream-nginx.md` — the contract downstream proxies must satisfy, with sample nginx and NPM config

## Migration path (this host, .197)

Follow in order — the port stops answering between step 4 and step 5, so
plan a short outage:

1. In your downstream nginx / NPM: add a Proxy Host pointing at
   `127.0.0.1:30141` with the required headers from
   `docs/downstream-nginx.md` and an Access List for authentication.
   Do NOT enable it yet.
2. `systemctl --user stop nginx.service` (the sidecar), confirm the port
   `127.0.0.1:30142` stops answering.
3. Enable the downstream proxy; verify a request through it reaches pi-web
   and the auth prompt fires.
4. `systemctl --user disable nginx.service`
5. `git checkout remove-nginx-sidecar && git pull` on the deployment host,
   then `./scripts/install.sh` (idempotent — re-installs the three
   remaining units, restarts pi-web with the new PublishPort).
6. `rm ~/.config/containers/systemd/nginx.container` (install.sh no longer
   installs it, but a stale copy from the sidecar-era install would still
   be there).
7. `podman rm -f pi-agent-nginx`
8. Back up then delete leftover credentials:
   `mv ~/.config/pi-agent/{nginx.conf,auth.conf,htpasswd,initial-credentials} ~/pi-agent-sidecar-backup/`
9. Tailscale-serve: the old forward `--tcp=30142` (if any) can be dropped;
   add a new forward to whatever port the downstream proxy publishes.

## Rollback

The refactor lives on a branch. To revert cleanly: `git checkout main`,
re-run `./scripts/install.sh`, restore the four files under
`~/.config/pi-agent/` from backup, `systemctl --user start nginx.service`.
