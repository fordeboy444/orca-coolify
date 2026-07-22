#!/bin/bash
set -e

# Orca auto-starts Xvfb for `orca serve` when DISPLAY is unset (per the headless
# guide), so we do not start it manually. LIBGL_ALWAYS_SOFTWARE=1 is set in the
# Dockerfile for GPU-less containers.
#
# --no-sandbox: Chromium's setuid sandbox cannot run inside a Docker container
# as a non-root user (no SYS_ADMIN cap / seccomp allows it). Without this flag
# the Electron process exits immediately.
#
# --pairing-address 127.0.0.1: the client reaches the server through an SSH
#   local-forward tunnel (ssh -L 6768:127.0.0.1:6768 ...), so 127.0.0.1 is the
#   correct address to advertise.
# No --json: keep human-readable output so the pairing URL is visible in logs.
exec /opt/orca/squashfs-root/AppRun --no-sandbox serve --port 6768 --pairing-address 127.0.0.1