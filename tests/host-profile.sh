#!/usr/bin/env bash
# tests/host-profile.sh: static checks on the committed host-control profile. Runs in CI
# (from tests/dryrun.local.sh) and locally; reads files only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
C=quadlet/pi-web.container

for s in scripts/*.sh tests/*.sh; do bash -n "$s"; done
# refute CMD...: fail when CMD succeeds (a bare `! cmd` never trips set -e)
refute() { if "$@"; then echo "host-profile: FAIL: unexpected match: $*" >&2; exit 1; fi; }

# pi-web must publish loopback-only so a same-host reverse proxy can reach it and nothing
# on the LAN can. Widening it puts a root-equivalent shell on the network.
grep -qx 'PublishPort=127.0.0.1:30141:30141' "$C"
refute grep -qE '^PublishPort=(0\.0\.0\.0:)?30141' "$C"
grep -qx 'NoNewPrivileges=true' "$C"

# The image tag is pinned (<pi-web version>-r<revision>, plus the rendered -slim variant),
# and its version matches the Containerfile's pi-web.
grep -qxE 'Image=localhost/woow-podman-pi-agent-host:[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+@@PI_IMAGE_VARIANT@@' "$C"
grep -qx 'Pull=never' "$C"
refute grep -qE '^AutoUpdate=' "$C"
tag=$(sed -n 's/^Image=localhost\/woow-podman-pi-agent-host:\(.*\)@@PI_IMAGE_VARIANT@@$/\1/p' "$C")
ver=$(sed -n 's/^ARG PI_WEB_VERSION=//p' Containerfile | head -n1)
[ "${tag%-r*}" = "$ver" ] || { echo "Image tag $tag does not match ARG PI_WEB_VERSION=$ver" >&2; exit 1; }
# The host-control layer defaults to the locally built base of the same tag; a ghcr.io
# default would point at an image that was never published.
grep -qx "ARG BASE_IMAGE=localhost/woow-podman-pi-agent:$tag" Containerfile.host-control
# shellcheck disable=SC2016 # literal ${BASE_IMAGE}, as written in the Containerfile
grep -qx 'FROM ${BASE_IMAGE}' Containerfile.host-control

# Host-control mounts through systemd specifiers only: no account or uid is hardcoded.
grep -qx 'Volume=%h:/host%h:rw' "$C"
grep -qx 'Volume=%t/podman/podman.sock:/run/host/podman/podman.sock:rw' "$C"
grep -qx 'Volume=%t/bus:/run/host/user-bus:rw' "$C"
grep -qx 'Environment=HOST_HOME=/host%h' "$C"
# (/data/pi-agent/home is the agent's in-volume HOME, not a host path.)
refute grep -rqE '(^|[[:space:]=:])(/host)?/home/[A-Za-z0-9_.-]+|/run/user/[0-9]+' quadlet/ systemd/ config/

# Health timer cadence; bare podman so podman-static hosts get their own binary.
grep -qx 'OnActiveSec=150s' systemd/pi-web-health.timer
grep -qx 'OnUnitActiveSec=30s' systemd/pi-web-health.timer
grep -qx 'ExecCondition=podman container exists pi-web' systemd/pi-web-health.service
grep -qx 'ExecStart=podman healthcheck run pi-web' systemd/pi-web-health.service

# install.sh builds the base before the host layer and enables the timer before pi-web.
# shellcheck disable=SC2016 # literal "$REPO", as written in install.sh
grep -q -- '-f "$REPO/Containerfile" ' scripts/install.sh
# shellcheck disable=SC2016
grep -q -- '-f "$REPO/Containerfile.host-control" ' scripts/install.sh
grep -q 'enable --now pi-web-health.timer' scripts/install.sh

# The removed nginx sidecar must not come back.
refute grep -q 'nginx.container\|nginx.conf\|set-password\|--no-auth\|htpasswd\|auth.conf' scripts/install.sh
refute grep -q 'nginx.container\|nginx.service' scripts/uninstall.sh
[ ! -e quadlet/nginx.container ]
[ ! -e config/nginx.conf ]
[ ! -e scripts/set-password.sh ]

echo 'host-profile static checks: PASS'
