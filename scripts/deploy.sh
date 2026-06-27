#!/usr/bin/env bash
#
# deploy.sh — repeatable deploy for a single-VPS app (levels.io method).
#
# Run this from your DEV MACHINE, from the root of your app's working tree.
#
# The key idea: BUILD ON THE BOX. Native modules like better-sqlite3 compile
# against the server's libc/Node ABI. Building locally and shipping node_modules
# breaks at runtime; building on the server makes the bindings match.
#
# This is a TEMPLATE. Review every line and edit the CONFIG block below.
#
# Assumes provision.sh has already run on the server, and the app's
# next.config.* sets `output: "standalone"`.

set -euo pipefail

# ============================ CONFIG (EDIT ME) ==============================
SSH_HOST="deploy@example.com"          # user@host you deploy as (the deploy user)
SSH_KEY="${HOME}/.ssh/id_ed25519"      # private key for that user
APP_NAME="myapp"                       # must match provision.sh
RUN_MIGRATIONS="false"                 # "true" to run drizzle-kit migrate (optional/tool-specific)
# ===========================================================================

BUILD_DIR="/srv/${APP_NAME}-build"
LIVE_DIR="/srv/${APP_NAME}"
ENV_FILE="/etc/${APP_NAME}/env"
SSH=(ssh -i "${SSH_KEY}" "${SSH_HOST}")
RSYNC_SSH="ssh -i ${SSH_KEY}"

echo ">> Deploying ${APP_NAME} to ${SSH_HOST}"

# --- 1. Ship the working tree to the build dir --------------------------------
# Exclude anything that must be built/owned on the server or that holds data.
rsync -az --delete \
  -e "${RSYNC_SSH}" \
  --exclude 'node_modules' \
  --exclude '.next' \
  --exclude '.git' \
  --exclude 'data.db*' \
  --exclude '.env*' \
  ./ "${SSH_HOST}:${BUILD_DIR}/"

# --- 2. Build on the box -------------------------------------------------------
# Load secrets, install deps cleanly, build. better-sqlite3 compiles here.
"${SSH[@]}" bash -seuo pipefail <<EOF
  set -a; source "${ENV_FILE}"; set +a
  cd "${BUILD_DIR}"
  npm ci
  npm run build
EOF

# --- 3. Migrations (optional, tool-specific) -----------------------------------
if [[ "${RUN_MIGRATIONS}" == "true" ]]; then
  echo ">> Applying DB migrations"
  "${SSH[@]}" bash -seuo pipefail <<EOF
    set -a; source "${ENV_FILE}"; set +a
    cd "${BUILD_DIR}"
    npx drizzle-kit migrate
EOF
fi

# --- 4. Assemble the standalone bundle -----------------------------------------
# Next.js standalone output omits static assets and public/; copy them in.
# Also make sure the better-sqlite3 native binding is present under standalone.
"${SSH[@]}" bash -seuo pipefail <<EOF
  cd "${BUILD_DIR}"
  cp -r .next/static .next/standalone/.next/static
  if [[ -d public ]]; then cp -r public .next/standalone/public; fi

  # Ensure the better-sqlite3 .node binding made it into the standalone tree.
  BINDING=\$(find node_modules/better-sqlite3 -name '*.node' | head -n1 || true)
  if [[ -n "\${BINDING}" ]]; then
    DEST=".next/standalone/\$(dirname "\${BINDING}")"
    mkdir -p "\${DEST}"
    cp "\${BINDING}" "\${DEST}/"
  fi
EOF

# --- 5. Swap the new build into the live dir -----------------------------------
# rsync --delete keeps the live dir clean, but never touch the DB file.
"${SSH[@]}" bash -seuo pipefail <<EOF
  rsync -a --delete \
    --exclude 'data.db*' \
    "${BUILD_DIR}/.next/standalone/" "${LIVE_DIR}/"
EOF

# --- 6. Restart + verify -------------------------------------------------------
"${SSH[@]}" bash -seuo pipefail <<EOF
  sudo systemctl restart "${APP_NAME}"
  sleep 1
  systemctl is-active "${APP_NAME}"
EOF

# Health check against the public domain.
DOMAIN="${SSH_HOST#*@}"
echo ">> Health check: https://${DOMAIN}"
if curl -fsS --max-time 15 "https://${DOMAIN}" >/dev/null; then
  echo ">> Deploy OK."
else
  echo "!! Health check failed. Check: ssh ${SSH_HOST} 'journalctl -u ${APP_NAME} -n 50 --no-pager'" >&2
  exit 1
fi
