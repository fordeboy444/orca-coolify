# orca-coolify

Headless [`orca serve`](https://github.com/stablyai/orca) image for deployment on
[Coolify](https://coolify.io). Mirrors Orca's
[headless Linux server guide](https://github.com/stablyai/orca/blob/v1.4.150/docs/reference/headless-linux-server.md):
downloads the prebuilt Linux AppImage (v1.4.150), extracts it (Docker has no FUSE), and
runs it with Xvfb + `LIBGL_ALWAYS_SOFTWARE=1`. Pre-installs the **Claude Code** and
**Codex** CLIs so Orca can spawn coding agents inside the container.

## What it does

`entrypoint.sh` starts Xvfb, then runs:

```
/opt/orca/squashfs-root/AppRun --no-sandbox serve --port 6768 --pairing-address 127.0.0.1
```

The server listens on `0.0.0.0:6768` and serves the **Orca Web** client (the full Orca
UI: terminals, agents, worktrees, settings) at `http://<host>:6768`. Runtime state is
written to `~/.config/orca/orca-runtime.json`, which records the WebSocket endpoint
(`ws://0.0.0.0:6768`), a `runtimeId`, and an `authToken`.

### Pairing URL caveat (v1.4.150)

The headless guide on Orca's `main` branch describes a `Pairing URL: orca://pair?code=…`
line (and a `--json` `orca_server_ready` event) printed at startup. **Orca v1.4.150 does
not emit these** — that ready/JSON contract is from a newer build. v1.4.150 exposes the
endpoint + `authToken` in `orca-runtime.json` and serves the Orca Web UI on the port
instead. So the supported way to use this server is the **Orca Web client** over an SSH
tunnel (below), not a pairing URL.

## Reachability (private only)

Orca's docs warn against exposing `orca serve` to the public internet. This image is meant
to be reached over an **SSH local-forward tunnel** — no public domain, no firewall port
(Coolify publishes `6768:6768` to the host; the Hetzner firewall blocks 6768 externally,
so only the tunnel reaches it).

From your client machine:

```bash
ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host-ip>
```

Then open **http://127.0.0.1:6768** in a browser — the Orca Web UI loads and connects back
over the same loopback WebSocket. `--pairing-address 127.0.0.1` makes the advertised
endpoint match the tunnel.

(If you later want a desktop/mobile app to pair instead of the Web UI, you'll likely need
either a newer Orca release that emits `orca://pair` URLs, or a reachable non-loopback
advertised address such as a Tailscale IP — set via the `ORCA_PAIRING_ADDRESS` env var.)

## Coolify setup

- **Build pack:** Dockerfile, base directory `/`.
- **Exposed / published port:** `6768` (set `ports_exposes=6768`, `ports_mappings=6768:6768`
  via the API/UI). Coolify's `custom_docker_run_options` is **not** applied to Dockerfile
  apps (it's ignored for `-p`/`-v`), so use the real `ports_mappings` field.
- **Domain:** none (private deployment).
- **Persistent storage (REQUIRED for pairing/agent auth to survive redeploy):** add a
  persistent volume in the Coolify UI (**Settings → Persistent Storage**) mounted at
  **`/home/orca`** (covers `~/.config/orca` runtime state and the `~/.orca`, `~/.claude`,
  `~/.codex`, … agent configs). There is no API endpoint for persistent storage, so this
  is a one-time manual UI step. Without it, every redeploy resets Orca's identity and
  breaks any paired clients.
- **Environment variables** (set in Coolify; mark secret / not exposed):
  - `ANTHROPIC_API_KEY` — authenticates the Claude Code CLI.
  - `OPENAI_API_KEY` — authenticates the Codex CLI.
  - `ORCA_PAIRING_ADDRESS` *(optional)* — advertised address; defaults to `127.0.0.1`.

## Pinning the Orca version

By default the image pulls `releases/latest`. For reproducible builds, pin a release:

```bash
docker build --build-arg ORCA_VERSION=v1.4.150 -t orca-coolify .
```

Orca's upgrade SOP notes that persisted state lives under `~/.config` and survives binary
replacement, so a pinned image can still read existing state.

## Notes / caveats

- Agent auth is **API-key only** in a headless container; interactive OAuth/subscription
  login is impractical here.
- `--no-sandbox` is required: Chromium's sandbox can't run in Docker as a non-root user.
- Xvfb is started explicitly (Orca's auto-Xvfb did not start inside the container).
- No TLS on 6768 — traffic is encrypted by the SSH tunnel.
- Line endings: `entrypoint.sh` must be LF (enforced via `.gitattributes`); CRLF breaks
  bash on Linux.