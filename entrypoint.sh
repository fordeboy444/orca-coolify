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
# --recipe-json: print a runtime-scoped pairing URL to stdout as a single JSON object
#   { "schemaVersion": 1, "pairingCode": "orca://pair?code=…", "projectRoot": "…" }
# (captured in `docker logs`). The Orca Web client served at http://127.0.0.1:6768 has
# a "Connect to Orca" page — open it in a browser over the SSH local-forward tunnel and
# paste the pairingCode there to connect this browser as an Orca client to the server.
# Runtime pairing needs no Orca account. --pairing-address 127.0.0.1 makes the encoded
# WebSocket endpoint reachable through the tunnel:
#   ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host>
# Override the advertised address with ORCA_PAIRING_ADDRESS (e.g. a Tailscale IP or a
# public wss:// URL) and the workspace root with ORCA_PROJECT_ROOT if needed.
#
# Pairing model: `--recipe-json` (runtime scope, browser Web UI, no account) and
# `--mobile-pairing` (mobile scope, phone, requires Orca sign-in) are mutually exclusive
# in one `serve` invocation. This build targets the browser. Phone pairing is NOT
# enabled here: it needs `--mobile-pairing` plus an Orca account sign-in that a headless
# server cannot easily perform (the mobile QR is an in-app, signed-in flow). v1.4.150
# also exposes the WebSocket endpoint + authToken in ~/.config/orca/orca-runtime.json.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  "$APPDIR/AppRun" --no-sandbox serve --port 6768 \
    --pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}" \
    --project-root "${ORCA_PROJECT_ROOT:-/home/orca}" \
    --recipe-json
rc=$?
echo ">>> orca serve exited with code $rc"
# Brief fallback so a crash stays visible long enough for the Coolify logs API to
# surface the exit. Remove once long-term stability is confirmed.
sleep 60
exit $rc