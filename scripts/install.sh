#!/usr/bin/env bash
# scripts/install.sh: install or update pi-web as rootless Quadlet units (podman >= 4.4,
# systemd --user, linger). Idempotent: an unchanged re-run builds nothing and restarts
# nothing. Run it as the account that owns the containers, never with sudo.
#
#   scripts/install.sh [--rebuild | --no-build] [--build-only] [--no-start] [--dry-run]
#
#   --rebuild     build the base and host images again even if the pinned tag exists
#   --no-build    never build; the pinned image must already exist (used by upgrade.sh)
#   --build-only  build the pinned base and host images, then stop (no config, no units);
#                 run it ahead of a maintenance window, the running pi-web is untouched
#   --no-start    install the units and daemon-reload, but start/restart nothing
#   --dry-run     render + validate + report what would change; touch nothing
#
# Per-host settings live in ~/.config/pi-agent/pi-agent.env, created from
# config/pi-agent.env.example on the first run. The units use %h/%t, so they never need
# editing for a different account or uid.
#
# Order: preflight -> env -> render -> dry-run -> build -> install -> apply -> smoke.
# Every image is built BEFORE any unit changes, so a failed build costs no downtime.
# pi-web is restarted when its unit, the network/volume units or its image changed.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

# ---- settings ------------------------------------------------------------------------------
APP=pi-agent
ENV_FILE=$HOME/.config/$APP/$APP.env
ENV_EXAMPLE=$REPO/config/$APP.env.example
PODMAN_MIN=4.4
CONTAINER=pi-web
BASE_REPO=localhost/woow-podman-pi-agent
UNITS=(pi-agent-network.service pi-agent-data-volume.service pi-web.service pi-web-health.timer)
HEALTH_TIMEOUT=600
PORT=30141
DOC_URL='Documentation=https://github.com/WOOWTECH/Woow_podman_pi_agent_package'
# podman-static (docs/armbian-arm64-deployment.md) installs its generator under /usr/local.
export QL_USER_GENERATOR="${QL_USER_GENERATOR:-/usr/lib/systemd/user-generators/podman-user-generator /lib/systemd/user-generators/podman-user-generator /etc/systemd/user-generators/podman-user-generator /usr/local/lib/systemd/user-generators/podman-user-generator}"
# --------------------------------------------------------------------------------------------

build=auto build_only=0 no_start=0
while (($#)); do
  case $1 in
    --rebuild) build=always ;;
    --no-build) build=never ;;
    --build-only) build_only=1 ;;
    --no-start) no_start=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ $build_only == 0 || $build != never ]] || ql_die "--build-only and --no-build contradict each other"
export QL_APP=$APP
dry() { [[ ${QL_DRY_RUN:-0} == 1 ]]; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# render_units <envfile>: stage + render quadlet/ and systemd/ into $WORK/out; sets IMAGE
render_units() {
  rm -rf "$WORK/src" "$WORK/out"
  mkdir -p "$WORK/src" "$WORK/out"
  # Glob, not a list of names: tests/dryrun.sh renders systemd/* the same way, so a helper
  # unit added later is installed as well as verified instead of only verified.
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.network "$REPO"/quadlet/*.volume \
    "$REPO"/systemd/* "$WORK/src/"
  ql_env_load "$1"
  RENDER_ARGS=()
  render_args "$1"
  ql_render "$WORK/src" "$1" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
  IMAGE=$(sed -n 's/^Image=//p' "$WORK/out/pi-web.container" | tail -n1)
  [[ $IMAGE =~ ^localhost/[a-z0-9._/-]+:[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+(-slim)?$ ]] \
    || ql_die "unexpected Image= in quadlet/pi-web.container: '$IMAGE'"
}

# build_images <host-image>: base from Containerfile, then the host layer on top of it.
# Only VIDEO_TOOLS is passed, so a host that built the same revision before gets full
# cache hits (and the same image ID).
build_images() {
  local image=$1 tag base
  local -a q_vt=()
  tag=${image##*:}
  base=$BASE_REPO:$tag
  [[ $tag == *-slim ]] && q_vt=(--build-arg VIDEO_TOOLS=0)
  ql_info "building $base from Containerfile${q_vt[*]:+ (${q_vt[*]})}; a cold build takes 5-20 min and needs network"
  podman build --format=docker "${q_vt[@]}" -t "$base" -f "$REPO/Containerfile" "$REPO" \
    || ql_die "building $base failed; nothing was changed"
  ql_info "building $image from Containerfile.host-control on $base"
  podman build --format=docker --build-arg "BASE_IMAGE=$base" -t "$image" -f "$REPO/Containerfile.host-control" "$REPO" \
    || ql_die "building $image failed; nothing was changed"
}

# ensure_image: build unless the pinned tag exists (or --rebuild / --no-build say otherwise)
ensure_image() {
  if [[ $build == never ]]; then
    podman image exists "$IMAGE" || ql_die "$IMAGE does not exist and --no-build was given (run scripts/install.sh --build-only)"
    return 0
  fi
  if [[ $build == auto ]] && podman image exists "$IMAGE"; then
    ql_info "image $IMAGE is present (use --rebuild to build it again)"
    return 0
  fi
  if dry; then ql_info "[dry-run] would build $BASE_REPO:${IMAGE##*:} and $IMAGE"; return 0; fi
  build_images "$IMAGE"
}

# ---- --build-only: images only, no config and no units ------------------------------------
if ((build_only)); then
  ql_require_rootless
  ql_require_podman_min "$PODMAN_MIN"
  export QL_ENV_MODE_CHECK=0
  if [[ -f $ENV_FILE ]]; then render_units "$ENV_FILE"; else render_units "$ENV_EXAMPLE"; fi
  ensure_image
  ql_info "image ready: $IMAGE ($(podman image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null | cut -c1-12 || echo '?'))"
  exit 0
fi

# ---- 1. host preflight ---------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
ql_lock "$APP"

# ---- 2. per-host settings (D2: values come from the env file, never from the repo) --------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 ]]; then
  ql_info "its defaults (PI_TZ=Asia/Taipei, PI_VIDEO_TOOLS=true) suit any host, so installing now; edit it and re-run to change them"
fi
if dry && [[ ! -f $ENV_FILE ]]; then render_units "$ENV_EXAMPLE"; else render_units "$ENV_FILE"; fi

# ---- 3. guards -----------------------------------------------------------------------------
# pi-web has been Quadlet-managed since the start, so an existing pi-web container normally
# carries PODMAN_SYSTEMD_UNIT=pi-web.service; anything else would be deleted by --replace.
ql_check_container_collision "$CONTAINER" pi-web.service
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered units failed the dry-run; nothing was installed"
for f in "$WORK/out"/*.container "$WORK/out"/*.network "$WORK/out"/*.volume; do
  ql_check_unit_shadow "$(ql_unit_for "$f")" "$APP"
done

# ---- 4. images before any unit changes -----------------------------------------------------
ensure_image
if dry && ! podman image exists "$IMAGE" >/dev/null 2>&1; then
  ql_info "[dry-run] $IMAGE is not built yet"
else
  ql_pull_images "$WORK/out" # verifies the Pull=never image is present
fi
want_id=''
if podman image exists "$IMAGE" >/dev/null 2>&1; then want_id=$(podman image inspect --format '{{.Id}}' "$IMAGE"); fi
have_id=$(podman container inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null || true)
if [[ -n $have_id && -n $want_id && $have_id != "$want_id" ]]; then
  ql_info "pi-web runs image ${have_id:0:12}; the pinned $IMAGE is ${want_id:0:12}: pi-web will restart"
  ql_mark_changed "$APP" pi-web.service
fi

# ---- 5. adopt helper units installed by the pre-Quadlet-lib install.sh ---------------------
# Earlier versions of this script copied pi-web-health.{service,timer} straight into
# ~/.config/systemd/user. They are ours (same Documentation= URL) but not in the lib's
# manifest, which would refuse them as foreign. pi_adopt_legacy_units moves them aside
# (backup kept) so ql_install_files below can take over; in a dry run it records the move
# instead of doing it, so step 6 reports the write the real run would do.
pi_adopt_legacy_units "$APP" "$WORK/out" "$DOC_URL" pi-web-health.service pi-web-health.timer

# ---- 6. install changed files, then start / restart only what changed ------------------------
ql_enable_podman_socket
changed=$(ql_install_files "$WORK/out" "$APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if dry; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
if commit=$(git -C "$REPO" rev-parse HEAD 2>/dev/null); then
  printf '%s\n' "$commit" >"$HOME/.local/state/woow-quadlet/$APP/installed-commit"
fi
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start pi-web.service"
  exit 0
fi
# The health timer first: podman-static hosts never register podman's own health timer,
# and a failed pi-web start below must not leave the timer stopped.
systemctl --user daemon-reload
systemctl --user enable --now pi-web-health.timer >/dev/null 2>&1 || ql_warn "could not enable pi-web-health.timer"
ql_apply_units "$APP" "${UNITS[@]}"

# ---- 7. smoke --------------------------------------------------------------------------------
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$CONTAINER" "$HEALTH_TIMEOUT" \
  || ql_die "pi-web did not become healthy; see: journalctl --user -u pi-web.service -n 100; podman logs --tail 100 pi-web"
ql_wait_http "http://127.0.0.1:$PORT/api/home" '200' 120 || ql_die "http://127.0.0.1:$PORT/api/home does not answer 200"
bash "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed"

# ---- 8. exposure report (read-only) --------------------------------------------------------
# Read the listener list once: `... | grep -vq` exits at the first non-loopback listener, the
# producer is then killed by SIGPIPE and pipefail makes that the pipeline's status -- which
# would swallow the very warning this block exists to print.
port_listeners=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ":$PORT\$" || true)
if [[ -n $port_listeners ]] && grep -vqE "^127\.0\.0\.1:$PORT\$" <<<"$port_listeners"; then
  ql_warn "port $PORT listens on a non-loopback address: that is an unauthenticated root-equivalent shell"
fi
if podman container exists woow-tailscale >/dev/null 2>&1; then
  ts_serve=$(podman exec woow-tailscale tailscale serve status --json 2>/dev/null || true)
  if grep -qE "127\.0\.0\.1:$PORT\b" <<<"$ts_serve"; then
    ql_warn "the woow-tailscale serve config forwards a tailnet port to 127.0.0.1:$PORT."
    ql_warn "Every tailnet member reaches pi-web WITHOUT the proxy's authentication. Remove it, e.g.:"
    printf '    podman exec woow-tailscale tailscale serve --tcp=%s off\n' "$PORT" >&2
  fi
fi
cat >&2 <<EOF

pi-web is installed and healthy: $IMAGE

  Loopback   http://127.0.0.1:$PORT   (NO authentication: same-host proxy only)
  Logs       journalctl --user -u pi-web.service -f ; podman logs -f pi-web
  Shell      podman exec -it pi-web bash
  Upgrade    git pull && scripts/upgrade.sh
  Backup     scripts/backup.sh

Put a reverse proxy WITH authentication in front of it (Woow_podman_nginxpm with
NPM_PI_WEB_FRONT=true, plus an access list; ideally Cloudflare Access as well).
Anyone who reaches port $PORT gets a shell as $(id -un) with read-write access to $HOME.
EOF
