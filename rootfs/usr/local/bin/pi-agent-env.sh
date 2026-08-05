# Shared runtime environment for every process that touches the agent's data
# directory: the pi-web server, any shell opened with `podman exec`, and any
# subprocess the coding agent spawns.
#
# Sourced (not executed) from pi-web-start.sh, the `pi` wrapper, and
# /etc/profile.d so an interactive `podman exec -it pi-web bash -l` lands in
# exactly the same environment the server runs in. Divergence here is how you
# get "it works in the UI but not in the terminal" bugs.

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
# the PATH prepend is guarded — on a cold volume the venv does not exist yet
# and an unconditional prepend would shadow the system python3 with a missing
# one.
if [ -x "${PI_AGENT_DATA_DIR}/venv/bin/python3" ]; then
    export PATH="${PI_AGENT_DATA_DIR}/venv/bin:${PATH}"
fi
export PLAYWRIGHT_BROWSERS_PATH="${PI_AGENT_DATA_DIR}/playwright-cache"
export RCLONE_CONFIG="${PI_AGENT_DATA_DIR}/rclone/rclone.conf"
