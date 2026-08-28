#!/usr/bin/env bash
# Acceptance suite for the Podman deployment.
#
#   podman exec -it pi-web bash /opt/tests/acceptance.sh
#
# Checks that need no LLM run first and are free; the conversation tests come
# last and cost tokens. Every check prints PASS/FAIL with the evidence inline,
# so a failure is actionable without re-running anything.
#
# Set PI_ACC_PASS (and PI_ACC_USER, default 'woow') to also run the checks that
# have to get past Basic auth. The suite cannot read the password itself: the
# htpasswd is mounted into nginx alone, and mounting it anywhere pi-web could
# see it would put the hash within reach of the agent's own read tool.
#
# Written to be comparable with the k3s deployment: the same properties, in the
# same order, so a difference between the two is a porting defect rather than a
# difference in how they were measured.
set -uo pipefail

DATA="${PI_AGENT_DATA_DIR:-/data/pi-agent}"
BASE="http://127.0.0.1:${PI_WEB_PORT:-30141}"
PROXY="http://${NGINX_HOST:-pi-agent-nginx}:30142"
CWD="${DATA}/home/pi-cwd-$(date +%Y%m%d)"
PASS=0; FAIL=0; NOTE=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[90mSKIP\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; NOTE=$((NOTE+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "1. Runtime"

if v=$(pi --version 2>/dev/null); then ok "pi on PATH — $v"; else bad "pi not on PATH (the launcher failed; terminal workflows are dead)"; fi
if v=$(node --version 2>/dev/null); then ok "node — $v"; else bad "node missing"; fi
# These must hold in a PLAIN exec, not only under `bash -l`. The image bakes
# them as ENV for exactly that reason: /etc/profile.d reaches login shells only,
# and a script run with `podman exec pi-web bash script.sh` would otherwise get
# HOME=/root and write the agent's state into the ephemeral layer.
[ -n "${PI_CODING_AGENT_DIR:-}" ] && ok "PI_CODING_AGENT_DIR=${PI_CODING_AGENT_DIR}" || bad "PI_CODING_AGENT_DIR unset in a non-login shell — the image ENV is missing"
[ "${HOME}" = "${DATA}/home" ] && ok "HOME pinned to the volume — ${HOME}" || bad "HOME is ${HOME}, expected ${DATA}/home (non-login shells lose the volume)"
[ "$(date +%Z)" != "UTC" ] && ok "timezone applied — $(date '+%Z %F %T')" || bad "still UTC; TZ did not apply"

head_ "2. Persistence layout"

for d in sessions skills home; do
  [ -d "${DATA}/${d}" ] && ok "${DATA}/${d} exists" || bad "${DATA}/${d} missing"
done
# The bridge is what makes `pi install` land where pi-web reads. Without it an
# install succeeds and the skill never appears in a session.
if [ -L "${HOME}/.pi/agent/skills" ]; then
  ok "skills bridge — $(readlink -f "${HOME}/.pi/agent/skills")"
else
  bad "skills bridge missing; CLI-installed skills will not appear in the UI"
fi
for f in models.json settings.json auth.json; do
  if [ -f "${DATA}/${f}" ]; then
    m=$(stat -c '%a' "${DATA}/${f}")
    case "${f}" in
      # 644 here means the entrypoint's umask is not in effect. pi-web recreates
      # models.json every time the Models page is saved, so a mode that is only
      # corrected at boot leaves the key world-readable for the whole session.
      models.json|auth.json) [ "$m" = "600" ] && ok "${f} mode ${m}" || bad "${f} mode ${m}, expected 600 (holds the provider key; umask 077 not applied)" ;;
      *) ok "${f} present (mode ${m})" ;;
    esac
  fi
done

head_ "3. HTTP surface"

code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/home"); [ "$code" = "200" ] && ok "/api/home -> 200" || bad "/api/home -> ${code}"
mkdir -p "${CWD}"
sleep 2
code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/models?cwd=${CWD}")
[ "$code" = "200" ] && ok "/api/models -> 200 (allowed-root resolution works)" || bad "/api/models -> ${code}"
code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/skills?cwd=${CWD}"); [ "$code" = "200" ] && ok "/api/skills -> 200" || bad "/api/skills -> ${code}"
code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/plugins?cwd=${CWD}"); [ "$code" = "200" ] && ok "/api/plugins -> 200" || bad "/api/plugins -> ${code}"

providers=$(curl -s "${BASE}/api/models-config" | head -c 40)
if echo "$providers" | grep -q '"providers":{}'; then
  bad "no provider configured yet — set one in the Models page before the conversation tests"
else
  ok "provider configured"
fi

head_ "4. CJK path handling (the U+3000 trap)"

# Upstream folds U+3000 to an ASCII space on every read/write/edit, which makes
# a write land at the wrong name and makes two files differing only by space
# type cross-read. The image patches this; verify the patch is live.
T="${CWD}/_acc_cjk"; rm -rf "$T"; mkdir -p "$T"
printf 'IDEOGRAPHIC\n' > "$T/台灣　報告.txt"   # U+3000 between the words
printf 'ASCII\n'       > "$T/台灣 報告.txt"    # U+0020
got=$(cat "$T/台灣　報告.txt" 2>/dev/null)
[ "$got" = "IDEOGRAPHIC" ] && ok "U+3000 filename reads its own content" || bad "U+3000 filename returned '${got}' (cross-read — patch not applied)"
n=$(find "$T" -type f | wc -l)
[ "$n" = "2" ] && ok "both space variants coexist as distinct files" || bad "expected 2 files, found ${n}"
rm -rf "$T"

head_ "5. Video pipeline"

if [ "${PI_VIDEO_TOOLS_BUILT:-1}" != "1" ]; then
  skip "image built with VIDEO_TOOLS=0 — no ffmpeg, Chromium libs, CJK fonts or rclone by design"
  [ "${VIDEO_PIPELINE_ENABLED:-true}" = "true" ] && warn "VIDEO_PIPELINE_ENABLED is still true on a slim image — set it false in the unit or the bootstrap fails on every boot"
elif [ "${VIDEO_PIPELINE_ENABLED:-true}" = "true" ]; then
  [ -f "${DATA}/.video-tools-installed" ] && ok "bootstrap sentinel present" || bad "sentinel missing — still installing, or it failed (see logs)"
  # bin/python3 survives a failed ensurepip, so its existence proves nothing.
  if "${DATA}/venv/bin/python3" -c 'import ensurepip' >/dev/null 2>&1; then ok "venv usable"; else bad "venv present but broken (ensurepip missing) — rebuild with RESET_VIDEO_TOOLS=true"; fi
  command -v ffmpeg >/dev/null && ok "ffmpeg — $(ffmpeg -version 2>&1 | head -1 | cut -d' ' -f1-3)" || bad "ffmpeg missing"
  [ -d "${DATA}/playwright-cache" ] && ok "playwright cache — $(du -sh "${DATA}/playwright-cache" 2>/dev/null | cut -f1)" || bad "playwright cache missing"
else
  skip "video pipeline disabled by VIDEO_PIPELINE_ENABLED"
fi

head_ "6. Authentication, trust guard and key exposure"

AUTH_USER="${PI_ACC_USER:-woow}"
AUTH_PASS="${PI_ACC_PASS:-}"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${PROXY}/api/home" 2>/dev/null || echo 000)

if [ "$code" = "000" ]; then
  skip "nginx not reachable at ${PROXY} — set NGINX_HOST or run this from the pi-agent network"
else
  AUTH_ON=0
  if [ "$code" = "401" ]; then
    AUTH_ON=1
    ok "unauthenticated request -> 401 (Basic auth is enforced at the edge)"
    # A rule that accepts everything and a rule that accepts the right thing
    # both answer 200 to the correct password. This is the only check that
    # tells them apart, and the one that catches an htpasswd nginx cannot
    # parse — which it treats as simply unmatched rather than as an error.
    wrong=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --user "${AUTH_USER}:not-the-password-$$" "${PROXY}/api/home")
    [ "$wrong" = "401" ] && ok "wrong password -> 401" || bad "wrong password -> ${wrong}, expected 401 — the credential check is not doing anything"
  else
    warn "unauthenticated request -> ${code}: there is NO password in front of the UI"
    warn "  -> anyone who can reach :30142 gets a coding agent with a shell. Fix: scripts/set-password.sh"
  fi

  if [ "$AUTH_ON" = "1" ] && [ -z "${AUTH_PASS}" ]; then
    skip "set PI_ACC_PASS to run the authenticated proxy checks (trust guard, key exposure)"
  else
    CURL_AUTH=""
    [ -n "${AUTH_PASS}" ] && CURL_AUTH="--user ${AUTH_USER}:${AUTH_PASS}"

    # The reason the nginx container exists at all: a hostname must work
    # THROUGH the proxy, because pi-web rejects it directly.
    # shellcheck disable=SC2086
    code=$(curl -s -o /dev/null -w '%{http_code}' ${CURL_AUTH} -H 'Host: pi.example.com' -H 'Origin: https://pi.example.com' "${PROXY}/api/models-config")
    [ "$code" = "200" ] && ok "hostname Host+Origin through nginx -> 200 (shim works)" || bad "hostname through nginx -> ${code} (the Host/Origin rewrite is not applied, or the password is wrong)"

    # shellcheck disable=SC2086
    if curl -s --max-time 5 ${CURL_AUTH} -H 'Host: pi.example.com' "${PROXY}/api/models-config" | grep -q '"apiKey":"[^"]'; then
      if [ "$AUTH_ON" = "1" ]; then
        warn "/api/models-config returns the provider key in cleartext to any authenticated caller, and to anything on the container network"
      else
        warn "/api/models-config returns the provider key in cleartext to an UNAUTHENTICATED caller through the published port"
      fi
    fi
  fi

  # Needs no credentials, and is the half that proves the shim is load-bearing
  # rather than decorative. Without it, a regression that removed the header
  # rewriting would leave this suite green while every named route in the
  # browser broke.
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: pi.example.com' -H 'Origin: https://pi.example.com' "${BASE}/api/models-config")
  [ "$code" = "403" ] && ok "same headers direct to pi-web -> 403 (shim is load-bearing, not decorative)" || bad "direct to pi-web -> ${code}, expected 403 — the guard changed upstream; re-read nginx.conf's assumptions"
fi

head_ "Summary"
printf '  %d passed, %d failed, %d notes\n\n' "$PASS" "$FAIL" "$NOTE"
[ "$FAIL" -eq 0 ] || exit 1
