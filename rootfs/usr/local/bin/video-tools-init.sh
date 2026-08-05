#!/bin/bash
# First-boot bootstrap for the video-production pipeline.
#
# Ported from the add-on's s6 oneshot. Three constraints carried over verbatim,
# because each one was a bug once:
#   1. Idempotent — guarded by a sentinel on the volume; later boots exit in ms.
#   2. Non-fatal — a failed install must never stop pi-web from serving. Every
#      failure path exits 0 after logging.
#   3. Persistent — everything lands under the named volume, so an image bump
#      does not re-download 720MB.
set -uo pipefail
exec 2>&1

DATA="${PI_AGENT_DATA_DIR:-/data/pi-agent}"
VENV="${DATA}/venv"
CACHE="${DATA}/playwright-cache"
RCLONE_DIR="${DATA}/rclone"
SENTINEL="${DATA}/.video-tools-installed"

log() { printf '[video-tools] %s\n' "$*"; }

mkdir -p "${DATA}" "${CACHE}" "${RCLONE_DIR}" "${DATA}/projects"

if [ -f "${SENTINEL}" ] && [ -x "${VENV}/bin/python3" ]; then
  log "already installed (sentinel present) — skipping"
  exit 0
fi

log "first-run install starting (~720MB, several minutes; pi-web is already serving)"

if [ ! -x "${VENV}/bin/python3" ]; then
  log "creating venv at ${VENV}"
  if ! python3 -m venv "${VENV}"; then
    log "WARNING: venv creation failed — video pipeline unavailable, chat unaffected"
    exit 0
  fi
fi

log "installing python packages (playwright, edge-tts, pyyaml, mutagen)"
"${VENV}/bin/pip" install --no-cache-dir --quiet --upgrade pip \
  || log "WARNING: pip self-upgrade failed — continuing"
if ! "${VENV}/bin/pip" install --no-cache-dir --quiet playwright edge-tts pyyaml mutagen; then
  log "WARNING: pip install failed — video pipeline unavailable"
  exit 0
fi

export PLAYWRIGHT_BROWSERS_PATH="${CACHE}"
log "downloading Chromium into ${CACHE} (~600MB)"
if ! "${VENV}/bin/playwright" install chromium; then
  log "WARNING: chromium download failed — capture step unavailable"
  exit 0
fi

if [ ! -s "${RCLONE_DIR}/rclone.conf" ]; then
  log "no rclone.conf yet — Drive upload stays unavailable until configured"
  log "  configure once: podman exec -it pi-web rclone config"
fi

touch "${SENTINEL}"
log "install complete — sentinel written to ${SENTINEL}"
