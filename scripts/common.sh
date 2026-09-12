# shellcheck shell=bash
# scripts/common.sh: pi-agent helpers shared by install.sh and the tests.
# Source it after scripts/lib/quadlet-lib.sh.

# pi_adopt_legacy_units <app> <rendered_dir> <doc_url> <unit...>
# Take over the helper units that a pre-quadlet-lib install.sh copied straight into
# ~/.config/systemd/user. They are ours - same Documentation= URL - but in no manifest, so
# ql_install_files refuses them as foreign units it must not overwrite. Each one that is
# still un-manifested and differs from the unit we are about to install is moved aside by
# ql_adopt_file (a copy is kept under <state>/<app>/adopted/), which under QL_DRY_RUN=1
# records the move instead of doing it: that is what lets a dry run on a host that has not
# been migrated yet report what the real run would do, rather than die in ql_install_files
# on a collision the real run never reaches.
# A file with the same bytes is left alone (ql_install_files adopts it as it is), and a file
# that is not ours is fatal - the same refusal as before.
pi_adopt_legacy_units() {
  local app=$1 out=$2 doc=$3
  shift 3
  local u p sdir manifest
  sdir=${QL_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}
  manifest=${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/$app/manifest
  for u in "$@"; do
    p=$sdir/$u
    [[ -f $p && ! -L $p ]] || continue
    if [[ -f $manifest ]] && grep -qF "  $p" "$manifest"; then continue; fi
    cmp -s "$p" "$out/$u" && continue
    grep -qxF "$doc" "$p" || ql_die "$p exists and was not installed by this package; move it away first"
    ql_adopt_file "$app" "$p"
  done
  return 0
}
