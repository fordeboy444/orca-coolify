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
# Flag-format note (the root cause of the earlier "no pairing URL" failure):
# AppRun runs the Electron binary directly; it does NOT route through the `orca` CLI
# wrapper that would translate the `serve` subcommand into Electron flags. So we must
# pass the Electron-main-format flags directly, NOT the CLI subcommand form. The
# Electron main (app.asar out/main/index.js) gates serve mode on a literal argv token:
#   const isServeMode = process.argv.includes("--serve");
# and getServeOptions() reads --serve-port / --serve-pairing-address / --serve-recipe-json /
# --serve-mobile-pairing / --serve-project-root / --serve-no-pairing / --serve-json.
# Passing `serve --port 6768 --pairing-address 127.0.0.1` (the CLI form) left isServeMode
# false, so the app opened its GUI window on Xvfb instead — it still started the runtime
# + WebSocket server (hence HTTP 200 and the daemon log) but never called printServeReady,
# so no "Orca server ready" line and no pairing URL was ever printed. The --mobile-pairing
# and --recipe-json experiments earlier in this deploy all failed for the same reason:
# serve mode was never active, so every serve flag was silently ignored.
#
# With --serve active, printServeReady() runs and prints to stdout:
#   Orca server ready: ws://127.0.0.1:6768
#   Web client URL: http://127.0.0.1:6768/?…   (when the web bundle is present)
#   Pairing URL: orca://pair?code=<base64url(offer)>
# captured in `docker logs`. The Pairing URL carries the REAL deviceToken — a fresh
# pending-device token minted by the device registry (DeviceRegistry.getOrCreatePendingDevice),
# NOT the runtime authToken. (Hand-building a URL from runtime.json authToken fails with
# "Unauthorized": authToken is the runtime session token, not a pairing invite token.)
# Paste the Pairing URL into the "Connect to Orca" page at http://127.0.0.1:6768 reached
# over the SSH local-forward tunnel:
#   ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host>
# Runtime pairing needs no Orca account. --serve-pairing-address 127.0.0.1 makes the
# encoded WebSocket endpoint reachable through the tunnel.
#
# Pairing model: runtime scope (browser Web UI, no account — this build) vs. mobile
# scope (phone, --serve-mobile-pairing, requires Orca account sign-in a headless server
# can't do). The two are mutually exclusive in one serve invocation.
# Override the advertised address with ORCA_PAIRING_ADDRESS (e.g. a Tailscale IP or a
# public wss:// URL) if needed.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  "$APPDIR/AppRun" --no-sandbox --serve --serve-port 6768 \
    --serve-pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}"
rc=$?
echo ">>> orca serve exited with code $rc"
# Brief fallback so a crash stays visible long enough for the Coolify logs API to
# surface the exit. Remove once long-term stability is confirmed.
sleep 60
exit $rc