#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

bash -n scripts/install.sh scripts/uninstall.sh

# pi-web must publish loopback-only so a same-host reverse proxy can reach it
# and nothing on the LAN can. Widening to 0.0.0.0 puts an unauthenticated
# /api/models-config on the network.
grep -qx 'PublishPort=127.0.0.1:30141:30141' quadlet/pi-web.container
! grep -q 'PublishPort=0\.0\.0\.0:30141:30141' quadlet/pi-web.container
grep -qx 'Image=localhost/woow-podman-pi-agent-host:latest' quadlet/pi-web.container
grep -qx 'Volume=/home/woowtechopenclaw:/host/home/woowtechopenclaw:rw' quadlet/pi-web.container
grep -qx 'Volume=/run/user/1000/podman/podman.sock:/run/host/podman/podman.sock:rw' quadlet/pi-web.container
grep -qx 'Volume=/run/user/1000/bus:/run/host/user-bus:rw' quadlet/pi-web.container
grep -qx 'NoNewPrivileges=true' quadlet/pi-web.container

grep -qx 'OnActiveSec=150s' systemd/pi-web-health.timer
grep -qx 'OnUnitActiveSec=30s' systemd/pi-web-health.timer
grep -qx 'ExecCondition=/usr/bin/podman container exists pi-web' systemd/pi-web-health.service
grep -qx 'ExecStart=/usr/bin/podman healthcheck run pi-web' systemd/pi-web-health.service

# install.sh must NOT reference the removed sidecar
! grep -q 'nginx.container\|nginx.conf\|set-password\|--no-auth\|htpasswd\|auth.conf' scripts/install.sh
! grep -q 'nginx.container\|nginx.service' scripts/uninstall.sh

# Repo must not still ship the sidecar or its password tooling
[ ! -e quadlet/nginx.container ]
[ ! -e config/nginx.conf ]
[ ! -e scripts/set-password.sh ]

grep -q 'pi-web-health.timer' scripts/install.sh scripts/uninstall.sh

echo 'host-profile static checks: PASS'
