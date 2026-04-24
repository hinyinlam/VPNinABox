#!/usr/bin/env bash
# DeleteNordVPNGateway.sh — list all NordVPN LXCs on Proxmox, choose one to delete.
#
# Correct deletion order: pct stop → pct destroy --purge
# Prompts for confirmation before any destructive action.
#
# Usage:
#   ./DeleteNordVPNGateway.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found. Copy .env.example → .env and fill in credentials."
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

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

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; RESET='\033[0m'

# ── Discover all NordVPN LXCs (running or stopped) ────────────────────────────
raw_list=$(pxm_ssh "pct list 2>/dev/null") || {
  echo "ERROR: Cannot reach Proxmox at ${PROXMOX_HOST}"
  exit 1
}

mapfile -t nordvpn_lxcs < <(
  echo "$raw_list" \
  | awk 'NR>1 && tolower($NF) ~ /nordvpn/ {print $1 " " $2 " " $NF}'
)

if [[ ${#nordvpn_lxcs[@]} -eq 0 ]]; then
  echo -e "${YELLOW}No NordVPN LXCs found on ${PROXMOX_HOST}${RESET}"
  exit 0
fi

# ── Display list ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
printf "${BOLD}║  Delete NordVPN Gateway — Proxmox %-33s║${RESET}\n" "${PROXMOX_HOST}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${RED}WARNING: Deletion is permanent. The LXC disk will be wiped.${RESET}"
echo ""

declare -a vmids=()
declare -a names=()
declare -a statuses=()

i=1
for entry in "${nordvpn_lxcs[@]}"; do
  vmid="${entry%% *}"
  rest="${entry#* }"
  status="${rest%% *}"
  lxc_name="${rest##* }"

  vmids+=("$vmid")
  names+=("$lxc_name")
  statuses+=("$status")

  if [[ "$status" == "running" ]]; then
    status_label="${GREEN}running${RESET}"
  else
    status_label="${DIM}${status}${RESET}"
  fi

  printf "  ${CYAN}[%d]${RESET}  %-6s  %-25s  %b\n" "$i" "$vmid" "$lxc_name" "$status_label"
  i=$((i + 1))
done

echo ""
echo -e "  ${CYAN}[0]${RESET}  Cancel — do nothing"
echo ""
read -rp "  Choose gateway to delete (number): " choice || true

if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
  echo -e "  ${DIM}Cancelled.${RESET}"
  exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#vmids[@]} ]]; then
  echo -e "  ${RED}Invalid choice.${RESET}"
  exit 1
fi

idx=$((choice - 1))
target_vmid="${vmids[$idx]}"
target_name="${names[$idx]}"
target_status="${statuses[$idx]}"

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}You selected:${RESET}"
echo -e "    VMID     : ${target_vmid}"
echo -e "    Name     : ${target_name}"
echo -e "    Status   : ${target_status}"
echo ""
echo -e "  ${RED}${BOLD}This will permanently destroy the LXC and wipe its disk.${RESET}"
echo -e "  ${BOLD}Type the container name to confirm deletion:${RESET}"
read -rp "  > " confirm || true

if [[ "$confirm" != "$target_name" ]]; then
  echo -e "  ${YELLOW}Name did not match. Aborted.${RESET}"
  exit 1
fi

# ── Get LXC IP before destroying (needed for OpenWRT cleanup) ────────────────
lxc_ip=$(pxm_ssh "pct config ${target_vmid}" \
  | grep "^net0:" \
  | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  | cut -d= -f2) || lxc_ip=""

# ── Delete: stop then destroy ──────────────────────────────────────────────────
echo ""
if [[ "$target_status" == "running" ]]; then
  echo -e "  Stopping LXC ${target_vmid}..."
  pxm_ssh "pct stop ${target_vmid}"
  echo -e "  ${GREEN}✓ Stopped${RESET}"
fi

echo -e "  Destroying LXC ${target_vmid} (--purge)..."
pxm_ssh "pct destroy ${target_vmid} --purge"
echo -e "  ${GREEN}✓ LXC ${target_vmid} (${target_name}) destroyed${RESET}"

# ── Clean up OpenWRT routes that pointed to this gateway ─────────────────────
OPENWRT_SCRIPT="${SCRIPT_DIR}/openwrt-switch-ip-to-nordvpn-gw.sh"
if [[ -n "$lxc_ip" && -n "${OPENWRT_HOST:-}" && -n "${OPENWRT_PASSWORD:-}" && -f "$OPENWRT_SCRIPT" ]]; then
  echo ""
  echo -e "  Cleaning up OpenWRT routes for gateway ${lxc_ip}..."
  bash "$OPENWRT_SCRIPT" --remove-gateway "$lxc_ip" || \
    echo -e "  ${YELLOW}⚠ OpenWRT cleanup failed — remove manually with:${RESET}"
    echo -e "  ${DIM}  $OPENWRT_SCRIPT --remove-gateway ${lxc_ip}${RESET}"
elif [[ -z "$lxc_ip" ]]; then
  echo -e "  ${YELLOW}⚠ Could not determine LXC IP — skipping OpenWRT cleanup${RESET}"
fi

echo ""
