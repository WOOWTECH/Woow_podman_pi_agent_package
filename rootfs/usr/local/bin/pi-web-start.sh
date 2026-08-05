#!/bin/bash
# Entrypoint for the pi-web container.
#
# Replaces the add-on's s6 `pi-web/run`. Everything bashio used to read from
# the Supervisor's options.json now arrives as plain env from the Quadlet unit.
set -euo pipefail

# Both streams to stdout so crash traces land in `podman logs` next to the
# ordinary output instead of being split across two channels.
exec 2>&1

# shellcheck source=/dev/null
source /usr/local/bin/pi-agent-env.sh

DATA_DIR="${PI_AGENT_DATA_DIR:-/data/pi-agent}"
log() { printf '[pi-web] %s\n' "$*"; }

mkdir -p "${DATA_DIR}/sessions" "${DATA_DIR}/home" "${DATA_DIR}/skills" "${DATA_DIR}/rclone"

# --- Credential file modes ----------------------------------------------------
# models.json holds the provider API key in plaintext and pi-web creates it 0644
# on a volume any `podman exec -it pi-web bash` lands on as root. Tightened on
# every boot because pi-web rewrites the file whenever the Models page is saved.
#
# This is defence in depth ONLY. It does not fix the two real problems, which
# are upstream: GET /api/models-config returns the key unredacted and
# unauthenticated, and the agent's own read tool can open the file. See README.
for f in models.json models-store.json auth.json rclone/rclone.conf; do
  [ -f "${DATA_DIR}/${f}" ] && chmod 600 "${DATA_DIR}/${f}" || true
done

# --- Skills path bridge -------------------------------------------------------
# pi-web reads skills from ${PI_CODING_AGENT_DIR}/skills, but the `skills` CLI
# (and `pi install`) writes to the agent's own home at $HOME/.pi/agent/skills.
# On the HA add-on those happen to coincide; here they do not, so an install
# succeeds and then the skill never shows up in a session. Bridge the two with
# a symlink, migrating anything already written to the wrong side.
AGENT_SKILLS_DIR="${HOME}/.pi/agent/skills"
mkdir -p "$(dirname "${AGENT_SKILLS_DIR}")"
if [ -d "${AGENT_SKILLS_DIR}" ] && [ ! -L "${AGENT_SKILLS_DIR}" ]; then
  log "migrating existing skills from ${AGENT_SKILLS_DIR} into ${DATA_DIR}/skills"
  cp -an "${AGENT_SKILLS_DIR}/." "${DATA_DIR}/skills/" 2>/dev/null || true
  rm -rf "${AGENT_SKILLS_DIR}"
fi
if [ ! -e "${AGENT_SKILLS_DIR}" ]; then
  ln -sfn "${DATA_DIR}/skills" "${AGENT_SKILLS_DIR}"
  log "skills bridged: ${AGENT_SKILLS_DIR} -> ${DATA_DIR}/skills"
fi

# --- Video tools reset (maintenance escape hatch) -----------------------------
# Ported from the add-on's reset_video_tools option. Without it, recovering a
# half-written venv means exec'ing in and deleting the sentinel by hand — and a
# 720MB install interrupted by a restart is exactly how one ends up half-written.
if [ "${RESET_VIDEO_TOOLS:-false}" = "true" ]; then
  log "RESET_VIDEO_TOOLS=true — clearing venv, playwright cache and sentinel"
  rm -rf "${DATA_DIR}/.video-tools-installed" "${DATA_DIR}/venv" "${DATA_DIR}/playwright-cache"
  log "  set it back to false once the reinstall completes, or every restart re-downloads ~720MB"
fi

# --- Timezone -----------------------------------------------------------------
# Debian defaults to UTC, which makes session timestamps and any SRT cue the
# video pipeline generates awkward for a Taipei team. Node reads TZ from the
# environment, not /etc/timezone, so both are set.
if [ -n "${TZ:-}" ]; then
  if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    log "timezone set to ${TZ}"
  else
    log "WARNING: timezone '${TZ}' not found in /usr/share/zoneinfo — staying on UTC"
  fi
fi

# --- Video pipeline bootstrap -------------------------------------------------
# Deliberately backgrounded rather than run inline before pi-web starts.
#
# The first-run install pulls ~720MB (Python venv + Playwright's Chromium).
# Inline, that keeps the listener down for 10-20 minutes on a cold volume: far
# past the image's HEALTHCHECK start-period, so the container reports unhealthy
# in `podman ps` while it is in fact only still installing, and close enough to
# the unit's TimeoutStartSec that one slow mirror turns a working deployment
# into a failed start. The add-on ran it as an s6 oneshot with no dependency
# edge — chat stays usable while the video tools install behind it. Same
# semantics here: non-blocking, non-fatal, sentinel-guarded.
if [ "${VIDEO_PIPELINE_ENABLED:-true}" = "true" ]; then
  log "video pipeline enabled — bootstrapping in background"
  /usr/local/bin/video-tools-init.sh &
else
  log "video pipeline disabled (VIDEO_PIPELINE_ENABLED=${VIDEO_PIPELINE_ENABLED:-})"
fi

# --- pi-web runtime -----------------------------------------------------------
export PI_WEB_HOSTNAME="${PI_WEB_HOSTNAME:-127.0.0.1}"
export PI_WEB_NO_OPEN=1
export PORT="${PI_WEB_PORT:-30141}"
export LOG_LEVEL="${LOG_LEVEL:-info}"

cd "${HOME}"

log "starting pi-web on ${PI_WEB_HOSTNAME}:${PORT}"
log "  data dir : ${PI_CODING_AGENT_DIR}"
log "  home     : ${HOME}"
log "  image    : ${PI_AGENT_IMAGE_VERSION:-dev} (pi-web ${PI_WEB_VERSION:-?}, ttyd ${TTYD_VERSION:-?})"

exec pi-web
