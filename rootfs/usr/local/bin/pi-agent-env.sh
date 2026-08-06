# Shared runtime environment for every process that touches the agent's data
# directory: the pi-web server, any shell opened with `podman exec`, and any
# subprocess the coding agent spawns.
#
# Sourced (not executed) from pi-web-start.sh, the `pi` wrapper, /etc/profile.d
# and BASH_ENV. The Containerfile ALSO bakes HOME and PI_CODING_AGENT_DIR as
# image ENV, because profile.d only reaches login shells and `podman exec -it
# pi-web bash` is not one: without the baked values that session lands on
# HOME=/root and writes into the container's ephemeral layer while the UI keeps
# reading the volume. This file remains the single place the values are
# defined; the ENV lines are a floor, not a second source of truth.

: "${PI_AGENT_DATA_DIR:=/data/pi-agent}"

# The pi coding agent stores skills, sessions, models.json and auth.json under
# this dir. Pinning it to the named volume is what makes them survive a
# container replacement — unpinned, they land on the container's ephemeral
# root filesystem.
export PI_CODING_AGENT_DIR="${PI_AGENT_DATA_DIR}"

# The agent creates per-session worktrees under $HOME/pi-cwd-*. Same reasoning.
export HOME="${PI_AGENT_DATA_DIR}/home"

export PI_TELEMETRY="${PI_TELEMETRY:-0}"
export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"

# Video pipeline. The venv is created on first boot into the named volume, so
# the PATH prepend is guarded. The guard is the sentinel, not the interpreter:
# a venv whose ensurepip step failed still leaves a working bin/python3 behind,
# and prepending that shadows the system python3 with an interpreter that has
# no packages — which is how a slim build (VIDEO_TOOLS=0) ends up reporting a
# healthy venv that cannot import anything.
if [ -f "${PI_AGENT_DATA_DIR}/.video-tools-installed" ] && [ -x "${PI_AGENT_DATA_DIR}/venv/bin/python3" ]; then
    export PATH="${PI_AGENT_DATA_DIR}/venv/bin:${PATH}"
fi
export PLAYWRIGHT_BROWSERS_PATH="${PI_AGENT_DATA_DIR}/playwright-cache"
export RCLONE_CONFIG="${PI_AGENT_DATA_DIR}/rclone/rclone.conf"
