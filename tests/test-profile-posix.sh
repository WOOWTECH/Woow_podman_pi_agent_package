#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${ROOT}/rootfs/etc/profile.d/pi-agent.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ENV_FILE="${WORK}/pi-agent-env.sh"
PROFILE_COPY="${WORK}/pi-agent.sh"

cat >"${ENV_FILE}" <<'EOF'
export PI_AGENT_PROFILE_TEST=loaded
EOF

# Substitute the image path with the temporary fixture while preserving the
# command form used by a login shell in the image.
sed "s|/usr/local/bin/pi-agent-env.sh|${ENV_FILE}|g" "${PROFILE}" >"${PROFILE_COPY}"

if ! output="$(dash -c '. "$1"; test "${PI_AGENT_PROFILE_TEST:-}" = loaded' sh "${PROFILE_COPY}" 2>&1)"; then
  printf 'POSIX profile loading failed:\n%s\n' "${output}" >&2
  exit 1
fi

if [ -n "${output}" ]; then
  printf 'POSIX profile loading wrote unexpected stderr/stdout:\n%s\n' "${output}" >&2
  exit 1
fi

echo "POSIX login profile: PASS"
