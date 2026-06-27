---
name: levelsio-vps-deploy
description: Deploys and operates a web app on a single cheap VPS the "levels.io" way — one hardened Hetzner/DigitalOcean box running Next.js (or any Node app) on SQLite + Caddy (auto-HTTPS) + systemd, optionally behind Cloudflare. Use when the user wants cheap single-server hosting, asks to provision a Hetzner/DigitalOcean VPS, wants to deploy a Next.js/Node app WITHOUT Vercel/Supabase/Kubernetes, mentions the "levels.io method" / "one big server" / "boring tech", or asks how to self-host a small/medium app for a flat ~$8/mo. Covers one-time provisioning (lockdown, firewall, users, Caddy, systemd) and repeatable deploys that build native modules on the box.
---

# levelsio-vps-deploy

Deploy and run a web app on **one cheap, hardened VPS** — the levels.io way.
No Kubernetes, no microservices, no managed PaaS. One box, boring tech,
vertical scaling, ship fast.

## The stack (defaults — swap only with reason)

| Layer | Choice | Why |
|---|---|---|
| Host | Hetzner CPX21 (~$8/mo) or DigitalOcean equivalent, Ubuntu 24.04 LTS | flat price, plenty for a small/medium app |
| App | Next.js App Router, `output: "standalone"` (or any Node app) | single self-contained process |
| DB | SQLite via `better-sqlite3`, WAL mode + `busy_timeout` | one file, no DB server, fast |
| Proxy / TLS | Caddy, reverse-proxy to `127.0.0.1:3000` | automatic HTTPS, 3-line config |
| Process mgmt | systemd unit, `Restart=always` | survives crashes and reboots |
| Edge (optional) | Cloudflare in front | DNS, origin hiding, WAF, caching |
| Backups | Litestream → S3/R2 | continuous offsite SQLite replication |

Vertically scale the box (more RAM/CPU) long before you reach for distribution.

## When to use this skill

- "Host my app cheaply on a single server"
- "Provision a Hetzner / DigitalOcean VPS for my Next.js app"
- "Deploy without Vercel / Supabase / Kubernetes"
- "Do it the levels.io way / one big server / boring tech"

## How the pieces fit

```
Internet → (Cloudflare) → Caddy :443 → Next.js :3000 (systemd) → SQLite file
                                                                    ↓
                                                          Litestream → S3/R2
```

Read `references/architecture.md` for the full diagram, rationale per layer,
scaling guidance, and the backup setup.

## Workflow

There are two phases. Provisioning is **once per server**; deploy is **every
release**.

### Phase 1 — Provision (one time)

`scripts/provision.sh` is a **template**. It is meant to be reviewed, edited
(the `CONFIG` block at the top), and run as root on a fresh VPS. It will:

1. Create a non-root `deploy` user with sudo + your SSH key.
2. Lock down SSH: disable password auth and root login.
3. Firewall with `ufw`: allow only 22, 80, 443.
4. Enable `unattended-upgrades` and `fail2ban`.
5. Install Node LTS and Caddy.
6. Create app dirs (`/srv/<app>`, `/srv/<app>-build`, `/var/lib/<app>`) owned by
   `deploy`, and the secrets file `/etc/<app>/env` (mode `0640`, `root:deploy`).
7. Write a `Caddyfile` (`DOMAIN` → `reverse_proxy 127.0.0.1:3000`) and a
   systemd unit for the app.

Steps for the agent:

1. Ask the user for: `APP_NAME`, `DOMAIN`, `DEPLOY_USER` (default `deploy`),
   the public SSH key to install, and the VPS IP / root access.
2. Edit the `CONFIG` block at the top of `scripts/provision.sh`.
3. Have the user copy it to the box and run it as root, e.g.
   `scp scripts/provision.sh root@SERVER:/tmp/ && ssh root@SERVER 'bash /tmp/provision.sh'`.
4. Generate app secrets **server-side** (never in the repo). For each secret:
   `openssl rand -base64 32`, then append to `/etc/<app>/env`.
5. Transfer any third-party credentials **out-of-band** (see Secrets, below).

### Phase 2 — Deploy (every release)

`scripts/deploy.sh` is a **template** run from your dev machine. The key trick:
**build on the box** so native modules (`better-sqlite3`) are compiled for the
server, not your laptop. It will:

1. `rsync` the working tree → `/srv/<app>-build`, excluding `node_modules`,
   `.next`, `.git`, `data.db*`, `.env*`.
2. On the box: `source /etc/<app>/env`; `npm ci`; `npm run build`.
3. (Optional) apply DB migrations (e.g. `npx drizzle-kit migrate`).
4. Assemble the standalone output: copy `.next/static` and `public` into
   `.next/standalone`, and ensure the `better-sqlite3` `.node` binding is
   present under `standalone/node_modules`.
5. `rsync -a --delete .next/standalone/ /srv/<app>/` (excluding `data.db*`).
6. `sudo systemctl restart <app>`; verify `systemctl is-active` and `curl` the
   domain.

Steps for the agent:

1. Confirm the app's `next.config.*` sets `output: "standalone"`.
2. Edit the `CONFIG` block in `scripts/deploy.sh` (`SSH_HOST`, `SSH_KEY`,
   `APP_NAME`).
3. Run it. On failure, consult `references/troubleshooting.md`.

## Secrets — non-negotiable rules

- Secrets live **only** in `/etc/<app>/env` on the server (mode `0640`,
  owner `root:deploy`). **Never** in the repo, the DB, or logs.
- Generate strong secrets **server-side**: `openssl rand -base64 32`.
- The deploy script must `source /etc/<app>/env` — it never bakes secrets into
  the build or prints them.
- Transfer third-party credentials **out-of-band**: `scp` a temp file, extract
  its contents into `/etc/<app>/env`, then `shred -u` the temp file. **Never**
  `echo` a credential on the command line (it lands in shell history and logs).

## SQLite gotcha (read before first build)

Set `busy_timeout` **before** switching the database to WAL mode, or the first
write during build/migration can fail with `SQLITE_BUSY`:

```js
const db = require("better-sqlite3")(process.env.DATABASE_PATH);
db.pragma("busy_timeout = 5000"); // FIRST
db.pragma("journal_mode = WAL");  // THEN
```

The DB file lives outside the deploy target (e.g. `/var/lib/<app>/data.db`) so
`rsync --delete` never wipes it.

## References

- `references/architecture.md` — diagram, per-layer rationale, scaling, backups
  (Litestream → R2).
- `references/troubleshooting.md` — `SQLITE_BUSY` on build, missing
  `better-sqlite3` binding, Caddy cert failures, systemd not reading env,
  permission-denied on `/srv`.

## Scripts

- `scripts/provision.sh` — one-time server lockdown + install (template).
- `scripts/deploy.sh` — repeatable build-on-box deploy (template).

Both use `set -euo pipefail`, are commented, and have a clearly marked `CONFIG`
block at the top with placeholder values. Review and edit before running.
