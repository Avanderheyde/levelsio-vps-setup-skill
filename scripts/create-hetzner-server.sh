#!/usr/bin/env bash
#
# create-hetzner-server.sh — spin up a fresh Hetzner Cloud VPS, ready for
# provision.sh. Run this from YOUR computer.
#
# This creates the actual server so you don't have to click around the Hetzner
# console. After it finishes you'll have a bare Ubuntu box with your SSH key
# installed as root — exactly what provision.sh expects.
#
# PREREQUISITES (one time — see references/provision-hetzner.md):
#   1. The hcloud CLI installed:   brew install hcloud   (or download the binary)
#   2. hcloud authenticated with your Hetzner API token. The token is a SECRET
#      and is NEVER stored in this script. Authenticate with EITHER:
#         hcloud context create <name>      # paste token at the hidden prompt
#      or export it in your shell:
#         export HCLOUD_TOKEN=...           # not on a shared/logged machine
#
# Run a SECOND time (with a new SERVER_NAME) to add another server.
#
# This is a TEMPLATE. Review it and edit the CONFIG block before running.

set -euo pipefail

# ============================ CONFIG (EDIT ME) ==============================
SERVER_NAME="myapp"                         # name in Hetzner + this is just a label
SERVER_TYPE="cpx21"                         # 3 vCPU / 4 GB (~€8/mo). `hcloud server-type list`
LOCATION="nbg1"                             # nbg1/fsn1/hel1 (EU), ash/hil (US). `hcloud location list`
IMAGE="ubuntu-24.04"                        # `hcloud image list --type system`
SSH_KEY_PUB="${HOME}/.ssh/id_ed25519.pub"   # PUBLIC key to install as root on the box
SSH_KEY_NAME="${SERVER_NAME}-key"           # name for the key in your Hetzner project
# ===========================================================================

# --- Preflight ----------------------------------------------------------------
if ! command -v hcloud >/dev/null 2>&1; then
  echo "!! hcloud CLI not found. Install it: brew install hcloud" >&2
  echo "   (or see references/provision-hetzner.md)" >&2
  exit 1
fi
if ! hcloud server list >/dev/null 2>&1; then
  echo "!! hcloud is not authenticated. Create a token in the Hetzner Cloud" >&2
  echo "   Console (Security -> API Tokens, Read & Write), then run:" >&2
  echo "       hcloud context create ${SERVER_NAME}" >&2
  echo "   and paste the token at the hidden prompt." >&2
  exit 1
fi
if [[ ! -f "${SSH_KEY_PUB}" ]]; then
  echo "!! No public key at ${SSH_KEY_PUB}." >&2
  echo "   Generate one first (see the SSH keys section in SKILL.md):" >&2
  echo "       ssh-keygen -t ed25519 -f ${SSH_KEY_PUB%.pub} -N \"\"" >&2
  exit 1
fi

# Refuse to clobber an existing server of the same name.
if hcloud server describe "${SERVER_NAME}" >/dev/null 2>&1; then
  echo "!! A server named '${SERVER_NAME}' already exists. Pick a new SERVER_NAME" >&2
  echo "   (this is how you add a SECOND server) or delete the old one." >&2
  exit 1
fi

# --- 1. Upload the SSH key (idempotent) ---------------------------------------
if ! hcloud ssh-key describe "${SSH_KEY_NAME}" >/dev/null 2>&1; then
  hcloud ssh-key create --name "${SSH_KEY_NAME}" --public-key-from-file "${SSH_KEY_PUB}"
  echo ">> Uploaded SSH key '${SSH_KEY_NAME}'."
fi

# --- 2. Create the server -----------------------------------------------------
echo ">> Creating ${SERVER_NAME} (${SERVER_TYPE}, ${IMAGE}, ${LOCATION})..."
hcloud server create \
  --name "${SERVER_NAME}" \
  --type "${SERVER_TYPE}" \
  --image "${IMAGE}" \
  --location "${LOCATION}" \
  --ssh-key "${SSH_KEY_NAME}"

IP="$(hcloud server ip "${SERVER_NAME}")"

# --- Done ----------------------------------------------------------------------
cat <<EOF

================================================================================
 Server '${SERVER_NAME}' is up at ${IP}.
================================================================================
 Your SSH key is installed as root, so you can connect right away.

 Next steps:
 1. Edit scripts/provision.sh CONFIG (APP_NAME, DOMAIN, DEPLOY_USER, the same
    public key), then provision the box:
      scp scripts/provision.sh root@${IP}:/tmp/
      ssh root@${IP} 'bash /tmp/provision.sh'
 2. Then Tailscale lockdown + your chosen path (A deploy / B develop-on-VPS).
    See SKILL.md.

 To add ANOTHER server later: change SERVER_NAME (and DOMAIN in provision.sh)
 and run this script again.
================================================================================
EOF
