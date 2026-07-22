#!/bin/bash
# Diagnostic entrypoint (set +e + sleep fallback) so a crashing container stays
# alive long enough for the Coolify logs API to surface output. Revert to a
# plain `exec` once orca serve is confirmed stable.
set +e
export APPDIR=/opt/orca/squashfs-root

echo "entrypoint starting as: $(id)"
echo "APPDIR=$APPDIR"
echo "DISPLAY=${DISPLAY:-<unset>} LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "which xvfb-run: $(command -v xvfb-run || true)"

# Wrap in xvfb-run: it starts Xvfb and sets $DISPLAY. The headless guide says
# Orca auto-starts Xvfb when DISPLAY is unset, but that did not happen in this
# container (Electron died with "Missing X server or $DISPLAY"), so start one
# explicitly. APPDIR is set so AppRun resolves $APPDIR/orca-ide.
# --no-sandbox: Chromium's sandbox can't run in Docker as non-root.
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  "$APPDIR/AppRun" --no-sandbox serve --port 6768 --pairing-address 127.0.0.1
rc=$?
echo ">>> orca serve exited with code $rc"
echo ">>> keeping container alive 10m for log inspection via Coolify API"
sleep 600
exit $rc