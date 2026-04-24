#!/usr/bin/env bash
# SwitchNordVPNConnection.sh — reconnect or switch country on a NordVPN LXC node.
#
# Run from your LOCAL MACHINE. Reads credentials from .env.
#
# Usage:
#   ./SwitchNordVPNConnection.sh                          # interactive
#   ./SwitchNordVPNConnection.sh --node <vmid|hostname>   # pre-select LXC
#   ./SwitchNordVPNConnection.sh --country <name>         # pre-select country
#   ./SwitchNordVPNConnection.sh --node 200 --country US  # fully non-interactive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found."; exit 1; }
set -a; source "$ENV_FILE"; set +a

[[ -n "${PROXMOX_HOST:-}"     ]] || { echo "ERROR: PROXMOX_HOST missing in .env";     exit 1; }
[[ -n "${PROXMOX_PASSWORD:-}" ]] || { echo "ERROR: PROXMOX_PASSWORD missing in .env"; exit 1; }

# ── Flags ─────────────────────────────────────────────────────────────────────
ARG_NODE=""
ARG_COUNTRY=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --node)    ARG_NODE="$2";    shift 2 ;;
    --country) ARG_COUNTRY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; RESET='\033[0m'

# ── SSH helper ────────────────────────────────────────────────────────────────
pxm_ssh() {
  sshpass -p "$PROXMOX_PASSWORD" ssh \
    -n \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=5 \
    "root@${PROXMOX_HOST}" "$@" 2>/dev/null
}

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
  exit 1
fi

# ── Get VPN status for a VMID ─────────────────────────────────────────────────
get_vpn_status() {
  pxm_ssh "pct exec ${1} -- nordvpn status 2>/dev/null" || true
}

# ── Print node summary ────────────────────────────────────────────────────────
print_node() {
  local vmid="$1" name="$2" raw="$3"
  local status country server city uptime
  status=$(echo  "$raw" | awk -F': ' '/^Status:/{print $2}')
  country=$(echo "$raw" | awk -F': ' '/^Country:/{print $2}')
  server=$(echo  "$raw" | awk -F': ' '/^Server:/{print $2}')
  city=$(echo    "$raw" | awk -F': ' '/^City:/{print $2}')
  uptime=$(echo  "$raw" | awk -F': ' '/^Uptime:/{print $2}')

  if [[ "$status" == "Connected" ]]; then
    local icon="${GREEN}●${RESET}" slabel="${GREEN}Connected${RESET}"
  else
    local icon="${RED}○${RESET}"   slabel="${RED}${status:-Disconnected}${RESET}"
  fi

  echo -e "  ${BOLD}${CYAN}[$vmid] $name${RESET}"
  printf   "  %-16s %b %b\n" "VPN Status:"  "$icon" "$slabel"
  printf   "  %-16s %s\n"    "Country:"     "${country:--}"
  printf   "  %-16s %s\n"    "Server:"      "${server:--}"
  printf   "  %-16s %s\n"    "City:"        "${city:--}"
  printf   "  %-16s %s\n"    "Uptime:"      "${uptime:--}"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       Switch NordVPN Connection                                  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Fetch status for all nodes ────────────────────────────────────────────────
declare -A node_status
declare -A node_name
declare -A node_country

for entry in "${nordvpn_lxcs[@]}"; do
  vmid="${entry%% *}"
  name="${entry##* }"
  raw=$(get_vpn_status "$vmid")
  node_status[$vmid]="$raw"
  node_name[$vmid]="$name"
  node_country[$vmid]=$(echo "$raw" | awk -F': ' '/^Country:/{print $2}')
done

# ── Step 1: Pick a node ───────────────────────────────────────────────────────
selected_vmid=""

if [[ -n "$ARG_NODE" ]]; then
  for entry in "${nordvpn_lxcs[@]}"; do
    vmid="${entry%% *}"
    name="${entry##* }"
    if [[ "$vmid" == "$ARG_NODE" || "$name" == *"$ARG_NODE"* ]]; then
      selected_vmid="$vmid"
      break
    fi
  done
  [[ -n "$selected_vmid" ]] || { echo -e "${RED}ERROR: Node '${ARG_NODE}' not found or not running.${RESET}"; exit 1; }

elif [[ ${#nordvpn_lxcs[@]} -eq 1 ]]; then
  selected_vmid="${nordvpn_lxcs[0]%% *}"
  echo -e "  ${DIM}Single node — auto-selected.${RESET}"
  echo ""

else
  echo -e "${BOLD}  Step 1: Select NordVPN node${RESET}"
  echo ""
  i=1
  declare -a vmid_order=()
  for entry in "${nordvpn_lxcs[@]}"; do
    vmid="${entry%% *}"
    name="${entry##* }"
    status=$(echo "${node_status[$vmid]}" | awk -F': ' '/^Status:/{print $2}')
    country="${node_country[$vmid]:--}"
    [[ "$status" == "Connected" ]] && dot="${GREEN}●${RESET}" || dot="${RED}○${RESET}"
    printf "  ${CYAN}[%d]${RESET}  %b  %-26s  %s\n" "$i" "$dot" "$name (VMID $vmid)" "$country"
    vmid_order+=("$vmid")
    i=$((i + 1))
  done
  echo ""
  read -rp "  Choice [1-$((i-1))]: " node_choice || true
  [[ "$node_choice" =~ ^[0-9]+$ && "$node_choice" -ge 1 && "$node_choice" -le $((i-1)) ]] \
    || { echo -e "  ${RED}Invalid choice.${RESET}"; exit 1; }
  selected_vmid="${vmid_order[$((node_choice - 1))]}"
fi

# ── Show current state ────────────────────────────────────────────────────────
echo ""
print_node "$selected_vmid" "${node_name[$selected_vmid]}" "${node_status[$selected_vmid]}"
echo ""

current_country="${node_country[$selected_vmid]}"

# ── Step 2: Choose action ─────────────────────────────────────────────────────
target_country=""

if [[ -n "$ARG_COUNTRY" ]]; then
  target_country="$ARG_COUNTRY"
else
  echo -e "${BOLD}  Step 2: Choose action${RESET}"
  echo ""
  echo -e "  ${CYAN}[1]${RESET}  Reconnect — same country (${current_country:-unknown}, new server)"
  echo -e "  ${CYAN}[2]${RESET}  Switch to a different country"
  echo -e "  ${CYAN}[0]${RESET}  Cancel"
  echo ""
  read -rp "  Choice: " action_choice || true

  case "${action_choice:-}" in
    0) echo -e "  ${DIM}Cancelled.${RESET}"; exit 0 ;;
    1) target_country="$current_country" ;;
    2)
      echo ""
      echo -e "  ${DIM}Fetching available countries...${RESET}"
      countries_raw=$(pxm_ssh "pct exec ${selected_vmid} -- nordvpn countries 2>/dev/null") || countries_raw=""

      if [[ -n "$countries_raw" ]]; then
        mapfile -t country_list <<< "$countries_raw"
        echo ""
        total=${#country_list[@]}
        cols=3
        rows=$(( (total + cols - 1) / cols ))
        for ((row=0; row<rows; row++)); do
          line=""
          for ((col=0; col<cols; col++)); do
            idx=$((row + col * rows))
            [[ $idx -lt $total ]] && line+=$(printf "  %-26s" "${country_list[$idx]}")
          done
          echo "$line"
        done
        echo ""
      fi

      read -rp "  Country name: " target_country || true
      target_country="${target_country// /}"
      ;;
    *) echo -e "  ${RED}Invalid choice.${RESET}"; exit 1 ;;
  esac
fi

[[ -n "$target_country" ]] || { echo -e "  ${RED}No country specified.${RESET}"; exit 1; }

# ── Connect ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  Connecting ${node_name[$selected_vmid]} → ${BOLD}${target_country}${RESET}..."
echo ""

connect_out=$(pxm_ssh "pct exec ${selected_vmid} -- nordvpn connect '${target_country}' 2>&1") || connect_out="(no output)"
echo -e "  ${DIM}${connect_out}${RESET}"
echo ""

# ── Verify new state ──────────────────────────────────────────────────────────
echo -e "  ${DIM}Verifying...${RESET}"
sleep 4

new_raw=$(get_vpn_status "$selected_vmid")
new_status=$(echo  "$new_raw" | awk -F': ' '/^Status:/{print $2}')
new_country=$(echo "$new_raw" | awk -F': ' '/^Country:/{print $2}')
new_server=$(echo  "$new_raw" | awk -F': ' '/^Server:/{print $2}')
new_ip=$(echo      "$new_raw" | awk -F': ' '/^IP:/{print $2}')

echo ""
if [[ "$new_status" == "Connected" ]]; then
  echo -e "  ${GREEN}✓ Connected${RESET}"
  printf   "  %-16s %s\n" "Country:"  "${new_country:--}"
  printf   "  %-16s %s\n" "Server:"   "${new_server:--}"
  printf   "  %-16s %s\n" "VPN IP:"   "${new_ip:--}"
else
  echo -e "  ${RED}✗ Not connected — status: ${new_status:-unknown}${RESET}"
  echo -e "  ${DIM}Debug: ssh root@${PROXMOX_HOST} 'pct exec ${selected_vmid} -- nordvpn status'${RESET}"
  exit 1
fi
echo ""
