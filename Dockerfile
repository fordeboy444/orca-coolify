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
ENV DISPLAY=:99

# Headless-guide runtime deps + git + build/prereq tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl file jq xvfb zlib1g-dev libfuse2 ca-certificates git gnupg xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Node 20 LTS — needed to install the coding-agent CLIs (Claude Code, Codex).
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Coding-agent CLIs that Orca will launch inside the container.
# Auth via API keys passed as env vars (ANTHROPIC_API_KEY / OPENAI_API_KEY).
RUN npm install -g @anthropic-ai/claude-code @openai/codex

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
    && rm /opt/orca/orca-linux.AppImage

# Non-root runtime user. State lives in /home/orca/.config — mount a persistent
# volume there in Coolify so pairing + agent auth survive redeployments.
RUN useradd -m -s /bin/bash orca

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/orca
EXPOSE 6768
USER orca

ENTRYPOINT ["/entrypoint.sh"]