#!/usr/bin/env bash
# Acceptance suite for the Podman deployment.
#
#   podman exec -it pi-web bash /opt/tests/acceptance.sh
#
# Checks that need no LLM run first and are free; the conversation tests come
# last and cost tokens. Every check prints PASS/FAIL with the evidence inline,
# so a failure is actionable without re-running anything.
#
# Written to be comparable with the k3s deployment: the same properties, in the
# same order, so a difference between the two is a porting defect rather than a
# difference in how they were measured.
set -uo pipefail

DATA="${PI_AGENT_DATA_DIR:-/data/pi-agent}"
BASE="http://127.0.0.1:${PI_WEB_PORT:-30141}"
CWD="${DATA}/home/pi-cwd-$(date +%Y%m%d)"
PASS=0; FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "1. Runtime"

if v=$(pi --version 2>/dev/null); then ok "pi on PATH — $v"; else bad "pi not on PATH (the launcher failed; terminal workflows are dead)"; fi
if v=$(node --version 2>/dev/null); then ok "node — $v"; else bad "node missing"; fi
[ -n "${PI_CODING_AGENT_DIR:-}" ] && ok "PI_CODING_AGENT_DIR=${PI_CODING_AGENT_DIR}" || bad "PI_CODING_AGENT_DIR unset"
[ "${HOME}" = "${DATA}/home" ] && ok "HOME pinned to the volume — ${HOME}" || bad "HOME is ${HOME}, expected ${DATA}/home"
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
      models.json|auth.json) [ "$m" = "600" ] && ok "${f} mode ${m}" || bad "${f} mode ${m}, expected 600 (holds the provider key)" ;;
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

if [ "${VIDEO_PIPELINE_ENABLED:-true}" = "true" ]; then
  [ -f "${DATA}/.video-tools-installed" ] && ok "bootstrap sentinel present" || bad "sentinel missing — still installing, or it failed (see logs)"
  [ -x "${DATA}/venv/bin/python3" ] && ok "venv python present" || bad "venv missing"
  command -v ffmpeg >/dev/null && ok "ffmpeg — $(ffmpeg -version 2>&1 | head -1 | cut -d' ' -f1-3)" || bad "ffmpeg missing"
  [ -d "${DATA}/playwright-cache" ] && ok "playwright cache — $(du -sh "${DATA}/playwright-cache" 2>/dev/null | cut -f1)" || bad "playwright cache missing"
else
  printf '  SKIP  video pipeline disabled by VIDEO_PIPELINE_ENABLED\n'
fi

head_ "Summary"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
