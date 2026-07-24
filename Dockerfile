# syntax=docker/dockerfile:1
#
# Headless "orca serve" image for Coolify.
# Mirrors the documented headless Linux server path:
#   https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
#
# Orca ships as a prebuilt AppImage (no Dockerfile upstream). Docker has no FUSE
# device, so we extract the AppImage once at build time and run squashfs-root/AppRun.
#
# Reachability: this server is meant to be reached over PRIVATE networking only.
# The default entrypoint advertises --pairing-address 127.0.0.1, expecting the
# client to reach it through an SSH local-forward tunnel:
#   ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host>
# Do NOT expose port 6768 to the public internet.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LIBGL_ALWAYS_SOFTWARE=1
# DISPLAY intentionally unset: Orca auto-starts Xvfb for `orca serve` when no
# DISPLAY is set (per the headless guide).

# Headless-guide runtime deps + git + build/prereq tools, PLUS the shared
# libraries Electron/Chromium needs. The headless guide targets a full Ubuntu
# install; the minimal ubuntu:22.04 base image lacks these, so without them
# orca serve exits immediately on startup.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl file jq xvfb zlib1g-dev libfuse2 ca-certificates git gnupg xz-utils \
        libnss3 libxss1 libasound2 libatk-bridge2.0-0 libatk1.0-0 \
        libcairo2 libcups2 libdbus-1-3 libdrm2 libgbm1 libgdk-pixbuf2.0-0 \
        libgtk-3-0 libnspr4 libpango-1.0-0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libxkbcommon0 libxshmfence1 libx11-6 libxcb1 \
        libxext6 libxres1 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Node 22 LTS — the @anthropic-ai/claude-code npm package has required Node 22+
# since v2.1.198. Needed to install the coding-agent CLIs (Claude Code, Codex).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Non-root runtime user, created before the CLI install so the CLIs can be
# installed into a directory `orca` owns. State lives in /home/orca/.config —
# mount a persistent volume there in Coolify so pairing + agent auth survive
# redeployments.
RUN useradd -m -s /bin/bash orca \
    && mkdir -p /opt/node-global \
    && chown -R orca:orca /opt/node-global

# Install the coding-agent CLIs into a USER-OWNED npm prefix so the `orca` user
# (which has no sudo) can auto-update and run `npm install -g ...@latest` itself.
# The previous `npm install -g` ran as root into the default global prefix, leaving
# it root-owned — so Claude Code's auto-updater failed at startup with a permission
# error ("npm global directory isn't writable"). NPM_CONFIG_PREFIX + PATH are set
# as image ENV so Orca and the `claude`/`codex` processes it spawns all resolve to
# this prefix. Auth for both CLIs is via API-key env vars (ANTHROPIC_API_KEY /
# OPENAI_API_KEY). NOTE: updates land in /opt/node-global (container writable
# layer) and reset to this build-pinned version on redeploy, then auto-update
# forward; settings/auth on the /home/orca volume are unaffected.
ENV NPM_CONFIG_PREFIX=/opt/node-global
ENV PATH=/opt/node-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER orca
RUN npm install -g @anthropic-ai/claude-code @openai/codex

# AppImage download/extract needs root (/opt/orca, curl, chmod). Switch back to
# root for this block, then drop to `orca` for runtime at the end.
USER root

# Orca AppImage — download the latest release and extract once (no FUSE at runtime).
# To pin a release for reproducibility, set ORCA_VERSION at build time, e.g.:
#   --build-arg ORCA_VERSION=v0.x.y
# and the URL below resolves to that release's AppImage.
ARG ORCA_VERSION=latest
RUN mkdir -p /opt/orca \
    && if [ "$ORCA_VERSION" = "latest" ]; then \
         URL="https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage"; \
       else \
         URL="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/orca-linux.AppImage"; \
       fi \
    && curl -L "$URL" -o /opt/orca/orca-linux.AppImage \
    && chmod +x /opt/orca/orca-linux.AppImage \
    && cd /opt/orca && ./orca-linux.AppImage --appimage-extract \
    && rm /opt/orca/orca-linux.AppImage \
    && chmod -R a+rX /opt/orca/squashfs-root \
    && chmod a+rx /opt/orca/squashfs-root/AppRun

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/orca
EXPOSE 6768
USER orca

ENTRYPOINT ["/entrypoint.sh"]