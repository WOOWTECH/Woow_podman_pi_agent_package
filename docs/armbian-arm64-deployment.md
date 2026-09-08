# Deploying on Armbian / arm64 with a Podman older than 4.4

Field notes from bringing this stack up on an Allwinner H618 board running
Armbian OS 26.08 (Debian 12 bookworm, aarch64, kernel 6.18 ophub). Everything
here is about the host, not the application: the units and the image are the
ones this repo ships.

The short version: `scripts/install.sh` requires Quadlet, Quadlet requires
Podman >= 4.4, and Debian 12 has no path to that. The way through is a parallel
Podman install under `/usr/local`, and then five smaller things break in a row.

---

## 1. There is no apt route to Podman >= 4.4 on bookworm/arm64

Checked, rather than assumed:

| Source | Podman | Verdict |
|---|---|---|
| `bookworm/main` | 4.3.1 | too old for Quadlet |
| `bookworm-backports` | *no podman package at all* | dead end |
| `trixie/main` | 5.4.2 | needs libc6 2.41; a partial upgrade in practice |
| alvistack `Debian_12` | 6.1.1 | **amd64 only** — 0 arm64 packages |

Verify the backports claim yourself:

```sh
curl -s https://deb.debian.org/debian/dists/bookworm-backports/main/binary-arm64/Packages.gz \
  | gunzip -c | grep -c '^Package: podman$'      # -> 0
```

Pinning trixie or running a dist-upgrade will pull libc6 and its dependents. On
a headless board reachable only over SSH, with a vendor kernel, that is a real
chance of never getting back in. Consider it only with physical access.

## 2. Parallel install: podman-static under /usr/local

[mgoltzsche/podman-static](https://github.com/mgoltzsche/podman-static)
publishes a linux-arm64 tarball with podman, crun, runc, conmon, netavark,
aardvark-dns, rootlessport, pasta, fuse-overlayfs **and the Quadlet
generator**. Everything lands in `/usr/local`; nothing in `/usr` is touched.

```sh
curl -fsSL -o podman.tgz \
  https://github.com/mgoltzsche/podman-static/releases/download/v6.1.1/podman-linux-arm64.tar.gz
tar xzf podman.tgz -C / --strip-components=1 podman-linux-arm64/usr/local
chown -R root:root /usr/local/bin /usr/local/libexec /usr/local/lib
```

**Extract only `usr/local`.** The tarball also carries `/etc/containers/*`.
Installing those switches the storage driver to overlay+fuse-overlayfs, and if
your existing store is vfs, every image already built on the host becomes
invisible.

`scripts/install.sh` probes three fixed paths for the generator, none of them
under `/usr/local`. One symlink satisfies it:

```sh
mkdir -p /usr/libexec/podman
ln -sfn /usr/local/libexec/podman/quadlet /usr/libexec/podman/quadlet
```

systemd 252 does scan `/usr/local/lib/systemd/user-generators`, so the
generator itself needs no help. Confirm before trusting it — drop a throwaway
`.container` file in `~/.config/containers/systemd/`, `systemctl --user
daemon-reload`, and check that `systemctl --user list-unit-files` reports the
matching `.service` as `generated`.

### Two Podmans on one host

`/usr/local/bin` precedes `/usr/bin` on PATH, so a bare `podman` now resolves to
the new one. If anything else on the box runs rootful Podman — a Home Assistant
container, say — it keeps its own store under `/var/lib/containers` and its own
database, and it must keep using `/usr/bin/podman` by absolute path.

Running a bare `podman` as root will offer to migrate *that* database too.
Decline it unless that is what you actually mean.

## 3. Rootless store migration, 4.3.x -> 6.x

Podman 6 dropped BoltDB. Three things go wrong in sequence.

**The migration refuses to start.** A lock file left by the old Podman:

```
Error: failed to open 2048 locks in /libpod_rootless_lock_1000:
       numerical result out of range
```

Remove the *rootless* lock file only — `/dev/shm/libpod_lock` belongs to the
rootful stack and may be in active use:

```sh
rm -f /dev/shm/libpod_rootless_lock_<uid>
podman system migrate --migrate-db
podman system renumber          # or containers and volumes deadlock on lock ID 0
```

Skipping `renumber` produces:

```
Error: container <id> and volume <name> share lock ID 0: deadlock due to lock mismatch
```

**The old database keeps coming back.** Anything that still calls the 4.3.x
binary recreates `bolt_state.db`, and Podman 6 then refuses to run at all.
Audit every periodic caller before migrating. In this repo,
`systemd/pi-web-health.service` invokes `/usr/bin/podman` every 30 seconds; any
site-local supervisor script is likely to as well. Point them at the new binary
or stop them for the duration.

**The store becomes ambiguous.** Podman 6 prefers overlay and creates an empty
overlay skeleton on every invocation. Next to an existing vfs store that yields:

```
Error: configure storage: ... contains several valid graphdrivers: overlay, vfs
```

Delete the empty `overlay*` directories and pin the driver for the user. Pin it
in `~/.config/containers/storage.conf`, not `/etc` — a system-wide file with a
`[storage]` section but no `runroot` breaks the apt Podman that the rootful
containers still depend on (`Failed to obtain podman configuration: runroot must
be set`):

```toml
[storage]
driver = "vfs"
graphroot = "/home/<user>/.local/share/containers/storage"
runroot = "/run/user/<uid>/containers"
```

vfs has no copy-on-write: each container creation copies the whole image. For
this image that is roughly 1.4GB and about 90 seconds per start on eMMC. Moving
to overlay is worth it, but it means rebuilding every image.

## 4. cgroup manager must be cgroupfs

The crun bundled with podman-static is a static build without libsystemd. Under
the systemd cgroup manager every container creation, `podman build` included,
fails with:

```
error running container: from /usr/local/bin/crun creating container ...:
systemd not supported: Not supported
```

Use cgroupfs, and pin the runtime so it cannot pick up an older crun belonging
to the apt Podman:

```toml
[engine]
cgroup_manager = "cgroupfs"
runtime = "crun"
[engine.runtimes]
crun = ["/usr/local/bin/crun"]
```

Rootless on cgroups v2 is fine under cgroupfs; systemd still supervises the
podman process through the Quadlet-generated unit.

## 5. netavark 2.x needs nft

netavark 2 removed the iptables firewall backend. `firewall_driver = "iptables"`
is now rejected outright:

```
Error: netavark: Must provide a valid firewall backend, got iptables
```

and without the binary you get:

```
netavark: nftables error: unable to execute "nft": No such file or directory
```

Install the `nftables` package for `/usr/sbin/nft`. On Debian 12 `iptables` is
already `iptables-nft`, so both stacks end up in the same kernel subsystem.
Installing the package changed no rules here (nat 7, filter 16 before and
after) and `nftables.service` stays disabled.

## 6. Health status stays `starting`

Known, and this repo already ships the workaround. Podman's native rootless
health timer does not register, so `podman ps` shows `(starting)` indefinitely
even while `/api/home` answers 200. `pi-web-health.timer` refreshes the state
every 30s.

Note that `scripts/install.sh` runs under `set -euo pipefail` and enables that
timer *after* starting `pi-web.service`. If the first start fails for any of the
reasons above, the script exits before the timer is enabled and the container
looks unhealthy even once the real fault is fixed. Enable it by hand after a
failed run:

```sh
systemctl --user enable --now pi-web-health.timer
```

## 7. install.sh needs a user session bus

Running it through `su - <user>` gives `Failed to connect to bus: No medium
found` at the `systemctl --user daemon-reload` step. Either log in as the user
properly, or export the session variables:

```sh
export XDG_RUNTIME_DIR=/run/user/<uid>
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus
```

The script is idempotent, so re-running it after that is safe.

## 8. Adapting the units to a different account

`quadlet/pi-web.container` names `/home/woowtechopenclaw` in two places, the
bind mount and `HOST_HOME`. The `/run/user/1000/...` paths in the same file
assume that account is uid 1000, so on a host where uid 1000 is a different
user only the home path needs changing.

Keep such edits in the working tree rather than in the installed copies:
`install.sh` verifies that what it installed matches its source, and
`git diff` then shows exactly how the deployment differs from this repo.

`tests/host-profile.sh` asserts the reference machine's literal values, so it
fails on those edits by design. The remaining assertions — loopback-only
publish, no 0.0.0.0 publish, the socket and bus mounts, `NoNewPrivileges`,
health timer cadence, no nginx leftovers — still pass and are the ones worth
watching.

## 9. If the image is built with VIDEO_TOOLS=0

Set `VIDEO_PIPELINE_ENABLED=false` in the unit, as the comment in
`quadlet/pi-web.container` says. Leaving it true is harmless — `pi-web-start.sh`
checks `PI_VIDEO_TOOLS_BUILT` and logs a skip rather than attempting the
download — but the acceptance suite will (correctly) flag the mismatch.

---

## Verifying the result

```sh
systemctl --user show pi-web.service -p FragmentPath -p UnitFileState
# FragmentPath=/run/user/<uid>/systemd/generator/pi-web.service
# UnitFileState=generated

podman ps                       # pi-web ... (healthy)
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30141/
podman exec -i pi-web bash -s < tests/acceptance.sh
```

The image does not ship `tests/` — only `patches/` and `rootfs/` are `COPY`ed —
so pipe the suite in rather than looking for it at `/opt/tests`.

Host-control checks, once the OpenClaw profile is running:

```sh
podman exec pi-web podman --remote ps          # host's rootless containers
podman exec pi-web ls "$HOST_HOME"             # host home, rw
podman exec pi-web systemctl --user is-active pi-web.service
```
