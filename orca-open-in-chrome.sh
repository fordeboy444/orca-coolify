#!/bin/sh
# Orca "System Browser" -> hosted Chrome (CDP).
#
# The orca image ships no xdg-open and no gio, so Electron's
# shell.openExternal has no target. This shim opens the link as a new tab
# in the Chrome service at 100.65.54.114:9333.
#
# One-way only: Orca opens the page. Orca does not control the tab.
# CDP has no authentication. Keep port 9333 on the Tailscale IP only.
url="$1"
[ -z "$url" ] && exit 1

# In the Chrome container, localhost is Chrome itself.
# Rewrite loopback URLs to the host Tailscale IP.
url=$(printf '%s' "$url" | sed -E 's#^http(s?)://(localhost|127\.0\.0\.1)(:[0-9]+)?#http\1://100.65.54.114\3#')

case "$url" in
  http://*|https://*) ;;
  *) exit 0 ;;
esac

enc=$(printf '%s' "$url" | jq -sRr @uri 2>/dev/null) || exit 1
printf '%s %s\n' "$(date -Is 2>/dev/null)" "$url" >> /tmp/orca-chrome-open.log 2>/dev/null
# Chrome 155: the URL is the query itself. "?url=<u>" opens about:blank.
curl -fsS --max-time 5 -X PUT "http://100.65.54.114:9333/json/new?$enc" >/dev/null 2>&1
exit 0
