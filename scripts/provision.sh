#!/usr/bin/env bash
#
# provision.sh — one-time provisioning for a single-VPS deploy (levels.io method).
#
# Run this ONCE on a fresh Ubuntu 24.04 LTS box, as root:
#     scp scripts/provision.sh root@SERVER_IP:/tmp/
#     ssh root@SERVER_IP 'bash /tmp/provision.sh'
#
# This is a TEMPLATE. Review every line and edit the CONFIG block below before
# running. It hardens the box, installs Node + Caddy, creates app directories,
# a secrets file, a Caddyfile, and a systemd unit.
#
# It does NOT write any secrets. Generate those server-side afterwards (see the
# "next steps" printed at the end).

set -euo pipefail

# ============================ CONFIG (EDIT ME) ==============================
APP_NAME="myapp"                       # lowercase, no spaces — used in all paths
DOMAIN="example.com"                   # the domain Caddy will serve + get TLS for
DEPLOY_USER="deploy"                   # non-root user that owns + runs the app
# Paste the PUBLIC SSH key (one line) that should be able to log in as DEPLOY_USER.
# Leave empty ONLY if the key is already present; the script will refuse to lock
# down SSH if no key is installed (so you don't lock yourself out).
DEPLOY_SSH_PUBKEY="ssh-ed25519 AAAA... you@laptop"
NODE_MAJOR="22"                        # Node LTS major version
# ===========================================================================

echo ">> Provisioning ${APP_NAME} on ${DOMAIN} (deploy user: ${DEPLOY_USER})"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "!! Must run as root." >&2
  exit 1
fi

# --- 1. System packages --------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban unattended-upgrades git rsync

# --- 2. Non-root deploy user ---------------------------------------------------
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
fi
usermod -aG sudo "${DEPLOY_USER}"

# Install the SSH key for the deploy user (if provided).
if [[ -n "${DEPLOY_SSH_PUBKEY}" && "${DEPLOY_SSH_PUBKEY}" != "ssh-ed25519 AAAA... you@laptop" ]]; then
  install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
  echo "${DEPLOY_SSH_PUBKEY}" > "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

# Refuse to harden SSH if the deploy user has no authorized key (avoid lockout).
if [[ ! -s "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]]; then
  echo "!! ${DEPLOY_USER} has no authorized_keys — set DEPLOY_SSH_PUBKEY first." >&2
  echo "!! Refusing to disable password SSH to avoid locking you out." >&2
  exit 1
fi

# Passwordless sudo for the deploy user (so deploys don't prompt).
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/90-${DEPLOY_USER}"

# --- 3. Harden SSH -------------------------------------------------------------
SSHD=/etc/ssh/sshd_config.d/99-hardening.conf
cat > "${SSHD}" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
systemctl reload ssh || systemctl reload sshd || true

# --- 4. Firewall ---------------------------------------------------------------
# Port 22 is left open to the world HERE on purpose: you're connected over the
# public IP right now, and slamming it shut mid-provision would lock you out.
# Once Tailscale is up and you've confirmed tailnet SSH works, run
# scripts/lock-down-tailscale.sh to restrict 22 to the tailnet (the levels.io way).
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     # SSH (locked to tailnet later by lock-down-tailscale.sh)
ufw allow 80/tcp     # HTTP (Caddy ACME + redirect)
ufw allow 443/tcp    # HTTPS
ufw --force enable

# --- 5. Automatic security updates --------------------------------------------
dpkg-reconfigure -f noninteractive unattended-upgrades || true
systemctl enable --now unattended-upgrades || true

# --- 6. fail2ban (brute-force protection on SSH) -------------------------------
systemctl enable --now fail2ban

# --- 6b. Tailscale -------------------------------------------------------------
# Installs the Tailscale daemon. This does NOT bring the box onto your tailnet —
# that step (`sudo tailscale up`) is interactive (it prints an auth link) and is
# left for you to run AFTER provisioning, so a bad config can't lock you out.
# Once the box is on your tailnet, run scripts/lock-down-tailscale.sh to restrict
# SSH (port 22) to the tailnet only — the way levels.io secures a box.
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# --- 7. Node LTS ---------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
node --version

# --- 8. Caddy ------------------------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

# --- 9. App directories --------------------------------------------------------
#   /srv/<app>         -> live app (deploy target)
#   /srv/<app>-build   -> build workspace (npm ci / npm run build happen here)
#   /var/lib/<app>     -> persistent data (the SQLite file lives here)
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/srv/${APP_NAME}"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/srv/${APP_NAME}-build"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/var/lib/${APP_NAME}"

# --- 10. Secrets file ----------------------------------------------------------
# Owned root:deploy, mode 0640 — readable by the deploy user, never world-readable.
# DO NOT put secrets in the repo. Fill this in server-side (see next steps).
install -d -m 750 -o root -g "${DEPLOY_USER}" "/etc/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}/env"
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<EOF
# Environment for ${APP_NAME}. Loaded by systemd (EnvironmentFile) and deploys.
# Add secrets here ONLY on the server. Never commit this file.
NODE_ENV=production
PORT=3000
DATABASE_PATH=/var/lib/${APP_NAME}/data.db
# Generated server-side, e.g.:  echo "SESSION_SECRET=\$(openssl rand -base64 32)" >> ${ENV_FILE}
EOF
fi
chown root:"${DEPLOY_USER}" "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

# --- 11. Caddyfile -------------------------------------------------------------
# Automatic HTTPS. Caddy obtains + renews the cert for DOMAIN automatically.
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}
EOF
systemctl enable caddy
systemctl restart caddy

# --- 12. systemd unit ----------------------------------------------------------
# Runs the standalone Next.js server as the deploy user, restarts on failure,
# loads secrets from the env file.
cat > "/etc/systemd/system/${APP_NAME}.service" <<EOF
[Unit]
Description=${APP_NAME} (Next.js standalone)
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=/srv/${APP_NAME}
EnvironmentFile=/etc/${APP_NAME}/env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=2
# Hardening
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/var/lib/${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${APP_NAME}.service"
# Don't start yet — there's no app deployed. The first deploy.sh run will start it.

# --- Done ----------------------------------------------------------------------
cat <<EOF

================================================================================
 Provisioning complete for ${APP_NAME}.
================================================================================
 Next steps:

 1. Generate app secrets SERVER-SIDE (never in the repo). For each one:
      ssh ${DEPLOY_USER}@${DOMAIN}
      echo "SESSION_SECRET=\$(openssl rand -base64 32)" | sudo tee -a /etc/${APP_NAME}/env >/dev/null

 2. Transfer third-party creds OUT-OF-BAND (never echo them on the cmdline):
      scp secret.txt ${DEPLOY_USER}@${DOMAIN}:/tmp/
      ssh ${DEPLOY_USER}@${DOMAIN}
      cat /tmp/secret.txt | sudo tee -a /etc/${APP_NAME}/env >/dev/null
      shred -u /tmp/secret.txt

 3. Point DNS: an A record for ${DOMAIN} -> this server's IP.
    (If using Cloudflare, you can proxy it once the origin is up.)

 4. Bring this box onto your Tailscale network (recommended — the levels.io way):
      sudo tailscale up           # follow the printed auth link to log in
      tailscale ip -4             # note the 100.x.y.z tailnet address
    Then, AFTER you've confirmed you can SSH over the tailnet
    (ssh ${DEPLOY_USER}@<100.x.y.z>), lock SSH to the tailnet only:
      bash scripts/lock-down-tailscale.sh
    See references/security-tailscale.md.

 5. Choose your workflow:
    - Path A (host only): from your dev machine, edit + run scripts/deploy.sh.
    - Path B (develop ON the VPS, the levels.io way): run
        bash scripts/setup-dev-on-vps.sh
      then connect with Termius + tmux. See references/develop-on-vps.md.
================================================================================
EOF
