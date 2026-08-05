#!/usr/bin/env bash
# Install the Woow Podman Pi Agent as rootless systemd user services.
#
# Run as the ordinary user that owns the Podman storage — NOT with sudo.
# Rootless is the point: the container's root maps to this unprivileged user.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/pi-agent"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

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

say "Installing nginx config to ${CONFIG_DIR}"
mkdir -p "${CONFIG_DIR}"
install -m 0644 "${REPO_DIR}/config/nginx.conf" "${CONFIG_DIR}/nginx.conf"

say "Installing Quadlet units to ${QUADLET_DIR}"
mkdir -p "${QUADLET_DIR}"
for unit in pi-agent.network pi-agent-data.volume pi-web.container nginx.container; do
  install -m 0644 "${REPO_DIR}/quadlet/${unit}" "${QUADLET_DIR}/${unit}"
  printf '    %s\n' "${unit}"
done

say "Reloading systemd and starting"
systemctl --user daemon-reload
systemctl --user start pi-web.service
systemctl --user start nginx.service

say "Waiting for pi-web to become healthy"
for i in $(seq 1 60); do
  status="$(podman inspect --format '{{.State.Health.Status}}' pi-web 2>/dev/null || echo starting)"
  [ "${status}" = "healthy" ] && { say "  healthy after ~$((i*5))s"; break; }
  [ "$i" -eq 60 ] && warn "still ${status} after 5 minutes — check: podman logs pi-web"
  sleep 5
done

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

$(say "Done")

  Web UI     http://${IP:-<host-ip>}:30142
  Logs       journalctl --user -u pi-web -f
             podman logs -f pi-web
  Shell      podman exec -it pi-web bash
  Stop       systemctl --user stop nginx pi-web
  Status     podman ps --format '{{.Names}}\t{{.Status}}'

  There is NO authentication in front of this. Anyone who can reach
  port 30142 on this LAN gets a coding agent with a shell. Configure the
  provider API key in the Models page once the UI is up.

EOF
