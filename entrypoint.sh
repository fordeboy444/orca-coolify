#!/bin/bash
# Headless "orca serve" entrypoint for Coolify.
# Mirrors Orca v1.4.150's headless Linux server path (Xvfb + LIBGL_ALWAYS_SOFTWARE),
# extracted-AppImage form (Docker has no FUSE).
set +e
export APPDIR=/opt/orca/squashfs-root

echo "entrypoint starting as: $(id)"
echo "APPDIR=$APPDIR  DISPLAY=${DISPLAY:-<unset>}  LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "pairing-address=${ORCA_PAIRING_ADDRESS:-127.0.0.1}  mobile-pairing=${ORCA_MOBILE_PAIRING:-0}"

# --- Claude Code model config: seed the repo template into ~/.claude/settings.json ---
# The orca app used to get its model configuration only from Coolify env vars, which meant
# every model change needed a Coolify edit plus a redeploy. The template baked in at
# /opt/orca-config/claude-model-config.json carries "model" + "modelPicker" instead, so the
# file on the orca-home volume is authoritative and the /model picker is curated there.
#
# MERGE DIRECTION IS THE SAFETY PROPERTY: `$tpl[0] * .` gives the ON-DISK file precedence
# (in jq, the right operand of `*` wins), so this only fills keys that are ABSENT and never
# overwrites a manual edit on the volume. Re-running it is a no-op once the keys exist.
#
# It also strips any stale custom `statusLine` key left in settings.json by the reverted
# custom-statusline image (commit 45785a4). That image baked /opt/cc-statusline.sh and wired
# settings.json .statusLine to it; this image no longer ships the script, so the stale
# reference would make the TUI footer go blank. del() is idempotent.
#
# jq validates the merged result BEFORE the mv, so a bad merge cannot corrupt the file.
# `set +e` at the top means a failure here never stops Orca from starting. Runs as the orca
# user, so the file lands orca-owned (UID 1000) — see .claude/memory/volume-file-permissions.md.
CC_SETTINGS="$HOME/.claude/settings.json"
CC_TEMPLATE=/opt/orca-config/claude-model-config.json
mkdir -p "$HOME/.claude"
if [ -f "$CC_TEMPLATE" ]; then
  tmp=$(mktemp)
  if [ -f "$CC_SETTINGS" ]; then
    jq --slurpfile tpl "$CC_TEMPLATE" '$tpl[0] * . | del(.statusLine, ._comment)' "$CC_SETTINGS" > "$tmp"
  else
    jq -n --slurpfile tpl "$CC_TEMPLATE" '$tpl[0] | del(.statusLine, ._comment)' > "$tmp"
  fi
  if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$CC_SETTINGS"
    echo "cc-model-config: merged $CC_TEMPLATE into $CC_SETTINGS"
  else
    echo "cc-model-config: MERGE FAILED, $CC_SETTINGS left unchanged"
    rm -f "$tmp"
  fi
elif [ -f "$CC_SETTINGS" ]; then
  tmp=$(mktemp) && jq 'del(.statusLine)' "$CC_SETTINGS" > "$tmp" && mv "$tmp" "$CC_SETTINGS"
fi

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
# Pairing model: runtime scope (browser Web UI, default, no account) vs. mobile scope
# (native clients — Orca Mobile app + Orca desktop app, --serve-mobile-pairing). The two
# are mutually exclusive in one serve invocation. Verified 2026-07-23: mobile scope mints a
# local mobile pairing QR with NO Orca account sign-in on the server side — the earlier
# "requires account" note was wrong (it came from tests that never activated serve mode).
# Set ORCA_MOBILE_PAIRING=1 to switch this instance to mobile scope for native clients.
# Set ORCA_PAIRING_ADDRESS to an address the clients can reach (Tailscale IP/hostname,
# LAN IP, or a public wss:// URL) — it is baked into the pairing QR as the ws endpoint.
# Default 127.0.0.1 only works for an SSH-forwarded browser on the same machine.
xvfb-run -a --server-args="-screen 0 1280x800x16 -ac +extension MIT-SHM" \
  "$APPDIR/AppRun" --no-sandbox --serve --serve-port 6768 \
    --serve-pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}" \
    --disable-dev-shm-usage \
    --disable-gpu-vsync \
    ${ORCA_MOBILE_PAIRING:+--serve-mobile-pairing}
rc=$?
echo ">>> orca serve exited with code $rc"
# Brief fallback so a crash stays visible long enough for the Coolify logs API to
# surface the exit. Remove once long-term stability is confirmed.
sleep 60
exit $rc