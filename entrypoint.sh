#!/bin/bash
set -euo pipefail

# Start a virtual framebuffer on :99. Orca also auto-starts Xvfb when DISPLAY
# is unset, but starting it explicitly avoids races in a container.
Xvfb :99 -screen 0 1280x800x24 >/tmp/xvfb.log 2>&1 &

# Run orca serve in the foreground so Coolify can manage the process and we can
# read the "Pairing URL: orca://..." line from the deployment logs.
#
# --pairing-address 127.0.0.1: the client reaches the server through an SSH
#   local-forward tunnel (ssh -L 6768:127.0.0.1:6768 ...), so 127.0.0.1 is the
#   correct address to advertise.
# No --json: keep human-readable output so the pairing URL is visible in logs.
exec /opt/orca/squashfs-root/AppRun serve --port 6768 --pairing-address 127.0.0.1