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
  /opt/orca/squashfs-root/AppRun --no-sandbox serve --port 6768 --pairing-address 127.0.0.1
```

The server:

- Listens on `0.0.0.0:6768` (WebSocket + HTTP).
- Serves the **Orca Web** client at `http://<host>:6768` — the full Orca UI (terminals,
  agents, worktrees, settings) running in a browser.
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

3. **Node 20 LTS** (NodeSource), so the coding-agent CLIs can be installed globally.

4. **Agent CLIs:** `npm install -g @anthropic-ai/claude-code @openai/codex`. Authenticated
   at runtime via API-key env vars (see [Environment variables](#environment-variables)).

5. **Orca AppImage:** downloaded from the GitHub release (latest by default, or a pinned
   `ORCA_VERSION`), then `--appimage-extract` once at build time (no FUSE at runtime) into
   `/opt/orca/squashfs-root`, then `chmod -R a+rX` + `chmod a+rx AppRun` so the non-root user
   can execute it.

6. **Non-root runtime user:** `useradd -m -s /bin/bash orca`. `WORKDIR /home/orca`,
   `EXPOSE 6768`, `USER orca`, `ENTRYPOINT ["/entrypoint.sh"]`.

## Headless build gotchas

These are the non-obvious things that had to be solved to make Orca run in a container
(each was a real crash-loop until fixed):

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

The headless guide on Orca's **`main` branch** describes a startup banner like:

```
Orca server ready: ws://0.0.0.0:6768
Pairing URL: orca://pair?code=…
```

and a `--json` flag that emits an `orca_server_ready` event with a `pairing` object
(`url`, `webClientUrl`, `qr`, …) for supervisors.

**Orca v1.4.150 emits none of that.** This was verified across every output channel: stdout,
`~/.config/orca/logs/daemon.log`, `~/.config/orca/logs/main.trace.ndjson`, and
`~/.config/orca/orca-runtime.json`. The `--json` flag is not a v1.4.150 flag. The
`orca://pair?code=…` ready/JSON contract is from a newer build than the current release.

What v1.4.150 **does** provide:

- The **Orca Web** UI served on :6768 — the full Orca client in a browser.
- A WebSocket endpoint + `authToken` + `runtimeId` in `~/.config/orca/orca-runtime.json`,
  e.g.:
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

So the **supported way to use this server is the Orca Web UI over an SSH tunnel**, not a
pairing URL. Desktop/mobile-app pairing (pasting an `orca://pair` URL into the Orca app)
is **not available** with v1.4.150 under the loopback-tunnel model; it would need either a
newer Orca release that emits pairing URLs, or a reachable non-loopback advertised address
(see [Reachability](#reachability-private-only)).

## Reachability (private only)

Orca's docs warn against exposing `orca serve` to the public internet. This image is meant
to be reached over an **SSH local-forward tunnel** — no public domain, no firewall port.

Coolify publishes `6768:6768` to the host (binds `0.0.0.0:6768`). The host's firewall blocks
6768 externally, so the port is only reachable through the tunnel. From your client machine:

```bash
ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host-ip>
```

Then open **http://127.0.0.1:6768** in a browser. The Orca Web UI loads and connects back
over the same loopback WebSocket — no pairing URL required.

`--pairing-address 127.0.0.1` makes the advertised endpoint match the tunnel's
`127.0.0.1:6768`. Override it with the `ORCA_PAIRING_ADDRESS` env var if you switch to a
different reachability model (e.g. a Tailscale IP, where you'd set it to the host's
Tailscale address and reach 6768 over the Tailscale network instead of an SSH tunnel).

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
   one-time manual UI step.

5. **Environment variables:** add `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` (mark secret).
   See [Environment variables](#environment-variables).

6. **Deploy.** Do not enable auto-deploy until the first deploy is verified.

## Environment variables

| Variable | Scope | Purpose |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | runtime, secret | Authenticates the Claude Code CLI. |
| `OPENAI_API_KEY` | runtime, secret | Authenticates the Codex CLI. |
| `ORCA_PAIRING_ADDRESS` | runtime, optional | Address advertised to clients. Defaults to `127.0.0.1` (matches the SSH tunnel). |
| `ORCA_VERSION` | **build-time `ARG`**, not env | Pin the Orca release, e.g. `--build-arg ORCA_VERSION=v1.4.150`. Defaults to `latest`. |

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
3. **Use it:** open the SSH tunnel (above) and browse to http://127.0.0.1:6768 — the Orca
   Web UI should load.
4. **Agent smoke test:** from the Web UI, run a trivial task with Claude Code and one with
   Codex to confirm both CLIs are present and authenticated.
5. **Persistence check:** trigger a redeploy and confirm the Web UI still recognizes the
   session afterward (proves the `/home/orca` volume is working).

## Persistent storage

Orca's identity, paired-device keys, profile data, and the agent-CLI configs live under the
`orca` user's home (`~/.config/orca`, `~/.orca`, `~/.claude`, `~/.codex`, `~/.gemini`, …).
Without persistence, **every redeploy resets all of it** — Orca gets a new `runtimeId`, the
E2EE keypair regenerates, and any connected clients must be re-established.

- **Mount a persistent volume at `/home/orca`** (covers both `~/.config/orca` runtime state
  and the dotfile agent configs).
- **Add it via the Coolify UI** (Settings → Persistent Storage). Coolify exposes **no API
  endpoint** for persistent storage, and `custom_docker_run_options -v` is ignored (see the
  gotcha above), so this is a manual one-time UI step.
- **Verify** by redeploying and confirming the session survives (step 5 above).

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
> different flags, the pairing-URL contract landing, etc.). Pinning a specific release makes
> deploys reproducible. Note also that the pairing-URL behavior documented on `main` may
> differ from the release you actually pull — verify against the *tagged* docs for your
> `ORCA_VERSION` (e.g. the `v1.4.150` headless guide linked at the top).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Container exits **126** | Missing Electron/Chromium shared libs on the minimal base. | Ensure the full lib list in the Dockerfile's `apt-get install` is present. |
| Container exits **127**, `/orca-ide: No such file or directory` | `APPDIR` not set; `AppRun` can't resolve `$APPDIR/orca-ide`. | `export APPDIR=/opt/orca/squashfs-root` (done in the entrypoint). |
| **Segfault (139)**, "Missing X server or $DISPLAY" | Orca's auto-Xvfb did not start in the container. | Wrap the launch in `xvfb-run -a` (done in the entrypoint). |
| `[single-instance] Another Orca instance is already running` | A second `orca` launched in the same userData profile (e.g. `serve --help` while `serve` is up). | Don't run a second orca in the same container; stop the first or use a separate profile. |
| `[ERROR:dbus/bus.cc] …` / `gpu … ContextResult::kTransientFailure` | Harmless Chromium stderr noise in a container without D-Bus/GPU. | Ignore — orca serve works fine despite these. |
| Coolify logs API returns `400 "Application is not running"` | The container has already exited, and the API only serves running containers. | The entrypoint keeps the container alive briefly after an exit (`sleep 60`) so logs are capturable; or inspect via SSH `docker logs`. |
| Port 6768 not published / no mounts despite `custom_docker_run_options` | `custom_docker_run_options` is ignored for Dockerfile apps. | Use `ports_mappings` (API) for the port and the Coolify UI for the volume. |
| `--json` not recognized / no `orca_server_ready` event | `--json` is not a v1.4.150 flag (it's from a newer `main` build). | Don't use `--json` on v1.4.150; use the Orca Web UI. |
| No `Pairing URL: orca://…` anywhere | v1.4.150 doesn't emit it (see [Pairing model](#pairing-model-v14150)). | Use the Orca Web UI over the SSH tunnel. |

**Reading logs:**
- Coolify API: `GET /api/v1/applications/<uuid>/logs` → returns `{"logs": "<string>"}` (not
  an array); only running containers.
- Read-only SSH (no changes): `docker ps -a`, `docker logs --tail 100 <container>`,
  `docker exec <container> sh -c "…"` for `curl`/`ls`/`cat`.

## Security notes

- **No TLS on 6768.** Traffic is encrypted by the SSH tunnel. Do not expose 6768 publicly.
- **Non-root runtime.** The `orca` user (UID 1000) runs the server.
- **Secrets.** `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` are stored as Coolify env vars (mark
  secret / not exposed). The `authToken` in `orca-runtime.json` is a secret too — don't
  expose it.
- **Firewall.** The host firewall blocks 6768 externally; only the SSH tunnel reaches it.

## Known limitations

- Agent auth is **API-key only** in a headless container; interactive OAuth/subscription
  login is impractical here.
- **No `orca://pair` URL in v1.4.150** — desktop/mobile-app pairing isn't available under
  the loopback-tunnel model. Use the Orca Web UI, or upgrade Orca / switch to a non-loopback
  advertised address for native-app pairing.
- The headless docs on `main` describe behavior ahead of the v1.4.150 release; always
  cross-check the tagged docs for your pinned `ORCA_VERSION`.

## Repository files

| File | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | The image: base, deps + Electron libs, Node + agent CLIs, AppImage download/extract, `orca` user, entrypoint. |
| [entrypoint.sh](entrypoint.sh) | Starts Xvfb and runs `orca serve --port 6768 --pairing-address 127.0.0.1`. |
| [README.md](README.md) | This document. |
| [.gitattributes](.gitattributes) | Forces LF line endings for `entrypoint.sh` and `Dockerfile`. |

## References

- Orca repo: https://github.com/stablyai/orca
- Orca headless guide (v1.4.150): https://github.com/stablyai/orca/blob/v1.4.150/docs/reference/headless-linux-server.md
- Orca headless guide (main, ahead of v1.4.150): https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
- Coolify: https://coolify.io — [API reference](https://coolify.io/docs/api-reference/api), [persistent storage](https://coolify.io/docs/knowledge-base/persistent-storage)