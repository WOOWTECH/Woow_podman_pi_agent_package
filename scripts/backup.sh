#!/usr/bin/env bash
# scripts/backup.sh: export the pi-agent-data volume (sessions, skills, the agent's $HOME,
# models.json WITH the provider API key) plus the installed units and the env file.
#
#   scripts/backup.sh [--hot] [--dest DIR]
#
#   (default)   cold: stop pi-web for the export (1-2 min for a few GB), then start it again
#   --hot       no stop; a session file written during the export may be torn
#   --dest DIR  default ~/backups/pi-agent
#
# Output (printed on stdout): DIR/pi-agent-data-<ts>.tar and DIR/pi-agent-config-<ts>.tgz,
# each with a .sha256, mode 0600 in a 0700 directory. Restore with scripts/restore.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"

APP=pi-agent
VOLUME=pi-agent-data
dest=$HOME/backups/$APP hot=0
while (($#)); do
  case $1 in
    --hot) hot=1 ;;
    --dest) dest=${2:?--dest needs a directory}; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
podman volume exists "$VOLUME" >/dev/null 2>&1 || ql_die "volume $VOLUME does not exist"

restart=0
if ((!hot)) && systemctl --user is-active --quiet pi-web.service; then
  restart=1
  trap 'systemctl --user start pi-web.service || ql_warn "could not start pi-web.service again; run: systemctl --user start pi-web.service"' EXIT
  ql_info "stopping pi-web.service for a consistent export (use --hot to skip)"
  systemctl --user stop pi-web.service
fi
ql_backup_volume "$VOLUME" "$dest"

# Units, env file and install state are small; keep them next to the data.
ts=$(date +%Y%m%d-%H%M%S)
cfg=$dest/$APP-config-$ts.tgz
rel=()
for p in .config/containers/systemd/pi-web.container .config/containers/systemd/pi-agent.network \
  .config/containers/systemd/pi-agent-data.volume .config/systemd/user/pi-web-health.service \
  .config/systemd/user/pi-web-health.timer ".config/$APP" ".local/state/woow-quadlet/$APP/manifest" \
  ".local/state/woow-quadlet/$APP/installed-commit"; do
  [[ -e $HOME/$p ]] && rel+=("$p")
done
if ((${#rel[@]})); then
  (umask 077 && tar -czf "$cfg.partial" -C "$HOME" -- "${rel[@]}") || { rm -f -- "$cfg.partial"; ql_die "cannot write $cfg"; }
  mv -f -- "$cfg.partial" "$cfg"
  (cd -- "$dest" && umask 077 && sha256sum -- "${cfg##*/}" >"${cfg##*/}.sha256")
  ql_info "archived units and settings -> $cfg"
  printf '%s\n' "$cfg"
fi
((restart)) && ql_info "starting pi-web.service again"
exit 0
