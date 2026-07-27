# Rebuilding the Orca Coolify app from this repo

This repo holds the **build recipe** for the headless [`orca serve`](https://github.com/stablyai/orca)
deployment that runs on Coolify (Hetzner VPS). It does **not** contain the runtime
configuration or persistent data — those live in Coolify and on the host. This
document is the bridge: it tells you exactly what to recreate, in what order, to
stand up a fresh Orca Coolify app identical to production.

If you only have this GitHub repo and not a recent persistent-volume snapshot, you
will be able to build the container but every paired device will need to re-pair
and all agent CLI auth/credentials will need to be re-entered. Treat the volume
snapshot as the truly irreplaceable artifact.

---

## 1. What this repo contains

| File | Purpose |
| --- | --- |
| `Dockerfile` | Builds the headless Orca image. Base `ubuntu:22.04`, installs Orca v1.4.150 AppImage (extracted, no FUSE), Node 22 LTS, Claude Code + Codex CLIs (user-owned prefix at `/opt/node-global`), non-root `orca` user with passwordless `sudo`. |
| `entrypoint.sh` | Starts Xvfb + runs `AppRun --serve --serve-port 6768 --serve-pairing-address …` (Electron-format flags — see README gotchas). |
| `README.md` | Full reference: build details, runtime behavior, redeploy gotchas, troubleshooting. Read this if anything in `REBUILD.md` is unclear. |
| `.gitattributes` | Forces LF line endings — required for `entrypoint.sh` to be executable inside the Linux container. |
| `.gitignore` | Excludes local volume snapshots, env files, secrets. |

---

## 2. What lives outside this repo (must be recreated)

### 2.1 Coolify application

| Setting | Production value (snapshot 2026-07-27) |
| --- | --- |
| App UUID | `krno4lok0n60h987k6876wlw` |
| Build pack | `dockerfile` |
| Git repository | `https://github.com/fordeboy444/orca-coolify.git` |
| Branch | `main` |
| Port mapping | `6768:6768` (container exposes `6768`) |
| Public FQDN | **none** — Tailscale Serve only |
| Health check | **disabled** (Orca serve-mode prints readiness to stdout; Coolify's HTTP probe would hit the SPA shell, not a stable endpoint) |
| Persistent volume | Container path `/home/orca` → Docker volume **`orca-home`** |

> ℹ️ Coolify's API does **not** return the persistent-volume mount in
> `GET /applications/<uuid>`. Verify the actual mount on the live host with:
> ```
> docker inspect <container-id> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
> ```
> The volume name in production is **`orca-home`** (NOT `orca-coolify_orca-home` —
> Coolify renamed it once; see "Volume rename gotcha" in auto-memory).

### 2.2 Environment variables (set in Coolify UI)

Each key appears in **two** Coolify environments (production + preview). When
recreating, set both — Coolify's API only returns envs for the current environment,
but both slots must be kept in sync. Mark every secret with `is_secret=true`.

#### Non-secret (safe to set to literal values)

| Key | Value |
| --- | --- |
| `ORCA_PAIRING_ADDRESS` | `wss://hetzner-orca.tail5350b8.ts.net` (production Tailscale URL — must be `wss://` for the HTTPS web UI; any plain `ws://` causes mixed-content block) |
| `ANTHROPIC_BASE_URL` | `https://ollama.com` |
| `ANTHROPIC_MODEL` | `glm-5.2:cloud` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `glm-5.2:cloud` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `minimax-m3:cloud` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `deepseek-v4-flash:cloud` |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `glm-5.2:cloud` |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` | `1` |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` |
| `ORCA_MOBILE_PAIRING` | **leave unset / empty** for browser scope (runtime). Any non-empty value switches to mobile-scope pairing. |

#### Secret (fetch from secure sources; never paste in chat / commits)

| Key | Source |
| --- | --- |
| `ANTHROPIC_AUTH_TOKEN` | Ollama Cloud dashboard → API keys. Length 57 — looks like `sk-…`. Mark secret. |
| `OPENAI_API_KEY` | OpenAI dashboard → API keys. Length 56. Mark secret. |
| `ANTHROPIC_API_KEY` | (Legacy / currently empty. Leave unset unless the rebuild requires it.) |

### 2.3 Persistent volume (`/home/orca`)

This is the irreplaceable artifact. It contains:

- `~/.config/orca/orca-runtime.json` — server's `authToken` + `runtimeId`
- `~/.config/orca/orca-devices.json` — paired browser/device registry
- `~/.config/orca/orca-e2ee-keypair.json` — encryption keypair (lose this → lose access to stored agent state)
- `~/.config/orca/agent-session-authority.key`
- `~/.config/orca/orchestration.db*` — sqlite with agent sessions
- `~/.claude/`, `~/.codex/` — agent CLI configs + auth
- `~/.hermes/` — Hermes Agent state (skills, plugins)
- `~/Projects/`, `~/Agents/` — user repos

The full volume is ~2.4 GB (Chromium caches dominate); a gzip tarball is ~1 GB.

**Backup procedure (read-only, no app impact):**

```bash
# SSH to the Hetzner host
ssh -i ./id_ed25519 root@<hetzner-ip>

# Find the volume's _data path
docker volume inspect orca-home --format '{{.Mountpoint}}'
# → /var/lib/docker/volumes/orca-home/_data

# Tar (excludes unix sockets and Chromium SingletonLock to keep tar fast)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
tar --exclude='*.sock' --exclude='Singleton*' \
  -czf /tmp/orca-home-$STAMP.tgz \
  -C /var/lib/docker/volumes/orca-home/_data .

# Verify key files
tar tzf /tmp/orca-home-$STAMP.tgz | grep -E \
  '(orca-runtime\.json|orca-devices\.json|orca-e2ee-keypair\.json|agent-session-authority\.key|orchestration\.db)'

# SHA-256 (record this alongside the archive)
sha256sum /tmp/orca-home-$STAMP.tgz

# Pull to local machine
scp -i ./id_ed25519 root@<hetzner-ip>:/tmp/orca-home-$STAMP.tgz \
  ./orca-coolify/_backups/

# Clean up the host copy
rm /tmp/orca-home-$STAMP.tgz
```

**Restore procedure:**

```bash
# Stop the live container (replace UUID)
docker stop krno4lok0n60h987k6876wlw-*

# Wipe the volume's _data (DESTRUCTIVE — only on a fresh rebuild)
rm -rf /var/lib/docker/volumes/orca-home/_data/*

# Extract the snapshot into the volume's _data path
tar -xzf ./orca-coolify/_backups/orca-home-<stamp>.tgz \
  -C /var/lib/docker/volumes/orca-home/_data

# Fix ownership — the orca user inside the container is UID 1000
# (the orca-files service and the live container both write as 1000:1000,
# so this is normally already correct, but be defensive on a fresh host)
chown -R 1000:1000 /var/lib/docker/volumes/orca-home/_data

# Restart the app via Coolify UI/API — the running container will see
# the restored files on its next start.
```

### 2.4 Tailscale Serve (host-level)

Production reaches Orca via `https://hetzner-orca.tail5350b8.ts.net/`. This is
**not** a Coolify feature — it's a host-level Tailscale command:

```bash
# Per-node enable (tailnet-wide feature flag must also be on):
# https://login.tailscale.com/f/serve?node=<node-id>
tailscale serve --bg --https=443 http://127.0.0.1:6768
```

Critical: point at explicit `127.0.0.1`, **not** `localhost`. `localhost` resolves
to IPv6 `::1` on this host while Orca listens on IPv4 only, producing a 502.

### 2.5 SSH key + Hetzner firewall

- SSH access uses `id_ed25519` / `id_ed25519.pub` at the workspace root (per the
  parent workspace's `CLAUDE.md`).
- The current Hetzner host runs **without** a Cloud firewall (post-migration
  state — see `hetzner-server-migration` memory note). Port 6768 is publicly
  exposed on the host IP, which is fine only because nothing listens on it
  directly — only Tailscale Serve proxies it. **Do not** add a Coolify public
  domain for Orca without re-evaluating this.

---

## 3. Deploy order (on a fresh Coolify + Hetzner)

1. **Provision Coolify** on a Hetzner VPS (see parent workspace's `guide.md`).
2. **Create the persistent volume first** in the Coolify UI (Storage → Persistent
   Volumes → name `orca-home`). It will be attached to the app in step 5.
3. **Create a project + resource** for Orca (Resources → "+ Add" → "Public/Private
   Repository" → `https://github.com/fordeboy444/orca-coolify.git`, branch `main`,
   build pack `Dockerfile`).
4. **Set the port mapping** to `6768:6768` in the resource's General → Ports.
   Do **not** set `custom_docker_run_options` — it's ignored for Dockerfile apps.
5. **Mount the persistent volume**: in the resource's Storage tab, add a mount
   mapping source `orca-home` → destination `/home/orca`.
6. **Set all environment variables** (table in §2.2). Mark secrets.
7. **Disable health check** (resource's Health Check tab) — see §2.1.
8. **Deploy** (Coolify UI or `POST /applications/<uuid>/deploy`). First build
   pulls Orca AppImage, ~3–5 min.
9. **Tail the logs**: wait for the `Orca server ready: ws://0.0.0.0:6768` line
   + the `Pairing URL: orca://pair?code=…` line.
10. **Restore the volume snapshot** (procedure in §2.3) if upgrading from a
    previous host — this preserves pairing tokens and agent auth. **Then
    redeploy** to pick up the restored files.
11. **Install latest CLIs** inside the running container (one-off, lost on
    next rebuild):
    ```bash
    docker exec -u orca <container> \
      bash -lc 'npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest'
    ```
    Why: `/opt/node-global` is on the container's writable layer, **not** the
    persisted volume. Every redeploy resets it to the Dockerfile-pinned version.
12. **Configure Tailscale Serve** on the host (§2.4) if the app isn't already
    reachable through Tailscale.
13. **Smoke-test**: open the Tailscale URL from any tailnet device, paste the
    `Web client URL` (from `docker logs`) into the "Connect to Orca" landing
    page, confirm agents can spawn and terminals work.

---

## 4. Common pitfalls (also see README troubleshooting)

- **Stuck terminal pane after redeploy** — backend is usually healthy; the issue
  is frontend. Verify with `docker exec --user orca <container> bash -lc 'orca status'`.
- **`Saving browser connection breaks after every redeploy`** — pairing token
  rotates on each container start because `~/.config/orca` wasn't persisted. The
  persistent volume mount in step 5 fixes this.
- **`Tailscale Serve returns 502`** — `tailscale serve` is pointing at `localhost`
  instead of `127.0.0.1`. Fix per §2.4.
- **`HTTPS page loads but Web UI hangs on "loading"`** — `ORCA_PAIRING_ADDRESS`
  is set to a plain `ws://` IP. Use `wss://<node>.<tailnet>.ts.net`.
- **`npm install -g …` fails with permission denied** in the Orca terminal — the
  CLIs were installed as root, not `orca`. Rebuild from this repo (the Dockerfile
  installs them as `orca` into the user-owned prefix `/opt/node-global`).
- **`Port 6768 not published despite `custom_docker_run_options`** —
  `custom_docker_run_options` is ignored for Dockerfile apps. Use the Coolify UI
  Ports tab or `POST /applications/<uuid>/envs` to set `PORTS_MAPPINGS=6768:6768`.

---

## 5. Local volume snapshot reference

The current `_backups/` directory in a working tree of this repo holds:

| File | Size | SHA-256 | Notes |
| --- | --- | --- | --- |
| `orca-home-<UTC-stamp>.tgz` | ~1 GB | (record at backup time) | Full `/home/orca` snapshot. Contains device tokens + agent auth — treat as a credential. |
| `coolify-config-<date>.md` | <10 KB | — | Redacted Coolify app-config snapshot (no secret values). |

**These are local-only — never commit them.** `.gitignore` excludes `_backups/`
and `orca-home-*.tgz` for that reason. Store copies offsite (encrypted disk, cloud
bucket, etc.) if you want a true off-host backup.

Last verified snapshot in this workspace: **2026-07-27T09:20:38Z**,
SHA-256 `bd0596ef3be1f227ed9e7158e17a1337fcc4cfdbb50c372e3b97de04b9e30d50`,
1,010 MB.