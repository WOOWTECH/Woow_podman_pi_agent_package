#!/usr/bin/env bash
# Install the Woow Podman Pi Agent as rootless systemd user services.
#
# Run as the ordinary user that owns the Podman storage — NOT with sudo.
# Rootless is the point: the container's root maps to this unprivileged user.
#
#   ./install.sh              enable password protection (generated, shown once)
#   ./install.sh --no-auth    leave the UI open to anyone who can reach the port
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/pi-agent"
WANT_AUTH=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-auth) WANT_AUTH=0; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

say "Installing nginx config to ${CONFIG_DIR}"
mkdir -p "${CONFIG_DIR}"
install -m 0644 "${REPO_DIR}/config/nginx.conf" "${CONFIG_DIR}/nginx.conf"

# --- Authentication -----------------------------------------------------------
# Done BEFORE the units are installed, for two reasons. The port is never
# briefly open on a fresh install; and set-password.sh finds no nginx.service
# yet, so it does not try to restart nginx at a point where pi-web is not
# listening — nginx resolves the pi-web name once at startup and would fail.
if [ "${WANT_AUTH}" = "1" ]; then
  if [ -s "${CONFIG_DIR}/htpasswd" ]; then
    say "Password already configured — keeping it (change it with scripts/set-password.sh)"
    [ -f "${CONFIG_DIR}/auth.conf" ] || die "htpasswd exists but auth.conf does not; run scripts/set-password.sh"
  else
    say "Generating a password for the web UI"
    "${REPO_DIR}/scripts/set-password.sh" --generate
  fi
else
  say "Disabling authentication (--no-auth)"
  "${REPO_DIR}/scripts/set-password.sh" --disable
fi

say "Installing Quadlet units to ${QUADLET_DIR}"
mkdir -p "${QUADLET_DIR}"
for unit in pi-agent.network pi-agent-data.volume pi-web.container nginx.container; do
  install -m 0644 "${REPO_DIR}/quadlet/${unit}" "${QUADLET_DIR}/${unit}"
  printf '    %s\n' "${unit}"
done

say "Reloading systemd and starting"
systemctl --user daemon-reload
systemctl --user start pi-web.service

say "Waiting for pi-web to become healthy"
for i in $(seq 1 60); do
  status="$(podman inspect --format '{{.State.Health.Status}}' pi-web 2>/dev/null || echo starting)"
  [ "${status}" = "healthy" ] && { say "  healthy after ~$((i*5))s"; break; }
  [ "$i" -eq 60 ] && warn "still ${status} after 5 minutes — check: podman logs pi-web"
  sleep 5
done

# nginx last: it resolves the pi-web container name at startup, so starting it
# before pi-web exists would leave it proxying to nothing.
systemctl --user start nginx.service

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

$(say "Done")

  Web UI     http://${IP:-<host-ip>}:30142
  Logs       journalctl --user -u pi-web -f
             podman logs -f pi-web
  Shell      podman exec -it pi-web bash
  Stop       systemctl --user stop nginx pi-web
  Status     podman ps --format '{{.Names}}\t{{.Status}}'
  Password   ./scripts/set-password.sh          (change)
             ./scripts/set-password.sh --disable (remove)

  Configure the provider API key in the Models page once the UI is up.

EOF

if [ "${WANT_AUTH}" != "1" ]; then
  warn "No authentication: anyone who can reach port 30142 gets a coding agent"
  warn "with a shell, and can read the provider API key in cleartext."
fi
