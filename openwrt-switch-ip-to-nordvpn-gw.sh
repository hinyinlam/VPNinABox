#!/usr/bin/env bash
# openwrt-switch-ip-to-nordvpn-gw.sh — policy-route a LAN source IP through a
# chosen NordVPN gateway on OpenWRT, without affecting other LAN clients.
#
# Mechanism: ip rule (policy routing) — traffic from <source-ip> uses a
# dedicated routing table (200) whose default route points at the NordVPN LXC.
# All other LAN traffic keeps its normal default gateway unchanged.
#
# Usage:
#   ./openwrt-switch-ip-to-nordvpn-gw.sh              # interactive
#   ./openwrt-switch-ip-to-nordvpn-gw.sh --list       # show current redirects
#   ./openwrt-switch-ip-to-nordvpn-gw.sh --remove <source-ip>  # remove redirect
#
# Persistence: rules are written to /etc/rc.local on the OpenWRT router so
# they survive reboots.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPN_TABLE=200          # dedicated policy routing table (safe — not used by NordVPN)
VPN_TABLE_PRIORITY=100 # ip rule priority (lower = checked first; above main at 32766)
LAN_IFACE="br-lan"     # OpenWRT LAN bridge — change if your setup differs

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found."; exit 1; }
set -a; source "$ENV_FILE"; set +a

[[ -n "${OPENWRT_HOST:-}"     ]] || { echo "ERROR: OPENWRT_HOST missing in .env";     exit 1; }
[[ -n "${OPENWRT_SSH_PORT:-22}" ]] && SSH_PORT="${OPENWRT_SSH_PORT:-22}"
[[ -n "${OPENWRT_PASSWORD:-}" ]] || { echo "ERROR: OPENWRT_PASSWORD missing in .env"; exit 1; }
[[ -n "${PROXMOX_HOST:-}"     ]] || { echo "ERROR: PROXMOX_HOST missing in .env";     exit 1; }
[[ -n "${PROXMOX_PASSWORD:-}" ]] || { echo "ERROR: PROXMOX_PASSWORD missing in .env"; exit 1; }

# ── Flags ─────────────────────────────────────────────────────────────────────
MODE="interactive"
REMOVE_IP=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --list)          MODE="list";   shift ;;
    --remove)        MODE="remove"; REMOVE_IP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── SSH helpers ───────────────────────────────────────────────────────────────
owrt_ssh() {
  local port="${OPENWRT_SSH_PORT:-22}"
  sshpass -p "$OPENWRT_PASSWORD" ssh \
    -p "$port" \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=5 \
    "root@${OPENWRT_HOST}" "$@" 2>/dev/null
}

pxm_ssh() {
  sshpass -p "$PROXMOX_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=5 \
    "root@${PROXMOX_HOST}" "$@" 2>/dev/null
}

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; RESET='\033[0m'

# ── Check OpenWRT reachable ───────────────────────────────────────────────────
owrt_ssh "echo ok" >/dev/null || {
  echo "ERROR: Cannot reach OpenWRT at ${OPENWRT_HOST}"
  exit 1
}

# ── List current redirects ────────────────────────────────────────────────────
list_redirects() {
  echo ""
  echo -e "${BOLD}  Current VPN redirects on OpenWRT (${OPENWRT_HOST})${RESET}"
  echo -e "  ─────────────────────────────────────────────────────"

  local rules
  rules=$(owrt_ssh "ip rule list" 2>/dev/null) || rules=""

  local gw
  gw=$(owrt_ssh "ip route show table ${VPN_TABLE} 2>/dev/null | awk '/default/{print \$3}'" || echo "")

  local found=0
  while IFS= read -r line; do
    local src
    src=$(echo "$line" | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/32)?' | awk '{print $2}')
    [[ -z "$src" ]] && continue
    # strip /32 suffix for display
    local display_ip="${src%/32}"
    printf "  %-20s  →  gateway %s\n" "$display_ip" "${gw:-unknown}"
    found=$((found + 1))
  done < <(echo "$rules" | grep "lookup ${VPN_TABLE}")

  if [[ $found -eq 0 ]]; then
    echo -e "  ${DIM}No redirects configured.${RESET}"
  fi
  echo ""
}

# ── Remove a redirect ─────────────────────────────────────────────────────────
remove_redirect() {
  local src_ip="$1"
  echo ""
  echo -e "  Removing redirect for ${src_ip}..."

  # Remove ip rule
  owrt_ssh "ip rule del from ${src_ip}/32 table ${VPN_TABLE} priority ${VPN_TABLE_PRIORITY} 2>/dev/null || true"
  owrt_ssh "ip route flush cache 2>/dev/null || true"

  # Remove from rc.local persistence block
  owrt_ssh "
    sed -i '/# vpn-redirect: ${src_ip}/,/# end-vpn-redirect: ${src_ip}/d' /etc/rc.local 2>/dev/null || true
  "

  echo -e "  ${GREEN}✓ Redirect for ${src_ip} removed${RESET}"
  echo ""
}

# ── Apply a redirect ──────────────────────────────────────────────────────────
apply_redirect() {
  local src_ip="$1"
  local gw_ip="$2"
  local gw_name="$3"

  echo ""
  echo -e "  Applying: ${src_ip} → ${gw_ip} (${gw_name})..."

  # Remove any existing rule for this source IP first (idempotent)
  owrt_ssh "ip rule del from ${src_ip}/32 table ${VPN_TABLE} 2>/dev/null || true"

  # Set the default route in the VPN table via the chosen gateway
  owrt_ssh "ip route replace default via ${gw_ip} dev ${LAN_IFACE} table ${VPN_TABLE}"

  # Add policy rule: traffic from src_ip → use VPN table
  owrt_ssh "ip rule add from ${src_ip}/32 table ${VPN_TABLE} priority ${VPN_TABLE_PRIORITY}"

  # Flush route cache so new rules take effect immediately
  owrt_ssh "ip route flush cache"

  # Persist across reboots via /etc/rc.local
  # Remove old entry for this IP first, then append fresh block
  owrt_ssh "
    sed -i '/# vpn-redirect: ${src_ip}/,/# end-vpn-redirect: ${src_ip}/d' /etc/rc.local 2>/dev/null || true
    # Ensure rc.local is executable and has exit 0
    [ -f /etc/rc.local ] || echo '#!/bin/sh' > /etc/rc.local
    chmod +x /etc/rc.local
    grep -q 'exit 0' /etc/rc.local || echo 'exit 0' >> /etc/rc.local
    # Insert persistence block before final exit 0
    sed -i '/^exit 0/i\\
# vpn-redirect: ${src_ip}\\
ip route replace default via ${gw_ip} dev ${LAN_IFACE} table ${VPN_TABLE}\\
ip rule add from ${src_ip}/32 table ${VPN_TABLE} priority ${VPN_TABLE_PRIORITY} 2>/dev/null || true\\
ip route flush cache\\
# end-vpn-redirect: ${src_ip}' /etc/rc.local
  "

  echo -e "  ${GREEN}✓ ${src_ip} will now route through ${gw_name} (${gw_ip})${RESET}"
  echo -e "  ${GREEN}✓ Persisted to /etc/rc.local — survives reboot${RESET}"
  echo ""
}

# ── Discover NordVPN gateways from Proxmox ────────────────────────────────────
discover_gateways() {
  local raw
  raw=$(pxm_ssh "pct list 2>/dev/null") || { echo "ERROR: Cannot reach Proxmox"; exit 1; }

  declare -ga gw_list=()
  while IFS= read -r entry; do
    local vmid="${entry%% *}"
    local rest="${entry#* }"
    local status="${rest%% *}"
    local lxc_name="${rest##* }"
    [[ "$status" != "running" ]] && continue

    local lxc_ip
    lxc_ip=$(pxm_ssh "pct config ${vmid}" \
      | grep "^net0:" \
      | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
      | cut -d= -f2) || lxc_ip=""
    [[ -z "$lxc_ip" ]] && continue

    local vpn_country
    vpn_country=$(pxm_ssh "pct exec ${vmid} -- nordvpn status 2>/dev/null" \
      | awk -F': ' '/^Country:/{print $2}') || vpn_country="Unknown"

    gw_list+=("${lxc_ip}|${lxc_name}|${vpn_country}")
  done < <(echo "$raw" | awk 'NR>1 && $2=="running" && tolower($NF) ~ /nordvpn/ {print $1 " " $2 " " $NF}')
}

# ── --list mode ───────────────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
  list_redirects
  exit 0
fi

# ── --remove mode ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "remove" ]]; then
  [[ -n "$REMOVE_IP" ]] || { echo "ERROR: --remove requires an IP argument"; exit 1; }
  remove_redirect "$REMOVE_IP"
  exit 0
fi

# ── Interactive mode ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       OpenWRT → NordVPN Policy Routing                          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# Show existing redirects
list_redirects

# Discover available gateways
echo -e "  ${DIM}Querying Proxmox for running NordVPN gateways...${RESET}"
discover_gateways

if [[ ${#gw_list[@]} -eq 0 ]]; then
  echo -e "${RED}  No running NordVPN LXCs found on Proxmox.${RESET}"
  exit 1
fi

# Ask for source IP
echo -e "${BOLD}  Step 1: Which LAN device to redirect?${RESET}"
echo -e "  Enter the source IP address (e.g. 192.168.1.100):"
read -rp "  Source IP: " src_ip || true
src_ip="${src_ip// /}"

if [[ -z "$src_ip" ]]; then
  echo -e "  ${DIM}Cancelled.${RESET}"; exit 0
fi

# Validate IP format
if ! echo "$src_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo -e "  ${RED}Invalid IP address: ${src_ip}${RESET}"; exit 1
fi

# Ask for gateway
echo ""
echo -e "${BOLD}  Step 2: Route through which NordVPN gateway?${RESET}"
echo ""
i=1
for entry in "${gw_list[@]}"; do
  IFS='|' read -r gw name country <<< "$entry"
  printf "  ${CYAN}[%d]${RESET}  %-12s  %-24s  %s\n" "$i" "$gw" "$name" "$country"
  i=$((i + 1))
done
echo ""
echo -e "  ${CYAN}[0]${RESET}  Remove redirect for ${src_ip} (restore normal routing)"
echo ""
read -rp "  Choice: " gw_choice || true

if [[ "$gw_choice" == "0" ]]; then
  remove_redirect "$src_ip"
  exit 0
fi

if ! [[ "$gw_choice" =~ ^[0-9]+$ ]] || [[ "$gw_choice" -lt 1 ]] || [[ "$gw_choice" -gt ${#gw_list[@]} ]]; then
  echo -e "  ${RED}Invalid choice.${RESET}"; exit 1
fi

selected="${gw_list[$((gw_choice - 1))]}"
IFS='|' read -r gw_ip gw_name gw_country <<< "$selected"

apply_redirect "$src_ip" "$gw_ip" "${gw_name} (${gw_country})"

# Verify: show updated redirect list
list_redirects
