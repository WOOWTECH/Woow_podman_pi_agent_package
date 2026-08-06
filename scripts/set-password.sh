#!/usr/bin/env bash
# Set, rotate or remove the password that guards the web UI.
#
#   ./set-password.sh                 prompt for a password (twice)
#   ./set-password.sh --generate      generate a strong one and print it once
#   ./set-password.sh --user alice    change the username too (default: woow)
#   ./set-password.sh --disable       remove authentication entirely
#
# Writes ~/.config/pi-agent/htpasswd and ~/.config/pi-agent/auth.conf, both of
# which nginx.container mounts read-only, then restarts nginx.
#
# This is the Podman equivalent of the add-on's password field: there is no
# settings page here, so the setting is a command. The password is never
# stored in a unit file, never passed as a command-line argument (which would
# put it in every `ps` on the host), and never written to disk in the clear —
# only its hash is.
set -euo pipefail

CONFIG_DIR="${HOME}/.config/pi-agent"
HTPASSWD="${CONFIG_DIR}/htpasswd"
AUTH_CONF="${CONFIG_DIR}/auth.conf"
NGINX_IMAGE="docker.io/library/nginx:1.27-alpine"
REALM="Woow Pi Agent"

USER_NAME="woow"
MODE="prompt"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --generate) MODE="generate"; shift ;;
    --disable)  MODE="disable";  shift ;;
    --stdin)    MODE="stdin";    shift ;;
    --user)     USER_NAME="${2:?--user needs a name}"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

# ':' separates the username from the hash in an htpasswd file, so a colon in
# the username would silently truncate it. Passwords may contain anything.
case "${USER_NAME}" in
  *:*|"") die "username must be non-empty and must not contain ':'" ;;
esac

mkdir -p "${CONFIG_DIR}"

reload_nginx() {
  if systemctl --user list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl --user restart nginx.service 2>/dev/null \
      || warn "could not restart nginx.service — restart it yourself for this to take effect"
  elif podman container exists pi-agent-nginx 2>/dev/null; then
    podman restart pi-agent-nginx >/dev/null \
      || warn "could not restart pi-agent-nginx"
  else
    warn "nginx is not running — the new setting applies at next start"
  fi
}

if [ "${MODE}" = "disable" ]; then
  : > "${HTPASSWD}"
  chmod 600 "${HTPASSWD}"
  cat > "${AUTH_CONF}" <<'EOF'
# Authentication is DISABLED. Anyone who can reach the published port gets a
# coding agent with a shell, and can read the provider API key in cleartext
# from /api/models-config. Re-enable with: ./scripts/set-password.sh
EOF
  chmod 644 "${AUTH_CONF}"
  reload_nginx
  warn "authentication DISABLED — the UI is now open to anyone who can reach the port"
  exit 0
fi

# --- obtain the password ------------------------------------------------------
PASSWORD=""
GENERATED=0

case "${MODE}" in
  generate)
    # 24 characters from the alphanumeric set. Restricted to alphanumerics on
    # purpose: this password gets pasted into browser dialogs and copied
    # between devices, and a shell-quoting accident is a likelier failure than
    # the entropy difference matters. 24 alphanumerics is ~143 bits.
    PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    GENERATED=1
    ;;
  stdin)
    IFS= read -r PASSWORD || true
    ;;
  prompt)
    [ -t 0 ] || die "not a terminal — use --generate or --stdin"
    printf 'Password for user "%s": ' "${USER_NAME}"; IFS= read -rs PASSWORD; echo
    printf 'Again: '; IFS= read -rs CONFIRM; echo
    [ "${PASSWORD}" = "${CONFIRM}" ] || die "passwords did not match"
    ;;
esac

[ -n "${PASSWORD}" ] || die "empty password"
[ "${#PASSWORD}" -ge 8 ] || die "password must be at least 8 characters"

# --- hash it ------------------------------------------------------------------
# SHA-512 crypt ($6$). nginx verifies it through the system crypt(), and musl's
# crypt in nginx:alpine supports $6$ — verified, not assumed. APR1 would also
# work but is MD5-based and there is no reason to choose it.
#
# Three ways to compute it, in order of preference. All three feed the password
# on stdin so it never appears in the process table, and all three strip the
# trailing newline identically, so they cannot disagree about what the password
# was.
SALT=$(LC_ALL=C tr -dc 'A-Za-z0-9./' < /dev/urandom | head -c 16)

hash_password() {
  if command -v openssl >/dev/null 2>&1; then
    printf '%s\n' "${PASSWORD}" | openssl passwd -6 -salt "${SALT}" -stdin
  elif podman container exists pi-agent-nginx 2>/dev/null; then
    printf '%s\n' "${PASSWORD}" | podman exec -i pi-agent-nginx busybox cryptpw -m sha512 -S "${SALT}"
  else
    printf '%s\n' "${PASSWORD}" | podman run --rm -i "${NGINX_IMAGE}" busybox cryptpw -m sha512 -S "${SALT}"
  fi
}

HASH=$(hash_password) || die "could not hash the password"
case "${HASH}" in
  \$6\$*) : ;;
  *) die "unexpected hash format: ${HASH%%\$*}... (expected \$6\$)" ;;
esac

# --- write --------------------------------------------------------------------
# Create with the right mode before writing, not after. A umask-dependent
# moment where the file is world-readable is exactly the defect this package
# already fixed once in models.json.
umask 077
: > "${HTPASSWD}"
chmod 600 "${HTPASSWD}"
printf '%s:%s\n' "${USER_NAME}" "${HASH}" > "${HTPASSWD}"

cat > "${AUTH_CONF}" <<EOF
# Generated by scripts/set-password.sh — edit that, not this.
auth_basic "${REALM}";
auth_basic_user_file /etc/nginx/htpasswd;
EOF
chmod 644 "${AUTH_CONF}"

reload_nginx

say "authentication enabled for user \"${USER_NAME}\""
if [ "${GENERATED}" = "1" ]; then
  cat <<EOF

  username  ${USER_NAME}
  password  ${PASSWORD}

  Write this down now. Only the hash is stored; there is no way to recover it.
  Lost it? Run this script again.

EOF
fi
cat <<'EOF'
  Note that Basic auth over plain HTTP sends the password base64-encoded on
  every request. Encoding is not encryption: anyone capturing traffic on the
  LAN segment can read it. For remote access use a TLS path (the host's
  Cloudflare Tunnel) rather than exposing this port.

  This protects the network edge, not the inside. The agent can still read
  the provider key from the volume and reach pi-web directly on the container
  network, neither of which passes through nginx.
EOF
