#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

bash -n scripts/install.sh scripts/uninstall.sh scripts/set-password.sh

grep -qx 'PublishPort=127.0.0.1:30142:30142' quadlet/nginx.container
! grep -q 'PublishPort=0\.0\.0\.0:30142:30142' quadlet/nginx.container
grep -qx 'NoNewPrivileges=true' quadlet/nginx.container
grep -qx 'Image=localhost/woow-podman-pi-agent-host:latest' quadlet/pi-web.container
grep -qx 'Volume=/home/woowtechopenclaw:/host/home/woowtechopenclaw:rw' quadlet/pi-web.container
grep -qx 'Volume=/run/user/1000/podman/podman.sock:/run/host/podman/podman.sock:rw' quadlet/pi-web.container
grep -qx 'Volume=/run/user/1000/bus:/run/host/user-bus:rw' quadlet/pi-web.container
grep -qx 'OnActiveSec=150s' systemd/pi-web-health.timer
grep -qx 'OnUnitActiveSec=30s' systemd/pi-web-health.timer
grep -qx 'ExecCondition=/usr/bin/podman container exists pi-web' systemd/pi-web-health.service
grep -qx 'ExecStart=/usr/bin/podman healthcheck run pi-web' systemd/pi-web-health.service
grep -q 'podman unshare chown' scripts/set-password.sh
grep -q 'chmod 0640' scripts/set-password.sh
grep -q 'pi-web-health.timer' scripts/install.sh scripts/uninstall.sh

echo 'host-profile static checks: PASS'
