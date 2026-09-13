#!/usr/bin/env bash
# scripts/restore.sh: replace the contents of the pi-agent-data volume with an export made
# by scripts/backup.sh, then start pi-web and run the smoke checks.
#
#   scripts/restore.sh <pi-agent-data-YYYYmmdd-HHMMSS.tar> [--yes] [--no-safety-backup]
#
#   --yes               do not ask for confirmation (required without a terminal)
#   --no-safety-backup  do not export the current contents first
#
# Destructive: everything in pi-agent-data is replaced. By default the current contents
# are exported to ~/backups/pi-agent/pre-restore/ first. Units and the env file are not
# touched; reinstall them with scripts/install.sh (the config archive from backup.sh holds
# the copies that were installed at backup time).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"

VOLUME=pi-agent-data
archive='' yes=0 safety=1
while (($#)); do
  case $1 in
    --yes) yes=1 ;;
    --no-safety-backup) safety=0 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $archive ]] || ql_die "one archive only"; archive=$1 ;;
  esac
  shift
done
[[ -n $archive ]] || ql_die "usage: scripts/restore.sh <pi-agent-data-*.tar> [--yes]"
[[ -f $archive ]] || ql_die "$archive not found"
ql_require_rootless
ql_lock pi-agent
if [[ -f $archive.sha256 ]]; then
  (cd -- "$(dirname -- "$archive")" && sha256sum -c --quiet -- "$(basename -- "$archive").sha256") \
    || ql_die "checksum mismatch for $archive"
  ql_info "checksum ok: $archive"
else
  ql_warn "no $archive.sha256 next to the archive; restoring without a checksum"
fi
tar -tf "$archive" >/dev/null 2>&1 || ql_die "$archive is not a readable tar archive"
if ((!yes)); then
  [[ -t 0 ]] || ql_die "restore replaces all of $VOLUME; add --yes to confirm non-interactively"
  read -r -p "Replace the contents of volume $VOLUME with $archive? Type 'restore': " answer
  [[ $answer == restore ]] || ql_die "aborted; nothing was changed"
fi

systemctl --user stop pi-web.service || true
if podman container exists pi-web >/dev/null 2>&1; then
  ql_die "a pi-web container still exists after stopping the unit; remove it first (podman rm pi-web)"
fi
if ((safety)) && podman volume exists "$VOLUME" >/dev/null 2>&1; then
  ql_info "exporting the current contents first"
  ql_backup_volume "$VOLUME" "$HOME/backups/pi-agent/pre-restore" >/dev/null
fi
if podman volume exists "$VOLUME" >/dev/null 2>&1; then
  podman volume rm "$VOLUME" >/dev/null || ql_die "cannot remove volume $VOLUME (still used by a container?)"
fi
podman volume create "$VOLUME" >/dev/null
podman volume import "$VOLUME" "$archive" || ql_die "podman volume import failed; the volume is empty now. Retry, or import the pre-restore export"
ql_info "restored $VOLUME from $archive"
systemctl --user start pi-web.service
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy pi-web 600 || ql_die "pi-web is not healthy after the restore"
bash "$REPO/tests/smoke.sh"
