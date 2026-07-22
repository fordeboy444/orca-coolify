#!/bin/bash
# Diagnostic entrypoint (set +e + sleep fallback) so a crashing container stays
# alive long enough for the Coolify logs API to surface output. Revert to a
# plain `exec` once orca serve is confirmed stable.
set +e
export APPDIR=/opt/orca/squashfs-root

echo "entrypoint starting as: $(id)"
echo "APPDIR=$APPDIR"
echo "DISPLAY=${DISPLAY:-<unset>} LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "AppRun perms: $(ls -la "$APPDIR/AppRun" 2>&1)"

# APPDIR must be set so AppRun (a shell script) resolves $APPDIR/orca-ide;
# without it, AppRun looks for /orca-ide and fails with 127.
# --no-sandbox: Chromium's sandbox can't run in Docker as non-root.
"$APPDIR/AppRun" --no-sandbox serve --port 6768 --pairing-address 127.0.0.1
rc=$?
echo ">>> orca serve exited with code $rc"
echo ">>> keeping container alive 10m for log inspection via Coolify API"
sleep 600
exit $rc