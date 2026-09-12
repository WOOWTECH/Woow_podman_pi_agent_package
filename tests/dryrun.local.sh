# shellcheck shell=bash
# tests/dryrun.local.sh: pi-agent assertions, sourced at the end of tests/dryrun.sh (the
# vendored template). The generic variants have already rendered their units into
# $WORK/<variant>/out; here the podman 4.9.3 generator output of those units is checked
# against the invariants this package promises, then tests/host-profile.sh runs.
# Uses $REPO, $WORK and the `failures` counter from tests/dryrun.sh.

# _pi_gen <variant> <unit>: that unit as the Quadlet generator emits it for the variant
_pi_gen() {
  QUADLET_UNIT_DIRS="$WORK/$1/out" "${QL_QUADLET_BIN:-/usr/libexec/podman/quadlet}" -dryrun -user 2>/dev/null |
    awk -v want="---$2---" '$0 == want { on = 1; next } /^---.*---$/ { on = 0 } on'
}
_pi_ok=0
_pi_check() { # _pi_check <label> <command...>
  local label=$1
  shift
  if "$@"; then _pi_ok=$((_pi_ok + 1)); else echo "FAIL $label"; failures=$((failures + 1)); fi
}
_pi_has() { [[ $1 == *"$2"* ]]; }
_pi_hasnt() { [[ $1 != *"$2"* ]]; }
_pi_re() { [[ $1 =~ $2 ]]; }

pi_version=$(sed -n 's/^ARG PI_WEB_VERSION=//p' "$REPO/Containerfile" | head -n1)
for variant in example fixture-slim; do
  unit=$(_pi_gen "$variant" pi-web.service)
  exec_line=$(grep '^ExecStart=' <<<"$unit" || true)
  echo "== invariants: $variant"
  _pi_check "$variant: pi-web.service generated" _pi_has "$exec_line" 'podman run --name=pi-web '
  _pi_check "$variant: loopback-only publish" _pi_has "$exec_line" '--publish 127.0.0.1:30141:30141'
  _pi_check "$variant: publish never widened" _pi_hasnt "$exec_line" '--publish 30141'
  _pi_check "$variant: publish never widened (0.0.0.0)" _pi_hasnt "$exec_line" '--publish 0.0.0.0:'
  _pi_check "$variant: home via %h" _pi_has "$exec_line" '-v %h:/host%h:rw'
  _pi_check "$variant: podman socket via %t" _pi_has "$exec_line" '-v %t/podman/podman.sock:/run/host/podman/podman.sock:rw'
  _pi_check "$variant: user bus via %t" _pi_has "$exec_line" '-v %t/bus:/run/host/user-bus:rw'
  _pi_check "$variant: HOST_HOME via %h" _pi_has "$exec_line" '--env HOST_HOME=/host%h'
  _pi_check "$variant: network pi-agent" _pi_has "$exec_line" '--network=pi-agent '
  _pi_check "$variant: data volume adopted by name" _pi_has "$exec_line" '-v pi-agent-data:/data/pi-agent'
  _pi_check "$variant: Pull=never" _pi_has "$exec_line" '--pull never'
  _pi_check "$variant: no-new-privileges" _pi_has "$exec_line" '--security-opt=no-new-privileges'
  _pi_check "$variant: no auto-update label" _pi_hasnt "$exec_line" 'io.containers.autoupdate'
  _pi_check "$variant: no literal account path" _pi_hasnt "$(grep -E '(^|[[:space:]=:])(/host)?/home/[A-Za-z0-9_.-]+|/run/user/[0-9]+' <<<"$unit")" '/'
  _pi_check "$variant: network-online.target dropped" _pi_hasnt "$unit" 'network-online.target'
  _pi_check "$variant: requires podman.socket" _pi_has "$unit" 'Requires=podman.socket'
  case $variant in
    example)
      _pi_check "$variant: image pinned to the Containerfile's pi-web $pi_version" \
        _pi_re "$exec_line" "localhost/woow-podman-pi-agent-host:${pi_version//./\\.}-r[0-9]+\$"
      _pi_check "$variant: video pipeline on" _pi_has "$exec_line" '--env VIDEO_PIPELINE_ENABLED=true'
      _pi_check "$variant: TZ rendered" _pi_has "$exec_line" '--env TZ=Asia/Taipei'
      ;;
    fixture-slim)
      _pi_check "$variant: slim image tag" _pi_re "$exec_line" "localhost/woow-podman-pi-agent-host:${pi_version//./\\.}-r[0-9]+-slim\$"
      _pi_check "$variant: video pipeline off" _pi_has "$exec_line" '--env VIDEO_PIPELINE_ENABLED=false'
      _pi_check "$variant: exactly one VIDEO_PIPELINE_ENABLED" _pi_re "$(grep -o 'VIDEO_PIPELINE_ENABLED=[a-z]*' <<<"$exec_line" | wc -l)" '^1$'
      ;;
  esac
done
echo "invariants: $_pi_ok passed"

echo "== tests/host-profile.sh"
if bash "$REPO/tests/host-profile.sh"; then echo "ok   host-profile"; else echo "FAIL host-profile"; failures=$((failures + 1)); fi

# Step 5 + step 6 of scripts/install.sh against a host that still carries the pre-quadlet-lib
# pi-web-health.{service,timer}: the case that made every --dry-run there fail.
echo "== tests/adopt-legacy.sh"
if bash "$REPO/tests/adopt-legacy.sh"; then echo "ok   adopt-legacy"; else echo "FAIL adopt-legacy"; failures=$((failures + 1)); fi
