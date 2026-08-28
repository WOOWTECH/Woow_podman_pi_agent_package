#!/usr/bin/env bash
# Install the Woow Podman Pi Agent as rootless systemd user services.
#
# Run as the ordinary user that owns the Podman storage — NOT with sudo.
# Rootless is the point: the container's root maps to this unprivileged user.
#
# This installs pi-web only. There is no reverse proxy in this repo any more —
# authentication and Host/Origin rewriting are the responsibility of a
# same-host proxy (see docs/downstream-nginx.md). Without one in place, the
# published loopback port is unauthenticated and returns the provider API key
# in cleartext on /api/models-config.
#
#   ./install.sh              install and start pi-web
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${HOME}/.config/containers/systemd"
USER_UNIT_DIR="${HOME}/.config/systemd/user"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -ne 0 ] || die "Do not run this as root. Rootless Podman is the design."

command -v podman >/dev/null || die "podman not found"

# Quadlet arrived in Podman 4.4. Without it the .container files below are
# inert and nothing would start — fail loudly rather than leave a half-install.
say "Checking Podman and Quadlet"
podman --version
GEN=""
for p in /usr/lib/systemd/user-generators/podman-user-generator \
         /usr/libexec/podman/quadlet \
         /usr/lib/systemd/system-generators/podman-system-generator; do
  [ -x "$p" ] && { GEN="$p"; break; }
done
[ -n "${GEN}" ] || die "Quadlet generator not found. Podman >= 4.4 is required."
say "  Quadlet generator: ${GEN}"

# systemd user services stop at logout and do not start at boot unless the
# user lingers. This host's container runtime has restarted unprompted before;
# without lingering the stack would silently stay down afterwards.
say "Enabling lingering so the stack survives logout and reboot"
loginctl enable-linger "$(id -un)" || warn "enable-linger failed — the stack will stop at logout"

say "Installing OpenClaw host-profile units"
mkdir -p "${QUADLET_DIR}" "${USER_UNIT_DIR}"
for unit in pi-agent.network pi-agent-data.volume pi-web.container; do
  install -m 0644 "${REPO_DIR}/quadlet/${unit}" "${QUADLET_DIR}/${unit}"
  cmp -s "${REPO_DIR}/quadlet/${unit}" "${QUADLET_DIR}/${unit}" \
    || die "installed Quadlet differs from selected source: ${unit}"
  printf '    %s\n' "${unit}"
done
for unit in pi-web-health.service pi-web-health.timer; do
  install -m 0644 "${REPO_DIR}/systemd/${unit}" "${USER_UNIT_DIR}/${unit}"
  cmp -s "${REPO_DIR}/systemd/${unit}" "${USER_UNIT_DIR}/${unit}" \
    || die "installed user unit differs from selected source: ${unit}"
  printf '    %s\n' "${unit}"
done

say "Reloading systemd and starting"
systemctl --user daemon-reload
systemctl --user enable --now podman.socket
systemctl --user start pi-web.service
systemctl --user enable --now pi-web-health.timer

say "Waiting for pi-web to become healthy"
for i in $(seq 1 60); do
  status="$(podman inspect --format '{{.State.Health.Status}}' pi-web 2>/dev/null || echo starting)"
  [ "${status}" = "healthy" ] && { say "  healthy after ~$((i*5))s"; break; }
  [ "$i" -eq 60 ] && warn "still ${status} after 5 minutes — check: podman logs pi-web"
  sleep 5
done

cat <<EOF

$(say "Done")

  Loopback   http://127.0.0.1:30141    (unauthenticated — same-host proxy only)
  Logs       journalctl --user -u pi-web -f
             podman logs -f pi-web
  Shell      podman exec -it pi-web bash
  Stop       systemctl --user stop pi-web
  Status     podman ps --format '{{.Names}}\t{{.Status}}'
             systemctl --user status pi-web-health.timer

  Point your same-host nginx (or NPM) at 127.0.0.1:30141 with the two
  required proxy_set_header lines from docs/downstream-nginx.md, and put
  authentication (Basic auth, CF Access, …) on that proxy. Then configure
  the provider API key in the Models page once the UI is up.

EOF

warn "pi-web on 127.0.0.1:30141 has NO authentication and returns the provider"
warn "API key in cleartext on /api/models-config. Put a reverse proxy in front."
