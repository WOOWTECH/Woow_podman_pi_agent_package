# Woow Podman Pi Agent — pi-web + the pi coding agent, built for rootless Podman.
#
# This is NOT the k3s image with Kubernetes bits removed. It is built for a
# different runtime and the differences are deliberate:
#
#   - No ttyd. On Kubernetes a browser terminal was the only practical way to
#     reach a shell inside the pod. Under Podman `podman exec -it pi-web bash`
#     is the native answer, so the sidecar and its password Secret both go away.
#   - No kubectl, no s6-overlay, no bashio. systemd supervises via Quadlet.
#   - A real HEALTHCHECK instruction. Podman honours it natively and surfaces
#     the result in `podman ps`; there is no need to emulate Kubernetes'
#     three-probe model.
#
# Rootless note: the container runs as root INSIDE its user namespace, which
# maps to the unprivileged host user (uid 1000). That is a meaningful security
# improvement over the k3s deployment, which ran as real root on the node.
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
# Default 1 keeps parity with the k3s deployment.
ARG VIDEO_TOOLS=1

# Base runtime. ca-certificates/curl/git/gnupg/jq/openssh-client are needed by
# the provider check, the models.json merge and the `skills` CLI, which shells
# out to git and ssh. tini reaps: the agent's bash tool forks freely and
# without an init every abandoned child would linger as a zombie.
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

# pi-web ships a pre-built .next/ in its npm tarball and imports the coding
# agent as a library, so there is no separate agent daemon.
#
# Pinned deliberately. pi-web's own Host/Origin trust guard and its /api/*
# surface are what the nginx config is written against. Bump only after
# re-running the acceptance suite.
ARG PI_WEB_VERSION=0.8.4
RUN npm install -g --omit=dev "@agegr/pi-web@${PI_WEB_VERSION}" \
    && rm -rf /tmp/npm-cache

# Stop silent CJK path corruption. Upstream folds U+3000 and other Unicode
# spaces to ASCII on every read/write/edit and builds the read fallback chain
# from the folded path, so writes land at the wrong name while reporting
# success, and two files differing only by space type cross-read. The patch
# asserts every hunk, so an upstream bump fails the build rather than shipping
# an image that quietly lost the fix.
COPY patches/ /opt/patches/
RUN set -euo pipefail; \
    mapfile -d '' FILES < <(find /usr/lib/node_modules/@agegr/pi-web \
      -path '*@earendil-works/*/dist/*/tools/path-utils.js' -print0); \
    echo "[patch] found ${#FILES[@]} path-utils.js copies"; \
    if [ "${#FILES[@]}" -lt 2 ]; then \
      echo "[patch] FAIL: expected at least 2 copies, found ${#FILES[@]}" >&2; \
      exit 1; \
    fi; \
    node /opt/patches/fix-unicode-space-paths.mjs "${FILES[@]}"

COPY rootfs/ /

RUN chmod +x /usr/local/bin/pi /usr/local/bin/pi-web-start.sh /usr/local/bin/video-tools-init.sh \
    # Fail the build rather than ship an image where `pi` resolves to nothing.
    # Upstream installs the coding agent only as a transitive dependency, so npm
    # never links its bin — without the launcher, every terminal workflow dies.
    && test -x "$(command -v pi)" \
    && pi --version

ARG BUILD_VERSION=dev
ARG BUILD_REF=unknown

ENV PI_AGENT_IMAGE_VERSION=${BUILD_VERSION} \
    PI_WEB_VERSION=${PI_WEB_VERSION} \
    PI_AGENT_DATA_DIR=/data/pi-agent \
    PI_WEB_PORT=30141

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
