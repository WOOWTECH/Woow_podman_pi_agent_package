#!/usr/bin/env bash
# tests/adopt-legacy.sh: steps 5 and 6 of scripts/install.sh on a host that still carries the
# helper units an earlier, pre-quadlet-lib install.sh copied straight into
# ~/.config/systemd/user - dry first, then for real. Everything happens in a sandbox
# (QL_SYSTEMD_USER_DIR / QL_QUADLET_DIR / QL_STATE_ROOT / QL_CONFIG_ROOT): no containers, no
# systemd, nothing outside $TMPDIR. Called from tests/dryrun.local.sh, so it runs in CI.
#
# The bug it pins down: --dry-run always failed on such a host. Step 5 skipped the move
# because a dry run must not touch anything, and step 6 then found the un-manifested unit in
# ~/.config/systemd/user and died with "refusing to install" - a failure the real run never
# hits, because there step 5 has already moved the file. A dry run has to model the adoption.
#
# Each mode runs in its own subshell so QL_DRY_RUN cannot leak into the next check, which
# is the point rather than an accident:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
export QL_LOG_PREFIX=adopt-legacy

APP=pi-agent
DOC_URL='Documentation=https://github.com/WOOWTECH/Woow_podman_pi_agent_package'
UNITS=(pi-web-health.service pi-web-health.timer)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/adopt-legacy.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ok=0 bad=0
pass() { ok=$((ok + 1)); }
fail() { echo "FAIL $*"; bad=$((bad + 1)); }

# sandbox <name>: an empty "host" plus $OUT, the units install.sh would install
sandbox() {
  local h=$WORK/$1
  export QL_SYSTEMD_USER_DIR=$h/systemd-user QL_QUADLET_DIR=$h/quadlet QL_STATE_ROOT=$h/state QL_CONFIG_ROOT=$h/config
  OUT=$h/out
  mkdir -p "$QL_SYSTEMD_USER_DIR" "$QL_QUADLET_DIR" "$OUT"
  cp -p "$REPO"/systemd/* "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$OUT/"
}
# legacy_units: what the earlier install.sh left behind - our units, but an older revision
legacy_units() {
  local u
  for u in "${UNITS[@]}"; do
    { echo '# installed by pi-agent 0.8.x, before the manifest existed'; cat "$REPO/systemd/$u"; } >"$QL_SYSTEMD_USER_DIR/$u"
  done
}

# ---- 1. the dry run reports what the real run would do, instead of failing -----------------
sandbox dry
legacy_units
(
  export QL_DRY_RUN=1
  pi_adopt_legacy_units "$APP" "$OUT" "$DOC_URL" "${UNITS[@]}"
  ql_install_files "$OUT" "$APP"
) >"$WORK/dry.out" 2>"$WORK/dry.err" || fail "the dry run failed on an un-migrated host:"$'\n'"$(cat "$WORK/dry.err")"
for u in "${UNITS[@]}"; do
  if grep -qF "[dry-run] would adopt $QL_SYSTEMD_USER_DIR/$u" "$WORK/dry.err"; then pass; else fail "dry run: no adoption reported for $u"; fi
  if grep -qF "[dry-run] would write $QL_SYSTEMD_USER_DIR/$u" "$WORK/dry.err"; then pass; else fail "dry run: no write reported for $u"; fi
  if grep -qxF "$u" "$WORK/dry.out"; then pass; else fail "dry run: $u missing from the changed list"; fi
  if grep -q 'installed by pi-agent 0.8.x' "$QL_SYSTEMD_USER_DIR/$u"; then pass; else fail "dry run: it moved or rewrote $u"; fi
done
if [[ ! -e $QL_STATE_ROOT/$APP/manifest && -z $(ls -A "$QL_QUADLET_DIR") ]]; then pass; else fail "dry run wrote to the host"; fi

# ---- 2. the real run: moved aside, our copy installed, old copy kept -----------------------
sandbox real
legacy_units
pi_adopt_legacy_units "$APP" "$OUT" "$DOC_URL" "${UNITS[@]}" 2>"$WORK/real.err"
ql_install_files "$OUT" "$APP" >"$WORK/real.out" 2>>"$WORK/real.err"
for u in "${UNITS[@]}"; do
  if cmp -s "$REPO/systemd/$u" "$QL_SYSTEMD_USER_DIR/$u"; then pass; else fail "real run: our $u was not installed"; fi
  if grep -rqF 'installed by pi-agent 0.8.x' "$QL_STATE_ROOT/$APP/adopted"; then pass; else fail "real run: no copy of the old $u was kept"; fi
  if grep -qF "  $QL_SYSTEMD_USER_DIR/$u" "$QL_STATE_ROOT/$APP/manifest"; then pass; else fail "real run: $u is not in the manifest"; fi
done

# ---- 3. a unit that is not ours stays fatal, in both modes ---------------------------------
for mode in dry real; do
  sandbox "foreign-$mode"
  echo '[Unit]
Description=someone else health timer' >"$QL_SYSTEMD_USER_DIR/pi-web-health.timer"
  if (
    [[ $mode == dry ]] && export QL_DRY_RUN=1
    pi_adopt_legacy_units "$APP" "$OUT" "$DOC_URL" "${UNITS[@]}"
  ) >/dev/null 2>"$WORK/foreign.err"; then
    fail "$mode: a foreign unit was adopted"
  elif grep -q 'was not installed by this package' "$WORK/foreign.err"; then pass; else
    fail "$mode: a foreign unit failed for the wrong reason: $(cat "$WORK/foreign.err")"
  fi
done

# ---- 4. an identical unit is left to ql_install_files (nothing to adopt) -------------------
sandbox identical
cp -p "$REPO/systemd/pi-web-health.timer" "$QL_SYSTEMD_USER_DIR/"
pi_adopt_legacy_units "$APP" "$OUT" "$DOC_URL" "${UNITS[@]}" 2>"$WORK/identical.err"
if [[ -s $WORK/identical.err ]]; then fail "an identical unit must not be adopted: $(cat "$WORK/identical.err")"; else pass; fi
ql_install_files "$OUT" "$APP" >/dev/null 2>&1 || fail "an identical unit broke the install"

echo "adopt-legacy: $ok passed, $bad failed"
((bad == 0))
