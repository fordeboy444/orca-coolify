#!/bin/bash
# Headless "orca serve" entrypoint for Coolify.
#
# Diagnostic mode (set +e + sleep fallback) so a crashing container stays alive
# long enough for the Coolify logs API to surface output. Revert to a plain
# `exec` once orca serve is confirmed stable end-to-end.
set +e
export APPDIR=/opt/orca/squashfs-root

echo "entrypoint starting as: $(id)"
echo "APPDIR=$APPDIR  DISPLAY=${DISPLAY:-<unset>}  LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "which xvfb-run: $(command -v xvfb-run || true)  which script: $(command -v script || true)"

# xvfb-run: starts Xvfb and sets $DISPLAY. The headless guide says Orca auto-starts
# Xvfb when DISPLAY is unset, but that did not happen in this container (Electron died
# with "Missing X server or $DISPLAY"), so start one explicitly. APPDIR is set so
# AppRun resolves $APPDIR/orca-ide.
#
# script -qfc: allocates a pseudo-TTY for the child. Electron/Node stdout to a pipe is
# block-buffered, so the ~150-byte "Orca server ready / Pairing URL: orca://… " block
# otherwise sits unflushed in a 4KB pipe buffer and never reaches the Coolify logs.
# With a PTY, stdout is line-buffered and the ready block (incl. the pairing URL) is
# flushed line-by-line. -q = no "Script started" header, -f = flush each write,
# /dev/null = discard the typescript file. NB: PTY output may contain \r — strip when
# parsing.
#
# --no-sandbox: Chromium's sandbox can't run in Docker as non-root.
# --pairing-address 127.0.0.1: advertise the loopback address the desktop/mobile client
# reaches through the SSH local-forward tunnel:
#   ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host>
# --json: emit the versioned single-line `orca_server_ready` JSON event (schemaVersion 1)
# instead of the human-readable ready block. v1.4.150 did not print the human "Pairing
# URL:" block to stdout even via a PTY; --json is the supervisor code path that always
# emits a ready event with a `pairing` object (url / webClientUrl / qr when available,
# or available:false + reason). The PTY flushes that single line to the Coolify logs.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  script -qfc "$APPDIR/AppRun --no-sandbox serve --port 6768 --pairing-address 127.0.0.1 --json" /dev/null
rc=$?
echo ">>> orca serve exited with code $rc"
echo ">>> keeping container alive 10m for log inspection via Coolify API"
sleep 600
exit $rc