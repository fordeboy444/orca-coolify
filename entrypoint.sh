#!/bin/bash
# Headless "orca serve" entrypoint for Coolify.
# Mirrors Orca v1.4.150's headless Linux server path (Xvfb + LIBGL_ALWAYS_SOFTWARE),
# extracted-AppImage form (Docker has no FUSE).
set +e
export APPDIR=/opt/orca/squashfs-root

echo "entrypoint starting as: $(id)"
echo "APPDIR=$APPDIR  DISPLAY=${DISPLAY:-<unset>}  LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "pairing-address=${ORCA_PAIRING_ADDRESS:-127.0.0.1}  mobile-pairing=${ORCA_MOBILE_PAIRING:-0}"

# --- Claude Code settings: SEED ONCE, NEVER MERGE ---
# The orca-home volume holds the authoritative ~/.claude/settings.json. This PC keeps it
# in sync with tools/sync-settings-to-orca.py, so the file must stay exactly as synced.
#
# 2026-10-18..2026-11-11 BUG: the old code did a gap-fill merge ($tpl[0] * .). It added
# back every key that was ABSENT from the volume file on each boot. CLAUDE_CODE_SUBAGENT_MODEL
# returned that way after every nightly updater deploy, and any key deleted to mirror the
# local file came back too. Never merge an existing file again.
#
# Rules now:
#   1. Existing settings.json -> keep it. Only strip the keys below (idempotent; no write
#      when nothing changes).
#   2. No settings.json (fresh volume) -> seed it from the baked template.
#   3. CLAUDE_CODE_SUBAGENT_MODEL must never exist: when set, every subagent runs on that
#      one model and does not inherit the main session model. Do not remove this strip.
#   4. statusLine / _comment are stripped because the custom-statusline image (commit
#      45785a4) is gone, so a stale reference would blank the TUI footer.
#
# jq validates the result BEFORE the mv, so a bad edit cannot corrupt the file. `set +e`
# at the top means a failure here never stops Orca from starting. Runs as the orca user,
# so the file lands orca-owned (UID 1000) — see .claude/memory/volume-file-permissions.md.
CC_SETTINGS="$HOME/.claude/settings.json"
CC_TEMPLATE=/opt/orca-config/claude-model-config.json
mkdir -p "$HOME/.claude"
if [ -f "$CC_SETTINGS" ]; then
  tmp=$(mktemp)
  jq 'del(.statusLine, ._comment, .["env"]["CLAUDE_CODE_SUBAGENT_MODEL"])' "$CC_SETTINGS" > "$tmp"
  if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
    if cmp -s "$tmp" "$CC_SETTINGS"; then
      echo "cc-settings: existing file kept unchanged"
      rm -f "$tmp"
    else
      mv "$tmp" "$CC_SETTINGS"
      echo "cc-settings: existing file kept (forbidden keys stripped)"
    fi
  else
    echo "cc-settings: STRIP FAILED, $CC_SETTINGS left unchanged"
    rm -f "$tmp"
  fi
elif [ -f "$CC_TEMPLATE" ]; then
  tmp=$(mktemp)
  jq -n --slurpfile tpl "$CC_TEMPLATE" '$tpl[0] | del(.statusLine, ._comment, .["env"]["CLAUDE_CODE_SUBAGENT_MODEL"])' > "$tmp"
  if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$CC_SETTINGS"
    echo "cc-settings: fresh volume seeded from $CC_TEMPLATE"
  else
    echo "cc-settings: SEED FAILED, no settings.json created"
    rm -f "$tmp"
  fi
fi

# --- Single-instance lock: remove a lock left by a PREVIOUS container ---
# A redeploy creates a new container with a new machineIdentity. The old container's
# orcad.lock stays behind on the orca-home volume. On start, `orca serve` reads that
# lock, decides "another machine" holds the data root, and exits with code 3; Docker
# then restarts the container forever and every client gets 502.
# The lock is stale when its pid is not a live orca process IN THIS container. A live
# orca process still owns the data root, so keep the lock in that case.
ORCA_LOCK="$HOME/.config/orca/orcad.lock"
if [ -f "$ORCA_LOCK" ]; then
  lock_pid=$(jq -r '.pid // empty' "$ORCA_LOCK" 2>/dev/null)
  if [ -n "$lock_pid" ] && [ -r "/proc/$lock_pid/cmdline" ] \
     && tr '\0' ' ' < "/proc/$lock_pid/cmdline" 2>/dev/null | grep -q orca; then
    echo "orcad-lock: live orca process $lock_pid keeps the lock"
  else
    echo "orcad-lock: stale lock (pid=${lock_pid:-unknown}) — removed"
    rm -f "$ORCA_LOCK"
  fi
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