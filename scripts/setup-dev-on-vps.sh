#!/usr/bin/env bash
#
# setup-dev-on-vps.sh — Path B: develop ON the VPS, the levels.io way.
#
# Run this ON THE BOX after provision.sh. It sets up everything you need to do
# your actual coding on the server with Claude Code, in tmux sessions that
# survive disconnects — so Claude "keeps going all night while you sleep" and
# you can reattach from your laptop or your phone (via Termius) at any time.
#
# What it does, for DEPLOY_USER:
#   1. Installs tmux.
#   2. Installs Claude Code globally (npm i -g @anthropic-ai/claude-code).
#   3. Adds the `tm` tmux helper + auto-attach-on-login to ~/.bashrc, so one
#      session is created/attached per directory (one per site).
#   4. Prints how to log Claude Code in, and how to connect from Termius.
#
# This is a TEMPLATE. Review it and edit the CONFIG block before running.
# Connection details + the full workflow: references/develop-on-vps.md
# The tmux helper, standalone: references/remote-claude-code-tmux.md

set -euo pipefail

# ============================ CONFIG (EDIT ME) ==============================
DEPLOY_USER="deploy"                    # the user you develop as (must match provision.sh)
# ===========================================================================

if [[ "$(id -u)" -ne 0 ]]; then
  echo "!! Run as root (it installs global packages and edits ${DEPLOY_USER}'s ~/.bashrc)." >&2
  exit 1
fi
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "!! User ${DEPLOY_USER} does not exist. Run provision.sh first." >&2
  exit 1
fi

USER_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
BASHRC="${USER_HOME}/.bashrc"

# --- 1. tmux -------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y tmux

# --- 2. Claude Code (global) ---------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "!! Node is not installed. Run provision.sh first." >&2
  exit 1
fi
npm install -g @anthropic-ai/claude-code
echo ">> Claude Code installed: $(claude --version 2>/dev/null || echo 'run `claude` to start')"

# --- 3. tmux helper + auto-attach in ~/.bashrc ---------------------------------
# Idempotent: only append if our marker isn't already present.
MARKER="# >>> levelsio-vps tmux helper >>>"
if ! grep -qF "${MARKER}" "${BASHRC}" 2>/dev/null; then
  cat >> "${BASHRC}" <<'EOF'

# >>> levelsio-vps tmux helper >>>
# tmux session per folder. `tm` (no args) attaches to / creates a session
# named after the current dir's basename. `tm name` overrides the name.
# Works whether already inside tmux (uses switch-client) or outside it.
tm() {
  command -v tmux >/dev/null 2>&1 || { echo "tmux not installed"; return 1; }
  local name="${1:-$(basename "$PWD")}"
  # tmux session names can't contain '.' or ':' — replace with '-'
  name="${name//./-}"
  name="${name//:/-}"
  if [ -n "$TMUX" ]; then
    tmux has-session -t "$name" 2>/dev/null || tmux new-session -d -s "$name" -c "$PWD"
    tmux switch-client -t "$name"
  else
    tmux attach -t "$name" 2>/dev/null || tmux new -s "$name" -c "$PWD"
  fi
}

# Auto-attach on interactive login: picks a session named after wherever you
# land. Plain `ssh server` lands in $HOME -> session "<user>". Use
# `ssh server -t "cd /srv/sm.levels.io && bash -l"` to land in a site folder ->
# session "sm-levels-io". Skips inside tmux and non-interactive shells so
# scp/rsync/scripted ssh keep working.
if command -v tmux >/dev/null 2>&1 && [ -z "$TMUX" ] && [[ $- == *i* ]]; then
  tm
fi
# <<< levelsio-vps tmux helper <<<
EOF
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "${BASHRC}"
  echo ">> Added tm() + auto-attach to ${BASHRC}"
else
  echo ">> tmux helper already present in ${BASHRC} (skipped)"
fi

# --- Done ----------------------------------------------------------------------
cat <<EOF

================================================================================
 Path B ready: develop on the VPS with Claude Code in tmux.
================================================================================
 1. Log in to Claude Code (as ${DEPLOY_USER}, inside a session):
      su - ${DEPLOY_USER}
      cd /srv/<your-app>          # your code lives here; clone your repo if needed
      claude                      # then /login — pick API key OR the browser-link
                                  # flow (open the link on any device, paste the
                                  # code back into the terminal).

 2. Connect from Termius (laptop AND phone) over Tailscale:
      Host:    <this box's tailnet IP>  (tailscale ip -4)
      User:    ${DEPLOY_USER}
      On connect, run a startup snippet so you land in the right session:
          cd /srv/<your-app> && tm

 3. Detach any time with  Ctrl-b d  — Claude keeps running on the box.
    Reattach from any device by reconnecting (auto-attach) or running  tm.

 Full workflow + remote control from the Claude app: references/develop-on-vps.md
================================================================================
EOF
