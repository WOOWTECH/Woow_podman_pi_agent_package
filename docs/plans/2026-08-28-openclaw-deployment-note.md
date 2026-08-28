# WoowTechOpenClaw Pi Agent Deployment Note

## Selected local profile

This checkout is the host-specific source of truth for `woowtechopenclaw`. The selected Quadlets intentionally use `localhost/woow-podman-pi-agent-host:latest`, mount the user's home, rootless Podman socket and user D-Bus, and publish nginx only on `127.0.0.1:30142`. `scripts/install.sh` installs these exact files and verifies source/installed equality so a reinstall cannot silently restore LAN exposure or remove host control.

`Containerfile.host-control` is the reproducible recipe for the derived client image. The initial image had to be created through a temporary ordinary container and `podman commit` because this host's Podman 4.9 build namespace could not resolve package mirrors while ordinary containers could. Rebuild the recipe normally once that host build-network defect is corrected.

## Credential ownership

nginx request workers run as the image's `nginx` group. `scripts/set-password.sh` therefore publishes htpasswd atomically as container-visible `root:nginx` mode `0640` through `podman unshare`. Host mode `0600` is incorrect for this bind mount: the rootless nginx master can open it, but request workers cannot validate credentials.

## Health scheduling

Podman 4.9 failed to register its native rootless health timer during the first container start. `pi-web-health.timer` begins after 150 seconds and runs `podman healthcheck run pi-web` about every 30 seconds. It only refreshes health state; it never restarts the application. Native scheduling may coexist with this workaround if a later Podman release succeeds.

## Security boundary and residual risk

Pi Agent has all authority of `woowtechopenclaw` by explicit approval, including write access to the whole home, rootless containers, user services and arbitrary host-user commands. It has no passwordless sudo: `sudo -n` is denied. However, the existing account belongs to the `sudo` group and has a password, so it is not a durable non-administrative identity. Only an authorized administrator can remove that risk by using a dedicated non-sudo account or changing host account policy. This deployment does not alter groups, passwords, sudoers or root-owned files.

The dedicated host-control authorized key is de-duplicated and prefixed with `restrict`. No `from=` restriction is used because the observed source is a host LAN address whose stability cannot be guaranteed; a stale restriction could break approved host control. Because the whole home is intentionally writable, Pi can still rewrite `authorized_keys`; the key option is hardening, not an isolation boundary.

A controlled reboot test remains deferred because it would affect unrelated host services. Deployment-specific acceptance records are stored privately under `~/.local/state/pi-agent/acceptance/`.
