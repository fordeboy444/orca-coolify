#!/bin/bash
# Headless "orca serve" entrypoint for Coolify.
# Mirrors Orca v1.4.150's headless Linux server path (Xvfb + LIBGL_ALWAYS_SOFTWARE),
# extracted-AppImage form (Docker has no FUSE).
set +e
export APPDIR=/opt/orca/squashfs-root

echo "entrypoint starting as: $(id)"
echo "APPDIR=$APPDIR  DISPLAY=${DISPLAY:-<unset>}  LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "pairing-address=${ORCA_PAIRING_ADDRESS:-127.0.0.1}"

# xvfb-run: starts Xvfb and sets $DISPLAY. Orca's auto-Xvfb (when DISPLAY is unset) did
# not start inside this container, so start one explicitly. APPDIR is set so AppRun
# resolves $APPDIR/orca-ide.
#
# --no-sandbox: Chromium's sandbox can't run in Docker as non-root.
# --pairing-address 127.0.0.1: advertise the loopback address the client reaches through
# the SSH local-forward tunnel:
#   ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host>
# The Orca Web client is served at http://127.0.0.1:6768 (open it in a browser over the
# tunnel) and connects back over the same loopback WebSocket transport — no pairing URL
# required. Override the advertised address with ORCA_PAIRING_ADDRESS if needed.
#
# Note: Orca v1.4.150 does NOT print an `orca://pair?code=…` URL (that ready/JSON
# contract is from a newer `main`-branch build). v1.4.150 exposes the WebSocket endpoint
# + authToken in ~/.config/orca/orca-runtime.json and serves the Orca Web UI on :6768.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  "$APPDIR/AppRun" --no-sandbox serve --port 6768 --pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}"
rc=$?
echo ">>> orca serve exited with code $rc"
# Brief fallback so a crash stays visible long enough for the Coolify logs API to
# surface the exit. Remove once long-term stability is confirmed.
sleep 60
exit $rc