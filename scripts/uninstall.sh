#!/usr/bin/env bash
# scripts/uninstall.sh: remove the pi-web Quadlet units. Keeps data by default.
#
#   scripts/uninstall.sh                   stop + remove the units; keep pi-agent-data, the
#                                          env file, images and the pi-agent network
#   scripts/uninstall.sh --purge [--yes]   also delete pi-agent-data (after a final export to
#                                          ~/backups/pi-agent) and the pi-agent network
#   scripts/uninstall.sh --dry-run         report what would be removed
#
# pi-agent-data holds sessions, skills and models.json with the provider API key.
# --purge leaves the pi-agent network in place while another container (NPM with the
# pi-web front) is attached to it; NPM recreates it on its next start anyway.
# Never deleted here: ~/.config/pi-agent/pi-agent.env, images, podman.socket, and the
# reverse-proxy configuration in NPM or nginx.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"

APP=pi-agent
DATA_VOLUMES=(pi-agent-data)
BACKUP_DIR=$HOME/backups/$APP

purge=0 yes=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$APP
ql_require_rootless
ql_lock "$APP"

if [[ ! -f $HOME/.local/state/woow-quadlet/$APP/manifest ]]; then
  ql_warn "no install record in ~/.local/state/woow-quadlet/$APP (installed by an older install.sh?)."
  ql_warn "Run scripts/install.sh once to adopt the units, then uninstall; or remove them by hand:"
  cat >&2 <<'EOF'
    systemctl --user disable --now pi-web-health.timer; systemctl --user stop pi-web.service
    rm ~/.config/containers/systemd/{pi-web.container,pi-agent.network,pi-agent-data.volume}
    rm ~/.config/systemd/user/pi-web-health.{service,timer}; systemctl --user daemon-reload
EOF
  exit 1
fi

if ((!purge)); then
  ql_uninstall_units "$APP"
  ql_info "images kept: podman images 'localhost/woow-podman-pi-agent*'"
  exit 0
fi

if ((!yes)) && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  [[ -t 0 ]] || ql_die "--purge deletes pi-agent-data; add --yes to confirm non-interactively"
  read -r -p "Type '$APP' to delete the pi-agent-data volume: " answer
  [[ $answer == "$APP" ]] || ql_die "aborted; nothing was deleted"
fi
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  systemctl --user stop pi-web.service 2>/dev/null || true
  for v in "${DATA_VOLUMES[@]}"; do
    if podman volume exists "$v"; then ql_backup_volume "$v" "$BACKUP_DIR" >/dev/null; fi
  done
fi
ql_uninstall_units "$APP" --purge
