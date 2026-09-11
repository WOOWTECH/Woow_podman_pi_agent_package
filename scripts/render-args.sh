# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/pi-agent/pi-agent.env.
# Sourced by scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a
# host gets. render_args <envfile>: QL_ENV is loaded; sets RENDER_ARGS=(KEY=VALUE...).
render_args() {
  local tools tz
  tz=$(ql_env_get PI_TZ)
  ql_assert_match PI_TZ "$tz" '[A-Za-z][A-Za-z0-9_+/-]*'
  tools=$(ql_env_get PI_VIDEO_TOOLS true)
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  case $tools in
    true) RENDER_ARGS=(PI_IMAGE_VARIANT= PI_VIDEO_PIPELINE_ENABLED=true) ;;
    false) RENDER_ARGS=(PI_IMAGE_VARIANT=-slim PI_VIDEO_PIPELINE_ENABLED=false) ;;
    *) ql_die "PI_VIDEO_TOOLS must be true or false (got '$tools')" ;;
  esac
}
