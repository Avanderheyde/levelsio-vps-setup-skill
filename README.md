# levelsio-vps-setup-skill

A [Claude Code Agent Skill](https://docs.claude.com/en/docs/claude-code/skills)
that teaches Claude how to deploy and operate a web app on **one cheap,
hardened VPS** — the "levels.io" way. No Kubernetes, no microservices, no
managed PaaS bill. One boring box runs the app, the database, TLS, and backups,
and you scale it vertically. Drop the skill into a project, point it at a fresh
server, and let it provision and deploy.

**Who it's for:** indie devs, "vibe coders", and bootstrapped founders who want
to ship a small-to-medium app for a flat ~$8/month instead of stacking managed
services — and are comfortable owning a bit of ops in exchange.

## What you get

- **App:** Next.js (App Router, `output: "standalone"`) or any Node app, as a
  single self-contained process.
- **Database:** SQLite via `better-sqlite3` with WAL mode + `busy_timeout` — one
  file on local disk, no DB server.
- **TLS / proxy:** Caddy with automatic HTTPS, reverse-proxying `localhost:3000`.
- **Process management:** a systemd unit with auto-restart on crash/reboot.
- **Edge (optional):** Cloudflare in front for DNS, origin hiding, WAF, caching.
- **Backups:** Litestream streaming the SQLite file to S3 / Cloudflare R2.
- **Security baked in:** non-root deploy user, key-only SSH, `ufw` firewall,
  `fail2ban`, unattended security upgrades, secrets in a `0640` env file owned by
  `root:deploy` — never in the repo, DB, or logs.

## What's in here

```
SKILL.md                      # the skill: stack, workflow, secrets rules
scripts/provision.sh          # one-time server lockdown + install (template)
scripts/deploy.sh             # repeatable build-on-box deploy (template)
references/architecture.md    # diagram, rationale, scaling, backups (Litestream→R2)
references/troubleshooting.md # SQLITE_BUSY, native bindings, Caddy, systemd, perms
LICENSE                       # MIT
```

The scripts are **templates**: review them, edit the `CONFIG` block at the top
(placeholder hostnames/paths), then run. They use `set -euo pipefail` and are
commented throughout.

## Quickstart

### 1. Install the skill

Copy this folder into a Claude Code project's skills directory:

```bash
git clone https://github.com/Avanderheyde/levelsio-vps-setup-skill
mkdir -p your-project/.claude/skills
cp -r levelsio-vps-setup-skill your-project/.claude/skills/levelsio-vps-deploy
```

Claude Code auto-discovers skills under `.claude/skills/`. (User-level skills
under `~/.claude/skills/` work too.) Once installed, ask Claude something like
"deploy this app to a Hetzner VPS the levels.io way" and it will load the skill.

### 2. Provision (once per server)

On a fresh Ubuntu 24.04 box, with `scripts/provision.sh` edited:

```bash
scp scripts/provision.sh root@SERVER_IP:/tmp/
ssh root@SERVER_IP 'bash /tmp/provision.sh'
```

This hardens SSH, sets up the firewall, installs Node + Caddy, creates the app
directories and secrets file, and writes the Caddyfile and systemd unit. Then
generate secrets **server-side** (`openssl rand -base64 32`) into
`/etc/<app>/env`.

### 3. Deploy (every release)

From your dev machine, with `scripts/deploy.sh` edited:

```bash
./scripts/deploy.sh
```

It rsyncs your tree to the box, runs `npm ci && npm run build` **on the server**
(so `better-sqlite3` compiles for the server's ABI), assembles the standalone
bundle, swaps it into place, restarts the service, and health-checks the domain.

## Cost comparison

Worked example for a single small/medium app (web app + database + storage +
modest bandwidth). PaaS overage figures are illustrative of what teams commonly
hit at modest scale, not exact quotes.

| | VPS (Hetzner CPX21) | Supabase Pro + Vercel Pro |
|---|---|---|
| Base / month | **~$8 flat** | $25 (Supabase) + $20 (Vercel) = **$45** |
| Includes | App + SQLite/Postgres + storage + bandwidth, on one box | Managed Postgres + managed hosting + included quotas |
| Typical real monthly | **~$8** (flat; you add ~$0–5 for R2 backups) | **$60–150+** once bandwidth, function invocations, DB compute, extra seats/projects exceed included quotas |
| Annual (typical) | **~$96–160** | **~$720–1,800+** |
| Who runs ops | You (provisioning, backups, upgrades — automated here) | The provider (managed, autoscaling) |

**Tradeoffs — be honest:** the VPS is cheap and predictable, but *you* own the
box: backups, security updates, and the 3am page if it falls over (this skill
automates most of that, but it's still yours). Supabase + Vercel cost several
times more and meter usage, but they're fully managed, autoscale, give you
global edge and preview deploys, and there's no server for you to babysit. Pick
the VPS when you want low, flat cost and don't mind light ops; pick the PaaS when
you'd rather pay to never think about servers. Neither is "right" — it's a
budget-vs-ops trade.

## Sources / inspiration

The single-server philosophy here is inspired by **[@levelsio](https://x.com/levelsio)**,
who has long argued for running profitable products on one big, boring server.
The gist, paraphrased (not exact quotes): **one big server, boring well-understood
tech, SQLite over managed databases, scale vertically before you distribute, and
ship fast.** These posts are cited as inspiration:

- <https://x.com/levelsio/status/2052734824541016107>
- <https://x.com/levelsio/status/2054172213289398743>
- <https://x.com/levelsio/status/2057933239600263582>
- <https://x.com/levelsio/status/2033546675063554213>

## Disclaimer

Not affiliated with, endorsed by, or sponsored by levels.io / Pieter Levels.
This is an independent skill that packages a deployment method inspired by his
publicly shared philosophy. "levels.io" is referenced only to credit that
inspiration.

## License

[MIT](./LICENSE) © 2026 Avanderheyde
