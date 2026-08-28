# WoowTechOpenClaw Pi Agent Host Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Pi Agent rootlessly on WoowTechOpenClaw with full `woowtechopenclaw` user authority and a loopback-only authenticated UI.

**Architecture:** Clone and build the upstream package, then create a host-specific derived image with Podman/systemd clients. Extend the live Quadlet with the host home, Podman socket, and user D-Bus mounts; add a dedicated localhost SSH control path; publish nginx only on `127.0.0.1:30142`.

**Tech Stack:** Podman 4.9, Quadlet, systemd user services, OpenSSH, nginx, pi-web.

---

### Task 1: Preflight and source checkout

**Files:**
- Create: `~/Woow_podman_pi_agent_package/`

1. Verify SSH user/hostname, Podman, Quadlet, user D-Bus, localhost sshd, free TCP port 30142, and available disk space.
2. Clone `https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git` at `main`.
3. Record the exact source commit and ensure the checkout is clean.

### Task 2: Build application and host-integration images

**Files:**
- Create: `~/.config/pi-agent-host-integration/Containerfile`

1. Build the upstream image using mandatory Docker image format.
2. Create a derived Containerfile that installs only Podman and systemd clients.
3. Build `localhost/woow-podman-pi-agent-host:latest`.
4. Inspect both images and verify expected entrypoint, healthcheck, and installed clients.

### Task 3: Install base configuration without exposing the port

**Files:**
- Create: `~/.config/pi-agent/nginx.conf`
- Create: `~/.config/pi-agent/auth.conf`
- Create: `~/.config/pi-agent/htpasswd`
- Create: `~/.config/containers/systemd/pi-agent.network`
- Create: `~/.config/containers/systemd/pi-agent-data.volume`
- Create: `~/.config/containers/systemd/pi-web.container`
- Create: `~/.config/containers/systemd/nginx.container`

1. Generate Basic Auth with the plaintext delivered only to a root/user-private runtime file for later secure retrieval, never command arguments or logs.
2. Install the upstream configs and Quadlets while services remain stopped.
3. Patch nginx publishing from `0.0.0.0:30142` to `127.0.0.1:30142`.

### Task 4: Add host-user integration

**Files:**
- Modify: `~/.config/containers/systemd/pi-web.container`
- Create: Pi data volume `home/.ssh/host-control_ed25519`
- Create: Pi data volume `home/.ssh/config`
- Create: Pi data volume `home/.local/bin/host-shell`
- Create: Pi data volume `home/.local/bin/host-curl`
- Modify: `~/.ssh/authorized_keys`

1. Enable the rootless Podman socket.
2. Point the Quadlet at the derived local image and require `podman.socket`.
3. Mount `/home/woowtechopenclaw`, `/run/user/<uid>/podman/podman.sock`, and `/run/user/<uid>/bus` read-write.
4. Set host Podman and user D-Bus environment variables.
5. Generate a dedicated localhost SSH identity and install its public key for the same host user.
6. Record and pin localhost's SSH host key; configure the key for `host-control` only.
7. Install `host-shell` and `host-curl` wrappers.

### Task 5: Validate units and start services

1. Run the Quadlet generator/systemd verification before starting.
2. Reload the user manager and start `pi-web.service`, then `nginx.service`.
3. Confirm both services are boot-wanted and active.
4. Wait for Pi Web health to become `healthy`.

### Task 6: Acceptance verification

1. Assert the listener is exactly `127.0.0.1:30142` and not any-address/LAN.
2. Assert unauthenticated HTTP returns `401`.
3. Perform a temporary host-home write/read/delete probe from `pi-web`.
4. Verify host Podman from inside `pi-web` can see a known existing container.
5. Verify `systemctl --user` through the mounted D-Bus reports `podman.socket` active.
6. Verify `host-shell id -un` returns `woowtechopenclaw`.
7. Verify `host-curl` reaches a known host-loopback endpoint.
8. Run the upstream structural acceptance suite.
9. Check recent Pi Web logs for fatal errors and report residual risks.

### Task 7: Document deployment state

**Files:**
- Create: `~/Woow_podman_pi_agent_package/docs/plans/2026-08-28-openclaw-host-integration-design.md`
- Create: `~/Woow_podman_pi_agent_package/docs/plans/2026-08-28-openclaw-host-integration.md`

1. Copy the validated design and implementation plan into the deployed checkout.
2. Commit only documentation to the local deployment checkout; do not push upstream.
3. Record source commit, local documentation commit, image IDs, unit paths, and residual risks.
