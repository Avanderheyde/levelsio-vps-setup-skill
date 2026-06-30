# levelsio-vps-setup-skill

A [Claude Code Agent Skill](https://docs.claude.com/en/docs/claude-code/skills)
that teaches Claude how to set up a web app on **one cheap, hardened VPS** — the
"levels.io" way. No Kubernetes, no microservices, no managed PaaS bill. One
boring box runs the app, the database, TLS, and backups, and you scale it
vertically.

It offers **two workflows you pick between**:

- **Path A — host only:** develop on your own computer, deploy to the VPS for
  cheap hosting (`rsync` + build-on-box).
- **Path B — develop *on* the VPS (the full levels.io way):** your code lives on
  the box, Claude Code runs in **tmux** (so it keeps working while you're away),
  and you connect from your **laptop or your phone** via **Termius over
  Tailscale**. Edits are basically already live. This is how levels.io actually
  works — "coding almost solely on my VPS with Claude Code."

Both share the same hardened foundation, with **Tailscale** locking SSH to a
private network so the box is invisible to the public internet.

**Who it's for:** indie devs, "vibe coders", and bootstrapped founders who want
to ship a small-to-medium app for a flat ~$8/month instead of stacking managed
services — and want a cheap, always-on machine they can develop on from anywhere.

## What you get

- **App:** Next.js (App Router, `output: "standalone"`) or any Node app, as a
  single self-contained process.
- **Database:** SQLite via `better-sqlite3` with WAL mode + `busy_timeout` — one
  file on local disk, no DB server.
- **TLS / proxy:** Caddy with automatic HTTPS, reverse-proxying `localhost:3000`.
- **Process management:** a systemd unit with auto-restart on crash/reboot.
- **Network / SSH:** **Tailscale** — SSH locked to a private tailnet, so port 22
  is invisible on the public internet and you can connect from laptop or phone.
- **On-VPS development (Path B):** Claude Code + **tmux** with a "one session per
  folder" helper, so Claude survives disconnects and you reattach from any device
  via **Termius**.
- **Edge (optional):** Cloudflare in front for DNS, origin hiding, WAF, caching.
- **Backups:** Litestream streaming the SQLite file to S3 / Cloudflare R2.
- **Security baked in:** non-root deploy user, key-only SSH, `ufw` firewall (SSH
  restricted to the tailnet), `fail2ban`, unattended security upgrades, secrets in
  a `0640` env file owned by `root:deploy` — never in the repo, DB, or logs.

## What's in here

```
SKILL.md                                # the skill: pick-a-path front door, stack, secrets
scripts/create-hetzner-server.sh        # create the VPS itself via the hcloud CLI
scripts/provision.sh                    # one-time server lockdown + install, incl. Tailscale
scripts/lock-down-tailscale.sh          # restrict SSH to the tailnet (+ optional CF-only 443)
scripts/setup-dev-on-vps.sh             # Path B: install Claude Code + tmux + tm helper
scripts/deploy.sh                       # Path A: repeatable build-on-box deploy
references/provision-hetzner.md         # create the server: hcloud, API token, 1st + Nth box
references/architecture.md              # hosting diagram, rationale, scaling, backups
references/security-tailscale.md        # Tailscale lockdown, lockout-safe ordering, recovery
references/develop-on-vps.md            # Path B end to end: Termius, Claude login, live edit
references/remote-claude-code-tmux.md   # the tmux/persistent-Claude module (standalone-ready)
references/troubleshooting.md           # SQLITE_BUSY, bindings, Caddy, systemd, tmux, lockout
LICENSE                                 # MIT
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

### 1.5. No server yet? Create one (optional)

If you don't already have a VPS, Claude can spin one up for you with Hetzner's
`hcloud` CLI — no console clicking. One time: create a Hetzner **API token**
(Cloud Console → Security → API Tokens, Read & Write), install the CLI
(`brew install hcloud`), and authenticate yourself so the token stays private:

```bash
! hcloud context create personal-apps     # paste the token at the hidden prompt
```

Then edit + run the create script (or just ask Claude to "create a Hetzner server
for my app"):

```bash
bash scripts/create-hetzner-server.sh      # makes the box, installs your key, prints the IP
```

This gives you a bare Ubuntu box with root SSH, ready for the next step. Adding a
second server later is the same script with a new `SERVER_NAME`. Full detail (incl.
a DigitalOcean alternative) in `references/provision-hetzner.md`. Already have a
box? Skip to step 2.

### 2. Provision + secure (once per server, both paths)

On a fresh Ubuntu 24.04 box, with `scripts/provision.sh` edited:

```bash
scp scripts/provision.sh root@SERVER_IP:/tmp/
ssh root@SERVER_IP 'bash /tmp/provision.sh'
```

This hardens SSH, sets up the firewall, installs Tailscale + Node + Caddy, creates
the app directories and secrets file, and writes the Caddyfile and systemd unit.
Then generate secrets **server-side** (`openssl rand -base64 32`) into
`/etc/<app>/env`.

Lock SSH to your private network (the levels.io way — order matters to avoid a
lockout, see `references/security-tailscale.md`):

```bash
sudo tailscale up            # on the box; follow the auth link
# confirm `ssh deploy@<tailnet-ip>` works, THEN:
bash scripts/lock-down-tailscale.sh
```

### 3a. Path A — deploy from your computer (every release)

From your dev machine, with `scripts/deploy.sh` edited:

```bash
./scripts/deploy.sh
```

It rsyncs your tree to the box, runs `npm ci && npm run build` **on the server**
(so `better-sqlite3` compiles for the server's ABI), assembles the standalone
bundle, swaps it into place, restarts the service, and health-checks the domain.

### 3b. Path B — develop on the VPS (the levels.io way)

This is the "code on the server from anywhere, even your phone" workflow. Follow
these steps in order — they're written so a first-timer can't get lost. (Deeper
detail + screenshots-in-words in `references/develop-on-vps.md`.)

**Step 1 — Install the dev tools on the box (one time).** While you're still
SSH'd into the server from step 2:

```bash
bash scripts/setup-dev-on-vps.sh    # installs Claude Code + tmux + the `tm` helper
```

**Step 2 — Get Tailscale on BOTH ends.** You already ran `tailscale up` on the
VPS. Now install the **Tailscale app on the device you'll code from** — your
laptop, *and/or* your phone — and log into the **same Tailscale account**. That
puts your device and the VPS on the same private network. Find the VPS's address
with `tailscale ip -4` on the box (it looks like `100.x.y.z`). That address is how
you'll reach the box from anywhere, even on cellular.

> Why this matters: after the lockdown in step 2, the box only accepts SSH over
> Tailscale. No Tailscale on your device = no way in. Set it up on every device
> you want to code from.

**Step 3 — Connect with an SSH app.** Use **[Termius](https://termius.com)** (free,
works on iPhone, Android, Mac, Windows — what levels uses) or any SSH client.
Install it on whatever device you want to code from.

First you need an **SSH key** on that device that the box trusts. You don't have to
do this by hand — **ask Claude (with this skill) to "set up my SSH key and install
it on the box"** and it will generate the key and place it for you. The manual
version, for reference:

The box only lets in keys you've added to the `deploy` user — provisioning added
your laptop's key, so:

- **On your laptop** (the key you provisioned with): you're already trusted. In
  Termius desktop, just point the host at your existing
  `~/.ssh/id_ed25519`, or let Termius import it. Done.

- **On a new device, like your phone:** it has no key yet, so add one. In the
  Termius app: **Keychain → New Key → Generate** (ed25519), then open the key and
  **copy its *public* key**. Now add that public key to the box. The simplest way
  is from a device that already gets in (your laptop), in one line:

  ```bash
  # on the box (paste your phone's PUBLIC key in the quotes):
  echo "ssh-ed25519 AAAA...your-phone-key... phone" >> ~/.ssh/authorized_keys
  ```

  (If you can't get in from anywhere yet, use your cloud provider's web console —
  Hetzner Cloud Console / DigitalOcean Droplet Console — to run that line.) That's
  it — your phone is now trusted, no need to copy any private key around.

Then create the connection (Termius calls it a "Host"):

- **Address / Host:** the VPS's tailnet IP from step 2 (`100.x.y.z`)
- **Username:** `deploy` (your deploy user)
- **Key:** the key for *this* device (your laptop key, or the one you generated on
  the phone)
- **Run on connect (optional but recommended):** `cd /srv/<app> && tm`
- **Keep-alive / auto-reconnect:** turn it on, so flaky phone connections silently
  re-establish.

Tap connect. You're now on the server — from your phone or laptop.

**Step 4 — Start Claude Code.** In the session (if you didn't set the "run on
connect" command, do this manually):

```bash
cd /srv/<app>     # your project folder; clone your repo here if it's not already
tm                # opens/attaches a tmux session named after the folder
claude            # starts Claude Code
```

**Step 5 — Log Claude in.** Inside Claude, type:

```
/login
```

There's no browser on the server, so pick the **browser-link flow**: Claude prints
a link and a code. Open the link **on any device** (your phone's browser is fine),
log into your Claude account, then **copy the code and paste it back** into the
terminal. (Or paste an Anthropic API key instead.) You only do this once.

**Step 6 — Code, and walk away.** Tell Claude what to build or fix. It edits the
files that are actually serving your site. When you want to leave, **detach** with
`Ctrl-b` then `d` — Claude keeps running on the box "all night while you sleep."
Reconnect later from *any* device (Termius again, phone or laptop) and you're
right back where you left off, with Claude still going.

**Step 7 (optional) — Remote-control from the Claude app.** Because Claude lives
in a tmux session that never dies, you can also drive it from the **Claude
mobile/desktop app's remote session** instead of typing in a terminal — handy on a
phone. See `references/remote-claude-code-tmux.md`.

That's the whole loop: **Tailscale on both ends → SSH in with Termius → `tm` →
`claude` → `/login` → build → `Ctrl-b d` to leave it running.** One cheap box you
develop on from anywhere.

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

The single-server philosophy and the develop-on-the-VPS workflow here are inspired
by **[@levelsio](https://x.com/levelsio)**, who runs profitable products on one
big, boring server and codes "almost solely on my VPS with Claude Code." The gist,
paraphrased (not exact quotes): **one big server, boring well-understood tech,
SQLite over managed databases, scale vertically before you distribute, develop on
the box itself with Claude Code in tmux, connect from anywhere over Tailscale, and
ship fast.** Cited as inspiration:

- One big server / boring tech / vertical scaling:
  <https://x.com/levelsio/status/2052734824541016107>,
  <https://x.com/levelsio/status/2054172213289398743>,
  <https://x.com/levelsio/status/2057933239600263582>
- Tailscale-first security / lock SSH to the tailnet:
  <https://x.com/levelsio/status/2033546675063554213>,
  <https://x.com/levelsio/status/1953440287163887639>
- Develop on the VPS with Claude Code, switch between laptop and phone:
  <https://x.com/levelsio/status/2071162399864889705>,
  <https://x.com/levelsio/status/1953022273595506910>
- Long-form writeups of his setup:
  [daily laptop + iPhone VPS Claude Code setup](https://levels.io/daily-laptop-iphone-vps-claude-code-setup),
  [Termius + tmux per site](https://levels.io/latest-termius-tmux-setup-per-site)

## Disclaimer

Not affiliated with, endorsed by, or sponsored by levels.io / Pieter Levels.
This is an independent skill that packages a deployment method inspired by his
publicly shared philosophy. "levels.io" is referenced only to credit that
inspiration.

## License

[MIT](./LICENSE) © 2026 Avanderheyde
