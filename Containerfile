# Woow Podman Pi Agent — pi-web + the pi coding agent, built for rootless Podman.
#
# BUILD WITH --format=docker. This file uses SHELL and HEALTHCHECK, which the
# OCI image format has no field for; buildah's default OCI output drops or
# rejects them. Podman honours a Docker-format HEALTHCHECK natively and reports
# it in `podman ps`, which is the whole reason it is here:
#
#   podman build --format=docker -t ghcr.io/woowtech/woow-podman-pi-agent:latest -f Containerfile .
#
# This is NOT the k3s image with Kubernetes bits removed. It is built for a
# different runtime and the differences are deliberate:
#
#   - No ttyd. On Kubernetes a browser terminal was the only practical way to
#     reach a shell inside the pod. Under Podman `podman exec -it pi-web bash`
#     is the native answer, so the sidecar and its password Secret both go away.
#     As of pi-web 0.9.0 there is also a browser terminal built into the UI
#     itself (/api/terminal, SSE), which makes a ttyd sidecar redundant here for
#     a second, independent reason.
#   - No kubectl, no s6-overlay, no bashio. systemd supervises via Quadlet.
#   - A real HEALTHCHECK instruction. Podman honours it natively and surfaces
#     the result in `podman ps`; there is no need to emulate Kubernetes'
#     three-probe model.
#
# Rootless note: the container runs as root INSIDE its user namespace, which
# maps to the unprivileged host user (uid 1000). That is a meaningful security
# improvement over the k3s deployment, which ran as real root on the node.


# =============================================================================
# Stage 1 — build pi-web (and compile node-pty) in a throwaway toolchain image.
# =============================================================================
#
# WHY A BUILDER STAGE EXISTS AS OF pi-web 0.9.0
#
# 0.9.0 added a browser terminal, and with it a hard dependency on node-pty,
# which is a native addon. node-pty 1.1.0 ships prebuilt binaries for darwin
# and win32 ONLY — there is no linux-x64 or linux-arm64 prebuild — so its
# install script falls through to `node-gyp rebuild`:
#
#     install: "node scripts/prebuild.js || node-gyp rebuild"
#
# Measured against the 0.8.4 runtime image, which has neither make nor g++:
#
#     gyp ERR! build error
#     gyp ERR! stack Error: not found: make
#     gyp ERR! not ok
#
# So a compiler is now REQUIRED to build this image. It is not required to run
# it, and shipping ~250MB of gcc/binutils inside a container that executes
# model-authored shell commands is not a trade worth making. The toolchain
# therefore lives here and only the finished tree is copied forward.
#
# The two stages MUST resolve to the same Node major, or the compiled
# pty.node will not load. Both install nodejs from the same node_22.x
# NodeSource suite in the same build, and the runtime stage re-requires the
# module as a build-time assertion (see "node-pty loads" below), so an ABI
# mismatch fails the build instead of surfacing as a dead terminal in the UI.
FROM debian:bookworm-slim AS piweb-builder

ENV LANG=C.UTF-8 \
    NODE_ENV=production \
    npm_config_cache=/tmp/npm-cache \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# build-essential + python3 are node-gyp's requirements. git/openssh-client are
# not needed here — nothing in the install path shells out to them at BUILD
# time; they are runtime deps of the `skills` CLI and are installed in stage 2.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl gnupg build-essential python3 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# pi-web ships a pre-built .next/ in its npm tarball and imports the coding
# agent as a library, so there is no separate agent daemon.
#
# Pinned deliberately. pi-web's own Host/Origin trust guard and its /api/*
# surface are what the nginx config is written against. Bump only after
# re-running the acceptance suite.
#
# 0.9.0 notes, both verified against the built middleware.js:
#   - the guard's matcher widened from "/api/:path*" to ["/", "/api/:path*"],
#     so the HTML entry point is host-checked too and answers a PLAIN-TEXT 403
#     "Untrusted request" (not the JSON body) when it fails. The nginx config
#     already rewrites Host for the whole `location /`, so this is a no-op here
#     — but it is the first thing to suspect if a future proxy change breaks.
#   - PI_WEB_PASSWORD now enables built-in Basic Auth (username "pi").
#     Unused in this deployment; nginx and the network boundary are the control.
ARG PI_WEB_VERSION=0.9.0
RUN npm install -g --omit=dev --prefix=/opt/piweb "@agegr/pi-web@${PI_WEB_VERSION}" \
    && rm -rf /tmp/npm-cache

# node-gyp is allowed to fail silently in some npm configurations, and a
# missing pty.node turns into a terminal that opens and immediately dies at
# runtime. Assert the artifact exists and actually loads, here, where the
# failure is a red build instead of a support ticket.
RUN set -euo pipefail; \
    PTY="/opt/piweb/lib/node_modules/@agegr/pi-web/node_modules/node-pty"; \
    test -f "${PTY}/build/Release/pty.node" \
      || { echo "[build] FAIL: node-pty was not compiled for linux" >&2; exit 1; }; \
    node -e 'const p=require(process.argv[1]); if (typeof p.spawn !== "function") { throw new Error("node-pty loaded but has no spawn()"); } console.log("[build] node-pty OK");' "${PTY}"

# Stop silent CJK path corruption. Upstream folds U+3000 and other Unicode
# spaces to ASCII on every read/write/edit and builds the read fallback chain
# from the folded path, so writes land at the wrong name while reporting
# success, and two files differing only by space type cross-read. The patch
# asserts every hunk, so an upstream bump fails the build rather than shipping
# an image that quietly lost the fix.
#
# Still required at pi-coding-agent 0.85.1: the only change upstream made to
# these files since 0.83.0 was renaming a `signal` parameter to `context`.
COPY patches/ /opt/patches/
RUN set -euo pipefail; \
    mapfile -d '' FILES < <(find /opt/piweb/lib/node_modules/@agegr/pi-web \
      -path '*@earendil-works/*/dist/*/tools/path-utils.js' -print0); \
    echo "[patch] found ${#FILES[@]} path-utils.js copies"; \
    if [ "${#FILES[@]}" -lt 2 ]; then \
      echo "[patch] FAIL: expected at least 2 copies, found ${#FILES[@]}" >&2; \
      exit 1; \
    fi; \
    node /opt/patches/fix-unicode-space-paths.mjs "${FILES[@]}"


# =============================================================================
# Stage 2 — the runtime image. No compiler, no npm registry access.
# =============================================================================
FROM debian:bookworm-slim

ENV LANG=C.UTF-8 \
    NODE_ENV=production \
    npm_config_cache=/tmp/npm-cache \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    PI_TELEMETRY=0 \
    PI_SKIP_VERSION_CHECK=1 \
    DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Set VIDEO_TOOLS=0 to build a ~700MB image without the video toolchain.
# Default 1 keeps parity with the k3s deployment. When you build with 0, also
# set VIDEO_PIPELINE_ENABLED=false in the Quadlet unit — otherwise the
# entrypoint starts a bootstrap that cannot succeed and logs a failed venv on
# every boot.
ARG VIDEO_TOOLS=1

# Base runtime. ca-certificates/curl/git/gnupg/jq/openssh-client are needed by
# the provider check, the models.json merge and the `skills` CLI, which shells
# out to git and ssh. tini reaps: the agent's bash tool forks freely and
# without an init every abandoned child would linger as a zombie. As of 0.9.0
# the built-in browser terminal forks a login shell per session through
# node-pty, which makes the reaper load-bearing rather than merely tidy.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl git gnupg jq openssh-client tini procps less vim-tiny \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Video toolchain. fonts-noto-cjk is not optional for a zh-TW deployment:
# nothing else in Debian carries CJK glyphs for libass subtitle burn. The
# Chromium .so set is what Playwright's downloaded browser links against at
# capture time; the browser binary itself lands on the volume at first boot.
RUN if [ "${VIDEO_TOOLS}" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
         python3 python3-venv python3-pip \
         ffmpeg \
         fonts-noto-cjk fonts-noto-color-emoji fontconfig \
         libnss3 libatk-bridge2.0-0 libcups2 libxcomposite1 libxdamage1 \
         libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 \
      && ARCH="$(dpkg --print-architecture)" \
      && curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${ARCH}.deb" -o /tmp/rclone.deb \
      && dpkg -i /tmp/rclone.deb \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    else \
      echo "VIDEO_TOOLS=0 — skipping ffmpeg, Chromium libs, fonts and rclone"; \
    fi

# The finished, patched pi-web tree from stage 1. `npm install -g --prefix` put
# it under /opt/piweb/{lib,bin}, so it lands at /usr/local unchanged and the
# `pi-web` bin stays a working RELATIVE symlink into lib/node_modules.
COPY --from=piweb-builder /opt/piweb/lib/node_modules /usr/local/lib/node_modules
COPY --from=piweb-builder /opt/piweb/bin              /usr/local/bin

COPY rootfs/ /

RUN chmod +x /usr/local/bin/pi /usr/local/bin/pi-web-start.sh /usr/local/bin/video-tools-init.sh \
    # Fail the build rather than ship an image where `pi` resolves to nothing.
    # Upstream installs the coding agent only as a transitive dependency, so npm
    # never links its bin — without the launcher, every terminal workflow dies.
    && test -x "$(command -v pi)" \
    && pi --version \
    # node-pty loads. This is the cross-stage ABI assertion: stage 1 compiled
    # pty.node against ITS nodejs, and this is the first moment the module is
    # asked to load under the nodejs that will actually run it.
    && node -e 'const p=require("/usr/local/lib/node_modules/@agegr/pi-web/node_modules/node-pty"); if (typeof p.spawn !== "function") { throw new Error("node-pty has no spawn()"); } console.log("[build] node-pty loads under the runtime node");'

ARG BUILD_VERSION=dev
ARG BUILD_REF=unknown
ARG PI_WEB_VERSION=0.9.0

ENV PI_AGENT_IMAGE_VERSION=${BUILD_VERSION} \
    PI_WEB_VERSION=${PI_WEB_VERSION} \
    PI_AGENT_DATA_DIR=/data/pi-agent \
    PI_WEB_PORT=30141

# Baked into the image so EVERY entry point inherits them, not just login
# shells. pi-agent-env.sh is sourced from /etc/profile.d, which `podman exec
# pi-web bash` (interactive but not a login shell) and `podman exec pi-web bash
# script.sh` never read. Those sessions then run with HOME=/root, so a
# `pi install` from a shell writes the skill into the container's ephemeral
# layer while the UI keeps reading the volume — the install reports success and
# the skill never appears. Observed on the first Podman deployment.
#
# BASH_ENV covers non-interactive bash (including the agent's own bash tool) so
# the venv PATH guard in pi-agent-env.sh still applies there.
#
# SHELL is what pi-web 0.9.0's browser terminal spawns:
#     process.env.SHELL || "/bin/sh"   with argv ["-l"]
# Debian's /bin/sh is dash, so leaving SHELL unset hands every browser terminal
# session a shell with no history, no completion and no arrays — and the
# agent's own skills assume bash. Setting it here rather than in the entrypoint
# keeps it true for the pi-web process, which is what reads it.
ENV HOME=/data/pi-agent/home \
    SHELL=/bin/bash \
    PI_CODING_AGENT_DIR=/data/pi-agent \
    PLAYWRIGHT_BROWSERS_PATH=/data/pi-agent/playwright-cache \
    RCLONE_CONFIG=/data/pi-agent/rclone/rclone.conf \
    BASH_ENV=/usr/local/bin/pi-agent-env.sh \
    PI_VIDEO_TOOLS_BUILT=${VIDEO_TOOLS}

# Podman runs this natively and reports it in `podman ps`. /api/home is the one
# route that answers 200 on a fresh install with no session context.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS http://127.0.0.1:30141/api/home || exit 1

VOLUME ["/data/pi-agent"]
EXPOSE 30141

LABEL org.opencontainers.image.title="Woow Podman Pi Agent" \
      org.opencontainers.image.description="pi-web + pi coding agent, for rootless Podman with Quadlet" \
      org.opencontainers.image.vendor="WOOWTECH" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/WOOWTECH/Woow_podman_pi_agent_package" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REF}"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/pi-web-start.sh"]
