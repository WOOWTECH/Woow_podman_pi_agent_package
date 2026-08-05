#!/usr/bin/env bash
# Remove the Woow Podman Pi Agent units. The data volume is KEPT by default —
# it holds sessions, skills and the provider configuration, and deleting a
# deployment should not be how you lose them.
#
#   ./uninstall.sh            keep pi-agent-data
#   ./uninstall.sh --purge    delete pi-agent-data as well
set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
PURGE="${1:-}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "Stopping services"
systemctl --user stop nginx.service pi-web.service 2>/dev/null || true

say "Removing Quadlet units"
for unit in nginx.container pi-web.container pi-agent-data.volume pi-agent.network; do
  rm -f "${QUADLET_DIR}/${unit}"
done
systemctl --user daemon-reload

if [ "${PURGE}" = "--purge" ]; then
  say "Deleting the data volume (--purge given)"
  podman volume rm -f pi-agent-data 2>/dev/null || true
else
  say "Keeping volume pi-agent-data — remove with: podman volume rm pi-agent-data"
fi

say "Done"
