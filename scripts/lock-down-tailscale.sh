#!/usr/bin/env bash
#
# lock-down-tailscale.sh — restrict the box to the tailnet (the levels.io way).
#
# Run this ON THE BOX, as root, ONLY AFTER:
#   1. `sudo tailscale up` has put this box on your Tailscale network, and
#   2. you have confirmed you can SSH in over the tailnet:
#        ssh deploy@<100.x.y.z>     # the box's `tailscale ip -4` address
#
# What it does:
#   - Restricts SSH (port 22) to the Tailscale interface only, then removes the
#     public "allow 22" rule. After this, the box is invisible to SSH on the
#     public internet — you can only reach it over your tailnet.
#   - Optionally restricts HTTPS (443) to Cloudflare's published IP ranges, so
#     only Cloudflare can reach your origin (set CLOUDFLARE_ONLY_443="true").
#
# This is the single biggest security win for a single-box setup, and it's what
# levels.io does: "install Tailscale and lock down the firewall to only accept
# web traffic on 443 for Cloudflare IPs and SSH 22 for the Tailscale IP."
#
# SAFETY: this script refuses to lock SSH unless tailscaled is running with an
# IP, and it makes you confirm you are currently connected over the tailnet.
# If you lock yourself out anyway, use your cloud provider's web console / VNC to
# run `ufw allow 22/tcp` (see references/troubleshooting.md).

set -euo pipefail

# ============================ CONFIG (EDIT ME) ==============================
TS_IFACE="tailscale0"                   # Tailscale's network interface name
CLOUDFLARE_ONLY_443="false"             # "true" => only Cloudflare IPs may hit 443
CLOSE_PORT_80="false"                   # "true" => also close 80 (only if NOT using
                                        #   HTTP-01 ACME; needs Cloudflare proxy +
                                        #   DNS/TLS-ALPN cert issuance instead)
# ===========================================================================

if [[ "$(id -u)" -ne 0 ]]; then
  echo "!! Must run as root." >&2
  exit 1
fi

# --- 1. Verify Tailscale is actually up ---------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  echo "!! tailscale is not installed. Run provision.sh first, then 'sudo tailscale up'." >&2
  exit 1
fi
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -z "${TS_IP}" ]]; then
  echo "!! This box has no Tailscale IPv4 address. Run 'sudo tailscale up' first." >&2
  exit 1
fi
if ! ip link show "${TS_IFACE}" >/dev/null 2>&1; then
  echo "!! Interface ${TS_IFACE} not found. Is Tailscale connected? (tailscale status)" >&2
  exit 1
fi
echo ">> Tailscale is up. This box's tailnet IP is ${TS_IP}."

# --- 2. Confirm you're connected over the tailnet (anti-lockout) --------------
echo
echo "   You are about to close SSH on the PUBLIC internet. After this you can"
echo "   ONLY reach this box over Tailscale. Make sure you are CURRENTLY SSH'd in"
echo "   via the tailnet (e.g. you ran: ssh ${SUDO_USER:-deploy}@${TS_IP})."
echo
read -r -p "   Are you connected over the tailnet right now? [yes/NO] " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "!! Aborted. Reconnect over the tailnet, then re-run." >&2
  exit 1
fi

# --- 3. Restrict SSH to the tailnet interface ---------------------------------
# Allow 22 only on the Tailscale interface, THEN remove the public allow rule.
ufw allow in on "${TS_IFACE}" to any port 22 proto tcp
ufw delete allow 22/tcp || true
echo ">> SSH (22) now restricted to ${TS_IFACE} only."

# --- 4. Optionally restrict 443 to Cloudflare IP ranges -----------------------
if [[ "${CLOUDFLARE_ONLY_443}" == "true" ]]; then
  echo ">> Restricting 443 to Cloudflare IP ranges..."
  CF_V4="$(curl -fsSL https://www.cloudflare.com/ips-v4)"
  CF_V6="$(curl -fsSL https://www.cloudflare.com/ips-v6)"
  if [[ -z "${CF_V4}" ]]; then
    echo "!! Could not fetch Cloudflare IPs; leaving 443 as-is." >&2
  else
    while read -r cidr; do
      [[ -n "${cidr}" ]] && ufw allow from "${cidr}" to any port 443 proto tcp
    done <<< "${CF_V4}"
    while read -r cidr; do
      [[ -n "${cidr}" ]] && ufw allow from "${cidr}" to any port 443 proto tcp
    done <<< "${CF_V6}"
    ufw delete allow 443/tcp || true
    echo ">> 443 now restricted to Cloudflare ranges."
    echo "   (Cloudflare rotates these occasionally — re-run to refresh.)"
  fi
fi

# --- 5. Optionally close port 80 ----------------------------------------------
if [[ "${CLOSE_PORT_80}" == "true" ]]; then
  echo ">> Closing port 80. Caddy must NOT use the HTTP-01 ACME challenge now."
  echo "   Ensure Cloudflare proxy is on and Caddy uses DNS or TLS-ALPN issuance."
  ufw delete allow 80/tcp || true
fi

ufw reload
echo
echo "================================================================================"
echo " Lockdown complete. Current firewall:"
ufw status verbose
echo "================================================================================"
echo " From now on, SSH only works over Tailscale:  ssh <user>@${TS_IP}"
echo " Locked out? Use your provider's web console to run: ufw allow 22/tcp"
echo "================================================================================"
