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
# --mobile-pairing: print a mobile-scoped `orca://pair?code=…` pairing link to stdout
# (captured in `docker logs`). The Orca phone app scans the QR (or accepts the pasted
# link) and connects through Orca's relay (directorUrl/cellUrl in the decoded offer),
# which brokers a connection back to this server. The server only needs outbound HTTPS
# to the relay, so it stays on loopback — no public domain and no Hetzner firewall
# change. The invite token expires ~10 min after start; restart the container to
# regenerate. Override the advertised address with ORCA_PAIRING_ADDRESS if needed.
#
# Pairing model: `--mobile-pairing` (phone, relay) and `--recipe-json` (browser Web UI,
# runtime-scoped paste) are mutually exclusive in one `serve` invocation. This build
# targets the phone. v1.4.150 also exposes the WebSocket endpoint + authToken in
# ~/.config/orca/orca-runtime.json and serves the Orca Web SPA on :6768.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  "$APPDIR/AppRun" --no-sandbox serve --port 6768 \
    --pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}" \
    --mobile-pairing
rc=$?
echo ">>> orca serve exited with code $rc"
# Brief fallback so a crash stays visible long enough for the Coolify logs API to
# surface the exit. Remove once long-term stability is confirmed.
sleep 60
exit $rc