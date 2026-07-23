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
#
# Plain `orca serve` (no --recipe-json / --mobile-pairing) prints, to stdout:
#   - the runtime endpoint (ws://…), and
#   - a runtime-scoped pairing URL  orca://pair?code=<base64url(offer)>
# and, when the web client bundle is present, a browser URL with the pairing data
# embedded. We capture that stdout in `docker logs` and hand the pairing URL to the
# user to paste into the "Connect to Orca" page at http://127.0.0.1:6768 over the SSH
# local-forward tunnel:
#   ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host>
# Runtime pairing needs no Orca account. --pairing-address 127.0.0.1 makes the encoded
# WebSocket endpoint reachable through the tunnel.
#
# Why NOT --recipe-json: that flag switches stdout to a JSON object
#   { "schemaVersion": 1, "pairingCode": "…", "projectRoot": "…" }
# which is documented for the dev CLI (pnpm exec orca-dev serve) but does NOT emit in
# the packaged AppImage build — nothing reaches stdout or any file. Worse, passing it
# suppresses the normal text pairing-URL printout, leaving no usable pairing URL at
# all. Plain serve is the path that actually prints a pairing URL carrying the token
# the server validates (hand-building a URL from runtime.json authToken does NOT work
# — the server rejects it as "Unauthorized" because authToken is the runtime session
# token, not a pairing invite token).
#
# Pairing model: runtime scope (browser Web UI, no account, this build) vs. mobile
# scope (phone, --mobile-pairing, requires Orca account sign-in a headless server
# can't do). The two are mutually exclusive in one serve invocation.
# Override the advertised address with ORCA_PAIRING_ADDRESS (e.g. a Tailscale IP or a
# public wss:// URL) if needed.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  "$APPDIR/AppRun" --no-sandbox serve --port 6768 \
    --pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}"
rc=$?
echo ">>> orca serve exited with code $rc"
# Brief fallback so a crash stays visible long enough for the Coolify logs API to
# surface the exit. Remove once long-term stability is confirmed.
sleep 60
exit $rc