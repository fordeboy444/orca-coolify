# orca-coolify

Headless [`orca serve`](https://github.com/stablyai/orca) image for deployment on
[Coolify](https://coolify.io). Mirrors Orca's
[headless Linux server guide](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md):
downloads the prebuilt Linux AppImage, extracts it (Docker has no FUSE), and runs it with
Xvfb + `LIBGL_ALWAYS_SOFTWARE=1`. Pre-installs the **Claude Code** and **Codex** CLIs so
Orca can spawn coding agents inside the container.

## What it does

`entrypoint.sh` starts `Xvfb :99`, then runs:

```
/opt/orca/squashfs-root/AppRun serve --port 6768 --pairing-address 127.0.0.1
```

The server prints `Orca server ready` and a `Pairing URL: orca://pair?code=…` line to
stdout — visible in the Coolify deployment logs. Treat the pairing URL as a secret.

## Reachability (private only)

Orca's docs warn against exposing `orca serve` to the public internet. This image is meant
to be reached over an **SSH local-forward tunnel** — no public domain, no firewall port.

From your client machine:

```bash
ssh -i ./id_ed25519 -L 6768:127.0.0.1:6768 root@<host-ip>
```

Then in the Orca desktop/mobile app: **Settings → Remote Orca Servers → Add Server**, and
paste the pairing URL from the Coolify logs. The client connects to its own
`127.0.0.1:6768`, which the tunnel forwards to the container.

## Coolify setup

- **Build pack:** Dockerfile, base directory `/`.
- **Exposed port:** `6768` (override Coolify's default of 3000).
- **Domain:** none (private deployment). Bind the published port to host **loopback
  (`127.0.0.1`)** only.
- **Persistent storage:** mount a volume at **`/home/orca/.config`** so pairing state and
  agent auth survive redeploys. Without this, every redeploy breaks pairing.
- **Environment variables** (secret / not exposed):
  - `ANTHROPIC_API_KEY` — authenticates the Claude Code CLI.
  - `OPENAI_API_KEY` — authenticates the Codex CLI.

## Pinning the Orca version

By default the image pulls `releases/latest`. For reproducible builds, pin a release:

```bash
docker build --build-arg ORCA_VERSION=v0.x.y -t orca-coolify .
```

Orca's upgrade SOP notes that persisted state lives under `~/.config` and survives binary
replacement, so a pinned image can still read existing state.

## Notes / caveats

- Agent auth is **API-key only** in a headless container; interactive OAuth/subscription
  login is impractical here.
- If Chromium's sandbox fails under the non-root `orca` user, the fallback is to pass
  `--no-sandbox` to the AppRun (add only if needed). Not expected per the headless guide.
- No TLS on 6768 — traffic is encrypted by the SSH tunnel.