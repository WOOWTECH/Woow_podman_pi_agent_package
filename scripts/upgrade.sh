#!/usr/bin/env bash
# scripts/upgrade.sh: move pi-web to the image that quadlet/pi-web.container pins now
# (run it after a `git pull` that bumped the tag), with a data backup first and an
# automatic rollback to the previous image when the new one fails.
#
#   scripts/upgrade.sh [--no-backup] [--prune]
#
#   (default)    hot export of pi-agent-data to ~/backups/pi-agent before anything changes
#                (a few GB; see scripts/backup.sh)
#   --no-backup  skip that export
#   --prune      after a successful upgrade, delete the previous base and host image tags
#
# Steps: build the new images while the old pi-web keeps serving -> keep copies of the
# installed units -> scripts/install.sh --no-build (restart, wait healthy, tests/smoke.sh)
# -> on failure put the previous units back, restart on the previous image, smoke again.
# Old image tags stay until --prune, so a rollback never needs a rebuild.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"

APP=pi-agent
ENV_FILE=$HOME/.config/$APP/$APP.env
STATE=$HOME/.local/state/woow-quadlet/$APP
QDIR=$HOME/.config/containers/systemd
SDIR=$HOME/.config/systemd/user
BASE_REPO=localhost/woow-podman-pi-agent
export QL_APP=$APP

backup=1 prune=0
while (($#)); do
  case $1 in
    --no-backup) backup=0 ;;
    --prune) prune=1 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_require_podman_min 4.4
[[ -f $QDIR/pi-web.container && -f $ENV_FILE ]] || ql_die "pi-web is not installed by this package yet; run scripts/install.sh"

prev_image=$(sed -n 's/^Image=//p' "$QDIR/pi-web.container" | tail -n1)
prev_id=$(podman container inspect --format '{{.Image}}' pi-web 2>/dev/null || true)
prev_commit=$(cat "$STATE/installed-commit" 2>/dev/null || true)
[[ -n $prev_commit ]] || prev_commit=unknown
ql_env_load "$ENV_FILE"
RENDER_ARGS=()
render_args "$ENV_FILE"
new_image=$(ql_render "$REPO/quadlet/pi-web.container" "$ENV_FILE" "$REPO/quadlet/render-vars" - "${RENDER_ARGS[@]}" | sed -n 's/^Image=//p' | tail -n1)
[[ -n $new_image ]] || ql_die "cannot read Image= from quadlet/pi-web.container"
ql_info "installed: $prev_image (commit ${prev_commit:0:12}); repo pins: $new_image"

if [[ $new_image == "$prev_image" ]]; then
  ql_info "the pinned image is unchanged; running install.sh to converge the units"
  exec bash "$REPO/scripts/install.sh"
fi

# 1. backup (optional) and build, both while the current pi-web keeps running
if ((backup)); then
  bash "$REPO/scripts/backup.sh" --hot || ql_die "backup failed; nothing was changed (use --no-backup to skip it)"
fi
bash "$REPO/scripts/install.sh" --build-only || ql_die "building $new_image failed; nothing was changed"

# 2. keep what is installed now, for the rollback
rb=$STATE/upgrade-$(date +%Y%m%d-%H%M%S)
(umask 077 && mkdir -p "$rb")
for f in "$QDIR"/pi-web.container "$QDIR"/pi-agent.network "$QDIR"/pi-agent-data.volume \
  "$SDIR"/pi-web-health.service "$SDIR"/pi-web-health.timer "$STATE"/manifest; do
  [[ -f $f ]] && cp -p -- "$f" "$rb/"
done
printf '%s\n' "$prev_image" >"$rb/image"

# 3. switch
if bash "$REPO/scripts/install.sh" --no-build; then
  ql_info "upgraded pi-web: $prev_image -> $new_image (rollback copies: $rb)"
  if ((prune)); then
    for img in "$prev_image" "$BASE_REPO:${prev_image##*:}"; do
      if podman image exists "$img" >/dev/null 2>&1; then
        if podman rmi "$img" >/dev/null 2>&1; then ql_info "removed $img"; else ql_warn "could not remove $img (still in use?)"; fi
      fi
    done
  else
    ql_info "previous image kept: $prev_image (delete later with --prune or podman rmi)"
  fi
  exit 0
fi

# 4. rollback
if cmp -s "$rb/pi-web.container" "$QDIR/pi-web.container" \
  && [[ $(podman container inspect --format '{{.Image}}' pi-web 2>/dev/null || true) == "$prev_id" ]]; then
  ql_die "install.sh failed before changing pi-web; it still runs $prev_image. Nothing to roll back."
fi
ql_warn "the new image failed; rolling back to $prev_image"
podman image exists "$prev_image" >/dev/null 2>&1 || ql_die "previous image $prev_image is gone; cannot roll back automatically"
for f in pi-web.container pi-agent.network pi-agent-data.volume; do
  [[ -f $rb/$f ]] && cp -p -- "$rb/$f" "$QDIR/$f"
done
for f in pi-web-health.service pi-web-health.timer; do
  [[ -f $rb/$f ]] && cp -p -- "$rb/$f" "$SDIR/$f"
done
[[ -f $rb/manifest ]] && cp -p -- "$rb/manifest" "$STATE/manifest"
systemctl --user daemon-reload
systemctl --user restart pi-web.service || ql_die "rollback: restarting pi-web.service failed; see journalctl --user -u pi-web.service -n 100"
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy pi-web 600 || ql_die "rollback: pi-web is not healthy on $prev_image either"
bash "$REPO/tests/smoke.sh" || ql_warn "rollback: smoke checks failed"
ql_warn "rolled back to $prev_image. The checkout still pins $new_image: fix the problem and re-run,"
if [[ $prev_commit != unknown ]]; then
  ql_warn "or return the checkout to the last good install: git -C $REPO checkout $prev_commit && scripts/install.sh"
fi
exit 1
