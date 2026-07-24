# orca-coolify

A headless [`orca serve`](https://github.com/stablyai/orca) Docker image for deployment on
[Coolify](https://coolify.io). Orca ships as a prebuilt Linux **AppImage** with no upstream
Dockerfile; this image downloads it, extracts it (Docker has no FUSE), and runs it headless
with Xvfb + `LIBGL_ALWAYS_SOFTWARE=1`, mirroring Orca's
[headless Linux server guide](https://github.com/stablyai/orca/blob/v1.4.150/docs/reference/headless-linux-server.md).
It pre-installs the **Claude Code** and **Codex** CLIs so Orca can spawn coding agents inside
the container.

> **Pinned release:** Orca **v1.4.150**. See [Pinning & upgrading](#pinning--upgrading-the-orca-version)
> for why the version matters and how to change it.

---

## Overview

[Orca](https://github.com/stablyai/orca) is an Electron desktop app whose server mode is
`orca serve`: a WebSocket + HTTP server on **port 6768** that hosts repos, git worktrees,
terminals, and the coding-agent processes. Clients connect to it and drive agents remotely.

Orca is **not a normal web app** — Nixpacks can't build it, and building from
`pnpm`/`electron-vite` source would be very heavy. The documented headless path is: take the
prebuilt AppImage, run it with Xvfb + `LIBGL_ALWAYS_SOFTWARE=1`, and extract it first
(`--appimage-extract`) because Docker has no FUSE device at runtime. This image does exactly
that in a Dockerfile, and adds the Node.js + CLI tooling Orca launches as agents.

**Why a custom repo:** `stablyai/orca` has no Dockerfile and we can't add one, so this repo
holds the Dockerfile + entrypoint that Coolify builds from.

## What it does

`entrypoint.sh` starts Xvfb, then runs:

```
xvfb-run -a --server-args="-screen 0 1280x800x24 -ac" \
  /opt/orca/squashfs-root/AppRun --no-sandbox --serve --serve-port 6768 \
    --serve-pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}" \
    ${ORCA_MOBILE_PAIRING:+--serve-mobile-pairing}
```

The two env-driven parts:
- `ORCA_PAIRING_ADDRESS` is the address baked into the pairing blob as the WebSocket
  endpoint. Default `127.0.0.1` (for an SSH local-forward tunnel). Set it to
  `wss://<node>.<tailnet>.ts.net` for the **Tailscale Serve** model used in production, to
  the host's Tailscale IP for the plain tailnet fallback, or to a public `wss://host` URL
  for a no-auth public domain (see [Reachability](#reachability)).
- `ORCA_MOBILE_PAIRING` switches the instance to **mobile** scope. `${VAR:+…}` means any
  non-empty value (including `"0"`) enables it — to get **runtime** scope you must leave it
  unset/empty (delete the env var), not set it to `0`. Runtime scope is the default and what
  production uses.

> ⚠️ The flags are **Electron-format** (`--serve --serve-port … --serve-pairing-address …`),
> not the `orca` CLI subcommand form (`serve --port … --pairing-address …`). See
> [Headless build gotchas](#headless-build-gotchas) for why this matters — getting it wrong
> was the root cause of this deployment emitting no pairing URL for several iterations.

The server:

- Enters **serve mode** (`--serve`), starts the runtime, and prints readiness + a pairing
  URL to stdout (captured in `docker logs`):
  ```
  Orca server ready: ws://0.0.0.0:6768
  Web client URL: http://127.0.0.1:6768/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3D…
  Pairing URL: orca://pair?code=…
  ```
- Listens on `0.0.0.0:6768` (WebSocket + HTTP).
- Serves the **Orca Web** client at `http://<host>:6768` — the full Orca UI (terminals,
  agents, worktrees, settings) running in a browser. Its landing page is a
  "Connect to Orca — paste a pairing URL" page; you pair it with the `Web client URL` or
  `Pairing URL` above (see [Reachability](#reachability)).
- Writes runtime state to `~/.config/orca/orca-runtime.json`, which records the WebSocket
  endpoint (`ws://0.0.0.0:6768`), a `runtimeId`, and an `authToken`.
- Writes app logs to `~/.config/orca/logs/daemon.log` and `~/.config/orca/logs/main.trace.ndjson`.

## How the image is built

The [Dockerfile](Dockerfile) is layered as follows:

1. **Base:** `ubuntu:22.04` (a supported Orca OS). `DEBIAN_FRONTEND=noninteractive`,
   `ENV LIBGL_ALWAYS_SOFTWARE=1`. `DISPLAY` is intentionally left unset (Xvfb is started
   explicitly in the entrypoint — see [gotchas](#headless-build-gotchas)).

2. **Headless-guide deps + Electron/Chromium shared libs.** The headless guide targets a
   full Ubuntu install; the minimal `ubuntu:22.04` base lacks the libraries Electron needs,
   so without them `orca serve` exits immediately. Installed:
   `curl file jq xvfb zlib1g-dev libfuse2 ca-certificates git gnupg xz-utils` plus the
   Electron/Chromium libs `libnss3 libxss1 libasound2 libatk-bridge2.0-0 libatk1.0-0
   libcairo2 libcups2 libdbus-1-3 libdrm2 libgbm1 libgdk-pixbuf2.0-0 libgtk-3-0 libnspr4
   libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxkbcommon0
   libxshmfence1 libx11-6 libxcb1 libxext6 libxres1 fonts-liberation`.

3. **Node 22 LTS** (NodeSource). Node 22+ is required by the `@anthropic-ai/claude-code`
   npm package as of v2.1.198 (Node 20 only warns `EBADENGINE` today, but will fail in a
   future release). Needed to install the coding-agent CLIs.

4. **Non-root runtime user + user-owned npm prefix:** `useradd -m -s /bin/bash orca` and
   `mkdir -p /opt/node-global` (`chown orca:orca`), created **before** the CLI install.
   `ENV NPM_CONFIG_PREFIX=/opt/node-global` and `ENV PATH=/opt/node-global/bin:…` are set
   as image env so Orca and the `claude`/`codex` processes it spawns all resolve here.

5. **Agent CLIs (installed as `orca`, not root):** `npm install -g @anthropic-ai/claude-code
   @openai/codex` runs under `USER orca` with `NPM_CONFIG_PREFIX=/opt/node-global`, so the
   packages land in `/opt/node-global/lib/node_modules` with bins in `/opt/node-global/bin`,
   **owned by `orca`**. Authenticated at runtime via API-key env vars (see
   [Environment variables](#environment-variables)).
   - **Why user-owned:** the container runs as the unprivileged `orca` user (no sudo). A
     root-owned global npm install left the global dir unwritable by `orca`, so Claude Code
     printed a "npm global directory isn't writable" permission notice at startup
     (`claude doctor`: "Last update attempt: failed (no_permissions)") and
     `npm install -g …@latest` failed from the Orca terminal. The user-owned prefix fixes
     this: `npm install -g …@latest` (and `claude update`) now run cleanly as `orca`.
   - **Auto-updates are OFF in this image** (`claude doctor`: "Auto-updates: disabled (set
     by env: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`)") — that env var is set to keep
     Claude Code quiet against the non-Anthropic (Ollama Cloud) backend. So Claude Code
     never updates itself here; update it manually (see [Updating the agent CLIs](#updating-the-agent-clis)).
   - **Redeploy behavior:** CLI updates write to `/opt/node-global` (the container's
     writable layer, NOT the `/home/orca` volume), so a redeploy resets the CLIs to this
     build-pinned version. Because auto-updates are off, they stay at that version until
     you update manually. Settings/auth live on the `/home/orca` volume and are unaffected.

6. **Orca AppImage (back to root):** `USER root`, then the AppImage is downloaded from the
   GitHub release (latest by default, or a pinned `ORCA_VERSION`), `--appimage-extract` once
   at build time (no FUSE at runtime) into `/opt/orca/squashfs-root`, then `chmod -R a+rX` +
   `chmod a+rx AppRun` so the non-root user can execute it.

7. **Drop to `orca` for runtime:** `WORKDIR /home/orca`, `EXPOSE 6768`, `USER orca`,
   `ENTRYPOINT ["/entrypoint.sh"]`.

## Updating the agent CLIs

There is **no Orca UI button** to update Claude Code or Codex — Orca just spawns the CLIs,
and in this image their auto-updaters are disabled (see step 5 above). To update either,
open a terminal in the Orca Web UI and run, as the `orca` user:

```bash
claude --version                                    # current version
npm install -g @anthropic-ai/claude-code@latest     # update Claude Code
npm install -g @openai/codex@latest                 # update Codex (if used)
claude --version                                    # confirm the new version
```

These succeed without sudo because the CLIs live in the user-owned `/opt/node-global`
prefix (`NPM_CONFIG_PREFIX`). `claude doctor` prints "No installation issues found" on a
healthy install; a "Last update attempt: failed (no_permissions)" line is stale history
from the pre-fix root-owned install and clears after a successful update.

> ⚠️ **Re-run after every redeploy.** `/opt/node-global` is on the container's writable
> layer (not the persisted `/home/orca` volume), so a Coolify redeploy resets the CLIs to
> the version baked into the image, and with auto-updates off nothing brings them forward.
> Re-run the `npm install -g …@latest` commands above after each redeploy to get current.
> Claude Code settings/auth live on the volume and are unaffected.

Verified 2026-07-24 after the user-owned-prefix rebuild: `which claude` →
`/opt/node-global/bin/claude`, `ls -ld /opt/node-global` owned by `orca:orca`,
`claude --version` → `2.1.218`, `claude doctor` → "No installation issues found", and
`npm install -g @anthropic-ai/claude-code@latest` completed with no permission error.

## Headless build gotchas

These are the non-obvious things that had to be solved to make Orca run in a container
(each was a real crash-loop or silent failure until fixed):

- **Pass Electron `--serve` flags, not the CLI `serve` subcommand.** `AppRun` execs the
  Electron binary **directly** — it does *not* route through the `orca` CLI wrapper that
  would translate the `serve` subcommand into Electron flags. The Electron main
  (`app.asar` → `out/main/index.js`) gates serve mode on a literal argv token:
  `const isServeMode = process.argv.includes("--serve");`, and `getServeOptions()` reads
  `--serve-port`, `--serve-pairing-address`, `--serve-recipe-json`, `--serve-mobile-pairing`,
  `--serve-project-root`, `--serve-no-pairing`, `--serve-json`. If you pass the CLI form
  `serve --port 6768 --pairing-address 127.0.0.1`, `isServeMode` is false and the app
  **silently opens its GUI window on Xvfb** instead. Headed mode still starts the runtime +
  WebSocket server (so `:6768` returns HTTP 200 and the daemon log looks healthy) but
  **never calls `printServeReady`**, so no `Orca server ready` / `Pairing URL` is printed and
  every serve flag is ignored. This was the root cause of this deployment emitting no
  pairing URL across several iterations (`--mobile-pairing`, `--recipe-json`, plain
  `serve` all no-op'd for the same reason). Fix: pass
  `--serve --serve-port 6768 --serve-pairing-address 127.0.0.1` directly.
- **No FUSE → extract the AppImage.** Docker containers have no FUSE device, so the
  AppImage can't be mounted at runtime. Extract it once at build time with
  `--appimage-extract` and run `squashfs-root/AppRun`.
- **`APPDIR` must be exported.** `AppRun` is a shell script that execs `$APPDIR/orca-ide`.
  Without `export APPDIR=/opt/orca/squashfs-root`, it exits **127** (`/orca-ide: No such file
  or directory`). The entrypoint exports it.
- **The Electron lib list is mandatory.** On the minimal base, `orca serve` exits **126**
  (missing shared libs). The full lib list in step 2 above resolves it.
- **`--no-sandbox` is required.** Chromium's setuid sandbox can't run in Docker as a
  non-root user; without `--no-sandbox` the Electron process fails to start.
- **Explicit `xvfb-run`.** The headless guide says Orca auto-starts Xvfb when `DISPLAY` is
  unset, but that did **not** happen in this container — Electron died with a **segfault
  (139)**, "Missing X server or $DISPLAY". The entrypoint wraps the launch in
  `xvfb-run -a`, which starts Xvfb and sets `DISPLAY` itself.
- **`LIBGL_ALWAYS_SOFTWARE=1`.** Forces software OpenGL rendering (no GPU in the container).
- **LF line endings.** `entrypoint.sh` is bash; CRLF line endings break it on Linux.
  [.gitattributes](.gitattributes) forces `eol=lf` for `.sh` and the `Dockerfile`.

## Pairing model (v1.4.150)

> This is the single most important thing to know about this deployment.

When serve mode is active (`--serve` in argv — see the gotcha above), Orca v1.4.150 prints
this startup banner to stdout (captured in `docker logs`):

```
Orca server ready: ws://0.0.0.0:6768
Web client URL: http://127.0.0.1:6768/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3D…
Pairing URL: orca://pair?code=…
```

The `--serve-json` flag (Electron form; CLI form `--json`) instead emits an
`orca_server_ready` JSON event with a `pairing` object (`url`, `webClientUrl`, `qr`, …) for
supervisors. This image uses the plain text path because it's the simplest way to capture
the pairing URL in `docker logs`.

Key facts about the pairing URL:

- The `Pairing URL`'s `deviceToken` is a fresh **pending-device token from Orca's device
  registry** (`DeviceRegistry.getOrCreatePendingDevice`), minted only when the WebSocket
  transport is enabled. It is **not** the `authToken` in `~/.config/orca/orca-runtime.json`.
  Do **not** hand-build a pairing URL from `orca-runtime.json` — the server rejects such
  URLs as **"Unauthorized. Pair this web client again."** because `authToken` is the runtime
  session token, not a pairing invite token. Always use the server-emitted `Pairing URL`.
- The `Web client URL` is just `http://<host>:6768/web-index.html#pairing=<url-encoded
  Pairing URL>` — opening it in a browser auto-pairs the web client (no pasting needed).
- **Runtime vs. mobile scope** are mutually exclusive in one invocation:
  - **Runtime scope** (default, `ORCA_MOBILE_PAIRING` unset) — the browser Web UI, full
    permissions including `repo.add` (adding projects), **no Orca account** needed. This is
    what production uses.
  - **Mobile scope** (`--serve-mobile-pairing` / `ORCA_MOBILE_PAIRING` set) — for Orca's
    *native* desktop/mobile apps. It does **not** require an Orca account on the server side
    (an earlier version of this README was wrong about that — the "requires account" claim
    came from tests that never activated serve mode). However, mobile-scope clients are
    **sandboxed**: `repo.add` (adding projects) is rejected with
    `method repo.add is not available to mobile clients`. So if you need to add projects,
    use **runtime scope** (the browser Web UI), not the native app. Switch by
    setting/deleting `ORCA_MOBILE_PAIRING` and redeploying.
- The pairing token **rotates on every container start** until `~/.config/orca` is
  persisted (see [Persistent storage](#persistent-storage)). Until then, a saved browser
  connection breaks on each redeploy and you must re-pair with the new URL from `docker logs`.

`~/.config/orca/orca-runtime.json` still records the runtime endpoint + a session
`authToken` (a separate secret — see [Security notes](#security-notes)):

```json
{
  "runtimeId": "<uuid>",
  "transports": [
    {"kind":"unix","endpoint":"/home/orca/.config/orca/o-25-<runtimeId>.sock"},
    {"kind":"websocket","endpoint":"ws://0.0.0.0:6768"}
  ],
  "authToken": "<token>",
  "startedAt": 1784758878476
}
```

## Reachability

> **Current production access URL: `https://hetzner-orca.tail5350b8.ts.net/`**
> (Tailscale Serve, tailnet-only, real `*.ts.net` cert, runtime scope — the browser Web UI).
> Open it on a **Tailscale-connected** device. The first visit needs the `#pairing=…` Web
> client URL from `docker logs` (auto-pairs the browser); then bookmark the bare URL above.
>
> ⚠️ **Do not use `http://localhost:6768` or `http://127.0.0.1:6768` unless you are running
> the SSH local-forward tunnel** described under "Alternative" below. Opening a localhost
> URL without the tunnel produces Chrome's `ERR_CONNECTION_REFUSED / "localhost refused to
> connect"` (the address-bar URL points at your own machine, where nothing is listening). The
> `localhost` path is a fallback access model, not the primary one — bookmark the `*.ts.net`
> URL instead.

Orca's docs warn against exposing `orca serve` to the public internet. The production
deployment reaches it over **Tailscale** — no public domain, no open firewall port, no auth
proxy needed. Two other models are documented below (SSH tunnel; public domain) for context.

### Production model: Tailscale Serve (HTTPS, tailnet-only)

The host runs Tailscale and is itself a tailnet node, so it has both a stable tailnet IP
(e.g. `100.65.54.114`) and a **MagicDNS** name of the form `<node>.<tailnet>.ts.net`
(e.g. `hetzner-orca.tail5350b8.ts.net`). **Tailscale Serve** terminates TLS on that name
and proxies it to the local Orca port, giving a real `https://<node>.<tailnet>.ts.net/` URL
with a browser-trusted cert — private (tailnet-only), **no basic auth**, and WebSocket
upgrades pass through (so it sidesteps the basic-auth breakage documented under the public
domain below). This is the production model.

Coolify publishes `6768:6768` to the host (`0.0.0.0:6768`). Serve does **not** bind the
host's public 443 — it terminates TLS inside `tailscaled` on the tailnet plane, so it does
not collide with Coolify's Traefik (which owns public 80/443).

> ⚠️ **Firewall caveat (post-2026-07-23 migration):** the production Tailscale-Serve URL is
> tailnet-only regardless (Serve listens on the tailnet plane, not the public NIC). **But**
> the current host has **no Hetzner Cloud firewall**, so the raw `6768` port **is publicly
> exposed** on the host's public IP (`http://<host-ip>:6768/` returns 200 to anyone). The
> pre-migration host had a `coolify-firewall` blocking 6768; it did not carry over to the new
> server. This is a known security regression pending a firewall fix (apply a Hetzner firewall
> allowing 22/80/443/41641-udp and denying the rest — careful not to lock out SSH). Until then,
> rely on the Tailscale-Serve URL for access and treat the pairing blob as the gate.

**One-time setup on the host:**

1. **Enable Tailscale Serve tailnet-wide** (admin console → DNS / Access Controls). Until you
   do, `tailscale serve` errors with `Serve is not enabled on your tailnet` and prints a
   deep-link (`https://login.tailscale.com/f/serve?node=…`) to enable it.
2. **Point Serve at the local port — use `127.0.0.1`, not `localhost`:**
   ```bash
   tailscale serve --bg --https=443 http://127.0.0.1:6768
   ```
   `--bg` makes it persistent across `tailscaled`/host restarts. ⚠️ `localhost` resolves to
   IPv6 `::1` first and Orca listens on **IPv4 only** (`0.0.0.0:6768`), so
   `http://localhost:6768` returns **502 Bad Gateway**. Always use `http://127.0.0.1:6768`.
   (`tailscale serve status` to view; `tailscale serve --reset` to clear.)
3. **Set `ORCA_PAIRING_ADDRESS=wss://<node>.<tailnet>.ts.net`** (no port — Serve is on 443).
   This is mandatory for any HTTPS front: Orca bakes this into the pairing blob as the WS
   endpoint, and an HTTPS page opening a plain `ws://` socket is **mixed-content-blocked**
   (the UI hangs — same failure mode as basic auth on a public domain). Orca accepts a full
   `wss://host` URL and advertises it with no `:6768` appended.
4. **Restart via Coolify** (`POST /applications/<uuid>/restart`) so Orca recreates with the
   new env var and reprints a `Web client URL` whose blob's `endpoint` is `wss://…`.

Then on any Tailscale-connected device, open the **Orca Web** client:

1. Get the `Web client URL` the server printed (Coolify API or `docker logs`):
   ```bash
   curl -H "Authorization: Bearer <token>" \
     "https://<coolify>/api/v1/applications/<app-uuid>/logs" \
     | jq -r '.logs' | grep -oE 'https://<node>\.<tailnet>\.ts\.net/web-index.html#pairing=[A-Za-z0-9%._-]+' | tail -1
   # or over SSH:  docker logs <container> 2>&1 | grep "Web client URL"
   ```
2. Open that URL in a browser on a Tailscale-connected device — the `#pairing=…` fragment
   auto-pairs the web client (no pasting). After the first pair, **bookmark the bare URL**
   `https://<node>.<tailnet>.ts.net/` — the paired device token persists in the `/home/orca`
   volume, so the bare URL reconnects on every visit, across restarts and redeploys.

> **Fallback (plain tailnet IP, no Serve):** if Serve is ever reset, the instance is still
> reachable at `http://<tailscale-ip>:6768/` (set `ORCA_PAIRING_ADDRESS` back to the IP).
> That `http` is end-to-end encrypted by Tailscale (WireGuard), so the missing TLS is
> cosmetic — the `http` is only the last hop inside an already-encrypted tunnel. Tailnet
> membership is the access gate; the pairing blob is the use gate.

> Requires Tailscale running on the client device, and no conflicting VPN (a system VPN can
> black-hole the Tailscale route and make the URL time out — disable it if the page won't
> load).

### Alternative: SSH local-forward tunnel (loopback model)

If you can't use Tailscale, set `ORCA_PAIRING_ADDRESS=127.0.0.1` and forward the port:

```bash
ssh -i ./id_ed25519 -N -L 6768:127.0.0.1:6768 root@<host-ip>
```

Then open `http://localhost:6768/web-index.html#pairing=…` (grab the `Web client URL` from
`docker logs`, substituting `127.0.0.1`→`localhost`). This is the original documented model;
the Tailscale model above is just the same thing without the tunnel.

### Alternative: public domain (no basic auth)

A public `https://<domain>/` works if you set `ORCA_PAIRING_ADDRESS=wss://<domain>` — Orca
accepts a full `wss://host` URL as the pairing address (verified: it advertises
`wss://<domain>` with no `:6768` appended). Coolify auto-provisions the Let's Encrypt cert
via Traefik. The pairing blob is the only gate, so the connect page is public but useless
without a fresh pairing URL.

> ⚠️ **Do NOT put Coolify HTTP basic auth on an Orca public domain.** The Web client is an
> SPA (`web-index.html` → `./assets/web-index-*.js`) that opens `new WebSocket(wss://…)`.
> Browsers do **not** send cached basic-auth credentials on a JS-initiated WebSocket and do
> not prompt for WS auth, so the WS upgrade gets `401` from Traefik and fails silently — the
> UI hangs forever on "loading". (A curl with explicit `-u` creds returns `101`, which is
> misleading — the browser can't do that.) If you need real auth on a public domain, use a
> **cookie-based forward-auth** proxy (OAuth2 Proxy / Authelia / Cloudflare Access): a
> session cookie *is* sent on the WebSocket upgrade, so unlike basic auth it works.

### A domain name without public exposure

The Tailscale Serve model above **is** this — a real `*.ts.net` domain with a real cert that
stays tailnet-only, no security downgrade, no auth needed. There's nothing extra to set up.

## Coolify setup (step-by-step)

1. **Create the application** from this public GitHub repository (Dockerfile build pack,
   base directory `/`).

2. **Ports — use the real API fields, not `custom_docker_run_options`.** Set:
   - `ports_exposes` = `6768`
   - `ports_mappings` = `6768:6768`

   Via the Coolify API:
   ```bash
   curl -X PATCH "https://<coolify>/api/v1/applications/<app-uuid>" \
     -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
     -d '{"ports_exposes":"6768","ports_mappings":"6768:6768"}'
   ```
   > ⚠️ **`custom_docker_run_options` is ignored for Dockerfile apps.** Both `-p` and `-v`
   > placed there are silently dropped — the container ends up with no published port and no
   > mounts. Use `ports_mappings` for the port and the UI for the volume (below).

3. **Domain:** none (private deployment).

4. **Persistent storage (required):** add a persistent volume in the Coolify UI
   (**Settings → Persistent Storage**) mounted at **`/home/orca`**. See
   [Persistent storage](#persistent-storage). There is **no API endpoint** for this; it's a
   one-time manual UI step. Without it the pairing token rotates on every redeploy and
   saved browser connections break.

5. **Environment variables:** add the Claude Code / Codex auth vars and
   `ORCA_PAIRING_ADDRESS`. Production wires Claude Code to **Ollama Cloud** (an
   Anthropic-compatible endpoint) rather than Anthropic — see
   [Environment variables](#environment-variables).

6. **Deploy.** Do not enable auto-deploy until the first deploy is verified.

## Environment variables

| Variable | Scope | Purpose |
| --- | --- | --- |
| `ORCA_PAIRING_ADDRESS` | runtime | Address baked into the pairing blob as the WS endpoint. `127.0.0.1` (SSH tunnel), the host's Tailscale IP (plain tailnet fallback), `wss://<node>.<tailnet>.ts.net` (**Tailscale Serve — production**), or `wss://<domain>` (public). |
| `ORCA_MOBILE_PAIRING` | runtime | Any non-empty value → **mobile** scope (native apps; `repo.add` blocked). Unset/empty → **runtime** scope (browser Web UI; production default). `${VAR:+…}` means `"0"` still enables it — delete the var to disable. |
| `ANTHROPIC_BASE_URL` | runtime | Claude Code backend. Production: `https://ollama.com` (Ollama Cloud's Anthropic-compatible endpoint — no `ollama` binary/daemon needed). |
| `ANTHROPIC_AUTH_TOKEN` | runtime, secret | Bearer token for the backend. For Ollama Cloud, your `OLLAMA_API_KEY` (ollama.com authenticates via `Authorization: Bearer`, not `x-api-key`). |
| `ANTHROPIC_MODEL` | runtime | Fallback model when no tier-specific slot applies. Production: `glm-5.2:cloud` (matches the Opus/main model). |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` | runtime | Per-tier overrides (Opus = main loop, Sonnet = general, Haiku = fast background). They do **not** have to be the same model — per-tier routing with different `:cloud` models works (verified; see note below). Each slot must be set to a tag the backend accepts, or Claude Code errors "model not found". Production: Opus=`glm-5.2:cloud`, Sonnet=`kimi-k2.7-code:cloud`, Haiku=`gemma4:31b-cloud`. |
| `CLAUDE_CODE_SUBAGENT_MODEL` | runtime | Model for Task-tool subagents. **Unset it to make subagents inherit the main session model** (dynamic — follows whatever the main loop runs). Set it explicitly only as a failsafe (see note below). Production: **unset** (subagents inherit `glm-5.2:cloud`). |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` / `_DISABLE_NONESSENTIAL_TRAFFIC` | runtime | Set both to `1` to keep Claude Code quiet against a non-Anthropic backend. ⚠️ `_DISABLE_NONESSENTIAL_TRAFFIC` also disables Claude Code's auto-updater (`claude doctor`: "Auto-updates: disabled"), so update the CLI manually (see [Updating the agent CLIs](#updating-the-agent-clis)). |
| `OPENAI_API_KEY` | runtime, secret | Authenticates the Codex CLI (if used). |
| `ORCA_VERSION` | **build-time `ARG`**, not env | Pin the Orca release, e.g. `--build-arg ORCA_VERSION=v1.4.150`. Defaults to `latest`. |

> **Ollama Cloud wiring (production):** Claude Code (the CLI Orca spawns) is pointed at
> Ollama Cloud, not Anthropic, via the `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` /
> `ANTHROPIC_MODEL*` vars above. Orca's agent PTY inherits container env, so this works with
> the normal **Claude** agent (do **not** use the "claude-teams" agent variant — its env
> allowlist drops `ANTHROPIC_BASE_URL`). No `ollama` binary or daemon is installed; the
> `ollama launch claude` command does not exist in the container.
>
> **Per-tier routing (verified 2026-07-23):** the three `ANTHROPIC_DEFAULT_*_MODEL` slots can
> hold *different* `:cloud` models simultaneously — Claude Code routes each tier to its own
> model. (An earlier version of this README claimed all three must be the same model or
> Claude Code errors "model not found"; that was a misdiagnosis — the error actually comes
> from an *invalid tag*, e.g. a local-only `gemma4:latest` instead of a cloud `gemma4:31b-cloud`.
> Every slot must be set to a tag the backend accepts, but they need not match.) Validate a
> tag before deploying it:
> ```bash
> curl -s -o /dev/null -w "%{http_code}\n" https://ollama.com/v1/messages \
>   -H "Authorization: Bearer $OLLAMA_API_KEY" -H "content-type: application/json" \
>   -H "anthropic-version: 2023-06-01" \
>   -d '{"model":"<tag>","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
> # expect 200
> ```
> Verified-valid Ollama Cloud tags: `glm-5.2:cloud`, `kimi-k2.7-code:cloud`, `gemma4:31b-cloud`
> (also `gemma4:cloud`, `gemma4:31b`), `deepseek-v4-pro:cloud`, `deepseek-v4-flash:cloud`,
> `kimi-k2.6:cloud`, `glm-5.1:cloud`, `qwen3.5:cloud`, `qwen3-coder:480b-cloud`,
> `minimax-m2.7:cloud`. GLM/DeepSeek/Kimi are reasoning models (emit a `thinking` block);
> Gemma4 returns plain text — fine for the fast Haiku tier.
>
> **Subagents inherit the main model when `CLAUDE_CODE_SUBAGENT_MODEL` is unset** (resolution
> order: env var → per-invocation `model` param → subagent `model:` frontmatter → main session
> model). The built-in subagents (Explore/Plan/general-purpose) use `model: inherit` and are
> safe. ⚠️ A *custom* subagent with `model: sonnet`/`haiku`/`opus`/`fable` frontmatter resolves
> to a built-in Anthropic model ID and will 404 "model not found" on a non-Anthropic backend —
> `CLAUDE_CODE_SUBAGENT_MODEL=inherit` does **not** shield against this (it still falls through
> to the frontmatter). Give custom subagents `model: inherit` (or a full `:cloud` ID), or set
> `CLAUDE_CODE_SUBAGENT_MODEL=<:cloud id>` as a blanket failsafe (which pins subagents to one
> model — no dynamic inheritance).
>
> Env-var changes need a Coolify restart/redeploy to take effect — `POST /applications/<uuid>/restart`
> queues a `restart_only` deployment that recreates the container with the new env (~1–2 min).
> Fallback if a model's tool-call quirks bite: swap that slot's var to `qwen3-coder:480b-cloud`
> (or back to `glm-5.2:cloud`) and restart.

## First run / verification

1. **Build logs:** trigger a deploy in Coolify; confirm the build completes and
   `squashfs-root/AppRun` is present.
2. **Runtime check:** the container stays up (restart_count 0). Confirm the port is
   published and the server responds on the host:
   ```bash
   ssh -i ./id_ed25519 root@<host-ip> \
     'docker port $(docker ps --format "{{.Names}}" | grep <app-uuid> | head -1)'
   curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://127.0.0.1:6768/
   ```
3. **Serve-mode check:** confirm serve mode is active (not just headed-on-Xvfb) — the
   container logs must contain the readiness banner:
   ```bash
   ssh -i ./id_ed25519 root@<host-ip> \
     'docker logs <container> 2>&1 | grep -E "Orca server ready|Web client URL|Pairing URL"'
   ```
   If those lines are absent, see the first row of [Troubleshooting](#troubleshooting).
4. **Use it:** extract the `Web client URL` from the logs and open it in a browser on a
   Tailscale-connected device (production model — see [Reachability](#reachability)), or over
   the SSH tunnel with `127.0.0.1`→`localhost`. The Orca Web UI should load and pair
   automatically; bookmark the bare URL for subsequent visits.
5. **Agent smoke test:** from the Web UI, run a trivial task with Claude Code and one with
   Codex to confirm both CLIs are present and authenticated.
6. **Persistence check:** trigger a redeploy and confirm the Web UI still recognizes the
   session afterward (proves the `/home/orca` volume is working and the pairing token did
   not rotate).
7. **Tailscale Serve check (production):** once Serve is configured, from a tailnet device
   confirm the HTTPS front and the wss upgrade:
   ```bash
   curl -sS -o /dev/null -w "%{http_code} ssl=%{ssl_verify_result}\n" https://<node>.<tailnet>.ts.net/
   # expect: 200 ssl=0   (valid cert)
   curl -sS -i --http1.1 -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://<node>.<tailnet>.ts.net/ | head -1
   # expect: HTTP/1.1 101 Switching Protocols
   ```
   A 502 means Serve is pointed at `localhost` instead of `127.0.0.1` (see
   [Troubleshooting](#troubleshooting)).

## Persistent storage

Orca's identity, paired-device keys, profile data, and the agent-CLI configs live under the
`orca` user's home (`~/.config/orca`, `~/.orca`, `~/.claude`, `~/.codex`, `~/.gemini`, …).
Without persistence, **every redeploy resets all of it** — Orca gets a new `runtimeId`, the
E2EE keypair regenerates, the device registry resets, and **the pairing token rotates**, so
any connected browser client must be re-paired with the new `Pairing URL` from `docker logs`.

- **Mount a persistent volume at `/home/orca`** (covers both `~/.config/orca` runtime state
  and the dotfile agent configs).
- **Add it via the Coolify UI** (Settings → Persistent Storage). Coolify exposes **no API
  endpoint** for persistent storage, and `custom_docker_run_options -v` is ignored (see the
  gotcha above), so this is a manual one-time UI step.
- **Verify** by redeploying and confirming the session survives (step 6 above).

## Pinning & upgrading the Orca version

By default the image pulls `releases/latest`. For reproducible builds, pin a release at
build time:

```bash
docker build --build-arg ORCA_VERSION=v1.4.150 -t orca-coolify .
```

To upgrade Orca, change `ORCA_VERSION` (or leave `latest`) and rebuild/redeploy. Orca's
upgrade SOP notes that persisted state lives under `~/.config` and survives binary
replacement, so a pinned image can still read existing state after an upgrade.

> ⚠️ **`latest` rolls forward** and a future release may change runtime needs (new libs,
> different flags, etc.). Pinning a specific release makes deploys reproducible. Note also
> that the headless docs on `main` may describe behavior ahead of the release you actually
> pull — verify against the *tagged* docs for your `ORCA_VERSION` (e.g. the `v1.4.150`
> headless guide linked at the top).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| No `Orca server ready` / `Pairing URL` in `docker logs`, but `:6768` returns HTTP 200 | Passed the CLI subcommand form (`serve --port … --pairing-address …`) to `AppRun`, which execs Electron directly — so `isServeMode` was false and the app opened its GUI window on Xvfb instead of entering serve mode. The WS server still starts (HTTP 200) but `printServeReady` never runs. | Pass Electron-format flags directly: `--serve --serve-port 6768 --serve-pairing-address 127.0.0.1`. |
| `Unauthorized. Pair this web client again.` when pasting a pairing URL | The URL was hand-built using the `authToken` from `orca-runtime.json` (the runtime session token), not a real pairing invite token. | Use the `Pairing URL` the server printed to `docker logs` (its `deviceToken` comes from the device registry). Don't hand-build pairing URLs. |
| Browser shows `This site can't be reached / ERR_CONNECTION_REFUSED / "localhost refused to connect"` | You opened a stale `http://localhost:6768` (or `127.0.0.1:6768`) URL/bookmark from the SSH-tunnel model with **no SSH tunnel running** — the address bar points at your own machine, where nothing listens. (An in-page `new WebSocket(...)` failure can't produce this Chrome net-error page; it strictly means a top-level localhost navigation, not a server bug.) | Use the production URL `https://<node>.<tailnet>.ts.net/` on a Tailscale-connected device — open the `#pairing=…` Web client URL from `docker logs` once to auto-pair, then bookmark the bare URL. **Delete the stale `localhost:6768` bookmark.** See [Reachability](#reachability). |
| Container exits **126** | Missing Electron/Chromium shared libs on the minimal base. | Ensure the full lib list in the Dockerfile's `apt-get install` is present. |
| Container exits **127**, `/orca-ide: No such file or directory` | `APPDIR` not set; `AppRun` can't resolve `$APPDIR/orca-ide`. | `export APPDIR=/opt/orca/squashfs-root` (done in the entrypoint). |
| **Segfault (139)**, "Missing X server or $DISPLAY" | Orca's auto-Xvfb did not start in the container. | Wrap the launch in `xvfb-run -a` (done in the entrypoint). |
| `[single-instance] Another Orca instance is already running` | A second `orca` launched in the same userData profile (e.g. `serve --help` while `serve` is up). | Don't run a second orca in the same container; stop the first or use a separate profile. |
| `[ERROR:dbus/bus.cc] …` / `gpu … ContextResult::kTransientFailure` | Harmless Chromium stderr noise in a container without D-Bus/GPU. | Ignore — orca serve works fine despite these. |
| Coolify logs API returns `400 "Application is not running"` | The container has already exited, and the API only serves running containers. | The entrypoint keeps the container alive briefly after an exit (`sleep 60`) so logs are capturable; or inspect via SSH `docker logs`. |
| Port 6768 not published / no mounts despite `custom_docker_run_options` | `custom_docker_run_options` is ignored for Dockerfile apps. | Use `ports_mappings` (API) for the port and the Coolify UI for the volume. |
| Saved browser connection breaks after every redeploy | Pairing token rotates on each container start because `~/.config/orca` isn't persisted. | Mount a persistent volume at `/home/orca` (see [Persistent storage](#persistent-storage)). |
| Tailscale Serve returns **502 Bad Gateway** | Serve proxied to `http://localhost:6768`, and `localhost` resolves to IPv6 `::1` while Orca listens on IPv4 only (`0.0.0.0:6768`) — the IPv6 path resets. | Point Serve at explicit IPv4: `tailscale serve --bg --https=443 http://127.0.0.1:6768`. |
| `tailscale serve` errors `Serve is not enabled on your tailnet` | The Serve feature is tailnet-wide and off by default. | Open the deep-link the CLI prints (`https://login.tailscale.com/f/serve?node=…`) and enable it, then retry. |
| HTTPS page loads but the Web UI hangs on "loading" | `ORCA_PAIRING_ADDRESS` is still an IP / `ws://…`, so the HTTPS page opens a plain `ws://` socket → mixed-content block. | Set `ORCA_PAIRING_ADDRESS=wss://<node>.<tailnet>.ts.net` and restart via Coolify. |
| Claude Code shows a permission / "can't auto-update" notice in the Orca terminal; `npm install -g …@latest` fails with permission denied | The CLIs were `npm install -g`'d as root into the default global prefix, which is root-owned — the non-root `orca` user can't write to it, so Claude Code's auto-updater fails at startup. | Fixed in the Dockerfile: the CLIs are installed as `orca` into a user-owned prefix (`/opt/node-global` via `NPM_CONFIG_PREFIX`). After a rebuild/redeploy, `which claude` → `/opt/node-global/bin/claude` and `npm install -g @anthropic-ai/claude-code@latest` works from the Orca terminal. |

**Reading logs:**
- Coolify API: `GET /api/v1/applications/<uuid>/logs` → returns `{"logs": "<string>"}` (not
  an array); only running containers.
- Read-only SSH (no changes): `docker ps -a`, `docker logs --tail 100 <container>`,
  `docker exec <container> sh -c "…"` for `curl`/`ls`/`cat`.

## Security notes

- **TLS.** With Tailscale Serve (production) the `https://<node>.<tailnet>.ts.net` URL has a
  real, browser-trusted cert — full TLS to the browser. The plain tailnet-IP fallback
  (`http://<ip>:6768`) has no TLS but is end-to-end encrypted by Tailscale (WireGuard), so the
  missing TLS is cosmetic (the `http` is only the last hop inside an already-encrypted tunnel);
  same for the SSH-tunnel model. Do not expose 6768 to the public internet without an encrypted
  transport in front of it.
- **Non-root runtime.** The `orca` user (UID 1000) runs the server.
- **Secrets.** `ANTHROPIC_AUTH_TOKEN` / `OPENAI_API_KEY` are stored as Coolify env vars
  (mark secret / not exposed). The `authToken` in `orca-runtime.json` is a secret too —
  don't expose it.
- **Pairing URLs are credentials.** The `Pairing URL` and `Web client URL` embed the
  device-registry `deviceToken` as base64 (reversible). Treat them like a password — don't
  post them publicly or commit them. A leaked URL lets a third party pair their own browser
  to your server until you redeploy (which mints a new token) or revoke. In the Tailscale
  model a leaked URL is only useful to someone also on your tailnet; on a public domain it's
  useful to anyone on the internet — keep that difference in mind.
- **Firewall.** On the pre-2026-07-23 host, a Hetzner Cloud firewall blocked 6768 externally
  so only the tailnet (or SSH tunnel) reached it. The current (post-migration) host has **no
  cloud firewall**, so `6768` is publicly exposed on the host IP until a firewall is applied —
  see the caveat in [Reachability → Production model](#production-model-tailscale-serve-https-tailnet-only).
  The Tailscale-Serve URL itself stays tailnet-only; treat the pairing blob as the real gate.
- **Don't use Coolify basic auth on an Orca domain.** It breaks the browser WebSocket (see
  [Reachability → public domain](#alternative-public-domain-no-basic-auth)). Use a
  cookie-based forward-auth proxy instead, or stay on the Tailscale model.

## Known limitations

- Agent auth is **API-key only** in a headless container; interactive OAuth/subscription
  login is impractical here.
- **Mobile (native app) scope is sandboxed.** It works without an Orca account on the
  server, but mobile-scope clients cannot add projects (`repo.add` is rejected). Production
  runs **runtime scope** (browser Web UI, full permissions, no account) for that reason.
  Switch scopes by setting/deleting `ORCA_MOBILE_PAIRING` and redeploying.
- **Pairing token rotates per redeploy until `/home/orca` is persisted**, so saved browser
  connections break on each redeploy. Mount the volume (see [Persistent storage](#persistent-storage)).
- The headless docs on `main` may describe behavior ahead of the v1.4.150 release; always
  cross-check the tagged docs for your pinned `ORCA_VERSION`.

## Repository files

| File | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | The image: base, deps + Electron libs, Node + agent CLIs, AppImage download/extract, `orca` user, entrypoint. |
| [entrypoint.sh](entrypoint.sh) | Starts Xvfb and runs `AppRun --no-sandbox --serve --serve-port 6768 --serve-pairing-address "${ORCA_PAIRING_ADDRESS:-127.0.0.1}" ${ORCA_MOBILE_PAIRING:+--serve-mobile-pairing}`. |
| [README.md](README.md) | This document. |
| [.gitattributes](.gitattributes) | Forces LF line endings for `entrypoint.sh` and `Dockerfile`. |

## References

- Orca repo: https://github.com/stablyai/orca
- Orca headless guide (v1.4.150): https://github.com/stablyai/orca/blob/v1.4.150/docs/reference/headless-linux-server.md
- Orca headless guide (main, ahead of v1.4.150): https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
- Coolify: https://coolify.io — [API reference](https://coolify.io/docs/api-reference/api), [persistent storage](https://coolify.io/docs/knowledge-base/persistent-storage)