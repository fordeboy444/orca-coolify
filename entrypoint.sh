#!/bin/bash
# Diagnostic entrypoint: prints environment + AppRun perms, runs orca serve, and
# on exit prints the code and sleeps so the Coolify logs API can surface output
# for a crashing container. Revert to a plain `exec` once orca serve is stable.
set +e
echo "entrypoint starting as: $(id)"
echo "DISPLAY=${DISPLAY:-<unset>} LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
echo "AppRun perms: $(ls -la /opt/orca/squashfs-root/AppRun 2>&1)"
echo "which xvfb-run: $(command -v xvfb-run || true) ; Xvfb: $(command -v Xvfb || true)"

/opt/orca/squashfs-root/AppRun --no-sandbox serve --port 6768 --pairing-address 127.0.0.1
rc=$?
echo ">>> orca serve exited with code $rc"
echo ">>> keeping container alive 10m for log inspection via Coolify API"
sleep 600
exit $rc