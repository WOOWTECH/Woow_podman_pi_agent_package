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

# A venv is judged by pip, not by python3.
#
# When `python3 -m venv` fails at the ensurepip step — which is what happens on
# an image built with VIDEO_TOOLS=0, where python3-venv is absent — it still
# leaves bin/python3 behind. Every guard in this script used to test that file,
# so a half-built venv read as complete: creation was skipped, the very next
# line called a pip that did not exist, the failure path exited 0, and the
# sentinel was never written. The result repeated identically on every boot and
# could not recover without deleting the tree by hand. bin/pip is the file whose
# absence actually breaks the next step, so that is what gets tested.
venv_usable() { [ -x "${VENV}/bin/pip" ] && [ -x "${VENV}/bin/python3" ]; }

mkdir -p "${DATA}" "${CACHE}" "${RCLONE_DIR}" "${DATA}/projects"

# Nothing here is useful without the system toolchain. ffmpeg is the cheapest
# reliable probe: it is installed only in the VIDEO_TOOLS=1 branch of the
# Containerfile, alongside python3-venv, the Chromium shared libraries and the
# CJK fonts. Saying so plainly beats letting the first symptom be a Python
# error several minutes into a download.
if ! command -v ffmpeg >/dev/null 2>&1; then
  log "image has no video toolchain (built with VIDEO_TOOLS=0) — nothing to install"
  log "  set VIDEO_PIPELINE_ENABLED=false in the Quadlet unit to stop invoking this"
  exit 0
fi

if [ -f "${SENTINEL}" ] && venv_usable; then
  log "already installed (sentinel present) — skipping"
  exit 0
fi

log "first-run install starting (~720MB, several minutes; pi-web is already serving)"

if ! venv_usable; then
  # Remove before recreating. `python3 -m venv` over a broken tree does not
  # reliably repair it, and leaving it in place is what made the old failure
  # permanent instead of transient.
  if [ -e "${VENV}" ]; then
    log "removing unusable venv at ${VENV} (no bin/pip — a previous run failed at ensurepip)"
    rm -rf "${VENV}"
  fi
  log "creating venv at ${VENV}"
  if ! python3 -m venv "${VENV}" || ! venv_usable; then
    log "WARNING: venv creation failed — video pipeline unavailable, chat unaffected"
    log "  most likely cause: python3-venv is not installed in this image"
    rm -rf "${VENV}"
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
