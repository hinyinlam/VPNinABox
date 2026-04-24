#!/usr/bin/env bash
# GetAvailableNordVPNGateway.sh — discover all running NordVPN LXCs on Proxmox
# and print their VPN status + ready-to-paste macOS route commands.
#
# Usage:
#   ./GetAvailableNordVPNGateway.sh          # uses .env for credentials
#   ./GetAvailableNordVPNGateway.sh --switch  # interactive: pick and apply gateway now

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found. Copy .env.example → .env and fill in credentials."
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

SWITCH_MODE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --switch) SWITCH_MODE=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── SSH helper ────────────────────────────────────────────────────────────────
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

# ── Discover running NordVPN LXCs ─────────────────────────────────────────────
raw_list=$(pxm_ssh "pct list 2>/dev/null") || {
  echo "ERROR: Cannot reach Proxmox at ${PROXMOX_HOST}"
  exit 1
}

mapfile -t nordvpn_lxcs < <(
  echo "$raw_list" \
  | awk 'NR>1 && $2=="running" && tolower($NF) ~ /nordvpn/ {print $1 " " $NF}'
)

if [[ ${#nordvpn_lxcs[@]} -eq 0 ]]; then
  echo -e "${RED}No running NordVPN LXCs found on ${PROXMOX_HOST}${RESET}"
  echo "  (Looking for containers with 'nordvpn' in the hostname that are running)"
  exit 0
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
printf "${BOLD}║  NordVPN Gateways on Proxmox %-36s║${RESET}\n" "${PROXMOX_HOST}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

current_gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}' || echo "unknown")
echo -e "  ${DIM}Current macOS default gateway: ${current_gw}${RESET}"
echo ""

gateways=()

for entry in "${nordvpn_lxcs[@]}"; do
  vmid="${entry%% *}"
  lxc_name="${entry##* }"

  # LXC IP from pct config net0 line
  lxc_ip=$(pxm_ssh "pct config $vmid" \
    | grep "^net0:" \
    | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | cut -d= -f2) || lxc_ip=""
  [[ -z "$lxc_ip" ]] && lxc_ip="unknown"

  # VPN status from inside container
  vpn_raw=$(pxm_ssh "pct exec $vmid -- nordvpn status 2>/dev/null") || vpn_raw=""
  vpn_status=$(echo  "$vpn_raw" | awk -F': ' '/^Status:/{print $2}')
  vpn_country=$(echo "$vpn_raw" | awk -F': ' '/^Country:/{print $2}')
  vpn_uptime=$(echo  "$vpn_raw" | awk -F': ' '/^Uptime:/{print $2}')

  # Public exit IP
  exit_ip=$(pxm_ssh "pct exec $vmid -- curl -s --max-time 6 https://ipinfo.io/ip 2>/dev/null" \
    | tr -d '[:space:]') || exit_ip="unreachable"
  exit_country=$(pxm_ssh "pct exec $vmid -- curl -s --max-time 6 https://ipinfo.io/country 2>/dev/null" \
    | tr -d '[:space:]') || exit_country="?"

  # Meshnet identity
  mesh_raw=$(pxm_ssh "pct exec $vmid -- nordvpn meshnet peer list 2>/dev/null") || mesh_raw=""
  mesh_nick=$(echo "$mesh_raw" \
    | awk '/^This device/{f=1} f && /^Nickname:/{if(NF>1) print $2; else print "-"; exit}') || mesh_nick="-"
  mesh_host=$(echo "$mesh_raw" \
    | awk '/^This device/{f=1} f && /^Hostname:/{print $2; exit}') || mesh_host="-"

  if [[ "$vpn_status" == "Connected" ]]; then
    status_icon="${GREEN}●${RESET}"; status_label="${GREEN}Connected${RESET}"
  else
    status_icon="${RED}○${RESET}"; status_label="${RED}${vpn_status:-Disconnected}${RESET}"
  fi

  [[ "$lxc_ip" == "$current_gw" ]] && active_tag=" ${YELLOW}◀ ACTIVE${RESET}" || active_tag=""

  echo -e "  ${BOLD}${CYAN}[$vmid] $lxc_name${RESET}${active_tag}"
  echo -e "  ─────────────────────────────────────────────────────"
  printf "  %-18s %b %b\n"  "VPN Status:"    "$status_icon" "$status_label"
  printf "  %-18s %s\n"     "Country:"       "${vpn_country:-unknown}"
  printf "  %-18s %s (%s)\n" "Exit IP:"      "${exit_ip}"   "${exit_country}"
  printf "  %-18s %s\n"     "Gateway IP:"    "$lxc_ip"
  printf "  %-18s %s\n"     "Uptime:"        "${vpn_uptime:--}"
  printf "  %-18s %s\n"     "Mesh hostname:" "${mesh_host:--}"
  printf "  %-18s %s\n"     "Mesh nickname:" "${mesh_nick:--}"
  echo ""

  [[ "$lxc_ip" != "unknown" ]] && gateways+=("$lxc_ip|$lxc_name|$vpn_country")
done

# ── Route commands ────────────────────────────────────────────────────────────
echo -e "${BOLD}  macOS Route Commands${RESET}"
echo -e "  ─────────────────────────────────────────────────────"
for gw_entry in "${gateways[@]}"; do
  IFS='|' read -r gw name country <<< "$gw_entry"
  [[ "$gw" == "$current_gw" ]] && tag=" ${YELLOW}[ACTIVE]${RESET}" || tag=""
  echo -e "  ${BOLD}${country}${RESET} via $name ($gw)${tag}"
  echo -e "  ${DIM}sudo route delete default && sudo route add default ${gw}${RESET}"
  echo ""
done
echo -e "  ${BOLD}Restore home gateway${RESET}"
echo -e "  ${DIM}sudo route delete default && sudo route add default ${GATEWAY:-192.168.1.1}${RESET}"
echo ""

# ── Interactive --switch ──────────────────────────────────────────────────────
if [[ "$SWITCH_MODE" == "true" ]] && [[ ${#gateways[@]} -gt 0 ]]; then
  echo -e "${BOLD}  Switch gateway now:${RESET}"
  i=1
  for gw_entry in "${gateways[@]}"; do
    IFS='|' read -r gw name country <<< "$gw_entry"
    echo -e "  ${CYAN}[$i]${RESET} $country — $gw ($name)"
    i=$((i + 1))
  done
  echo -e "  ${CYAN}[0]${RESET} Restore — ${GATEWAY:-192.168.1.1}"
  echo ""
  read -rp "  Choice: " choice
  if [[ "$choice" == "0" ]]; then
    sudo route delete default 2>/dev/null || true
    sudo route add default "${GATEWAY:-192.168.1.1}"
    echo -e "  ${GREEN}✓ Restored to ${GATEWAY:-192.168.1.1}${RESET}"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#gateways[@]} ]]; then
    selected="${gateways[$((choice-1))]}"
    IFS='|' read -r gw name country <<< "$selected"
    sudo route delete default 2>/dev/null || true
    sudo route add default "$gw"
    echo -e "  ${GREEN}✓ Routing through $country ($gw)${RESET}"
  else
    echo "  Cancelled."
  fi
  echo ""
fi
