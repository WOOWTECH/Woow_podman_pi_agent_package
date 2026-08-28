# WoowTechOpenClaw Pi Agent Host Integration Design

## Goal

Deploy Woow Podman Pi Agent as the unprivileged `woowtechopenclaw` account and give it the full authority of that account, without granting root or exposing the web UI beyond host loopback.

## Architecture

The upstream stack remains rootless and supervised by Quadlet/user systemd. A host-specific derived image extends `ghcr.io/woowtech/woow-podman-pi-agent:latest` with Podman and systemd client packages. The live `pi-web.container` uses that derived image and bind-mounts the host user's home, rootless Podman socket, and user D-Bus socket. `CONTAINER_HOST`, `DOCKER_HOST`, and `DBUS_SESSION_BUS_ADDRESS` direct tools inside Pi Agent to the host services.

A dedicated localhost-only SSH identity gives the container a general host command path as `woowtechopenclaw`. The key is limited by file permissions and connects only to a verified localhost host key. Helper commands `host-shell` and `host-curl` expose arbitrary host-user commands and host-loopback HTTP access. This intentionally gives model-authored commands every privilege held by `woowtechopenclaw`, but no sudo or host root authority.

The nginx Quadlet publishes only `127.0.0.1:30142:30142`. HTTP Basic authentication remains enabled as defense in depth. Pi Web itself remains on the private `pi-agent` network with no published port.

## Security Boundaries

- No sudo, privileged container, host PID namespace, host network, or host root bind mount.
- The agent can read and modify all files available to `woowtechopenclaw` and control all of that user's rootless containers and user services.
- The web endpoint is inaccessible directly from LAN interfaces.
- Provider credentials remain inside the persistent Pi Agent volume.
- The localhost SSH private key is dedicated to this integration and is not reused for external hosts.

## Verification

Verify the SSH identity and host key, Pi Web health, user service boot enablement, loopback-only port binding, Basic Auth rejection, host-home read/write with cleanup, host Podman visibility, user systemd access, host-shell identity, host-loopback HTTP access, and absence of recent fatal Pi Web errors.
