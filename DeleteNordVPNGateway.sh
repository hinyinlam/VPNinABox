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
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

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

pxm_ssh_stdin() {
  sshpass -p "$PROXMOX_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=5 \
    "root@${PROXMOX_HOST}" "$@" 2>/dev/null
}

is_ipv4() {
  local ip="$1" part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

remaining_running_nordvpn_lxcs() {
  pxm_ssh "pct list 2>/dev/null" \
    | awk -v deleted="$target_vmid" 'NR>1 && $1 != deleted && $2=="running" && tolower($NF) ~ /nordvpn/ {print $1 " " $NF}'
}

cleanup_mesh_peer_from_remaining_nodes() {
  local mesh_hostname="$1"

  [[ -n "$mesh_hostname" ]] || return 0
  if ! [[ "$mesh_hostname" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo -e "  ${YELLOW}⚠ Skipping Meshnet peer cleanup; unexpected hostname: ${mesh_hostname}${RESET}"
    return 0
  fi

  echo ""
  echo -e "  Removing stale Meshnet peer ${mesh_hostname} from remaining nodes..."

  local found=false
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    found=true
    local vmid="${entry%% *}"
    local name="${entry##* }"
    local out
    out=$(pxm_ssh "pct exec ${vmid} -- bash -lc 'printf %s\\n y | nordvpn meshnet peer remove ${mesh_hostname} 2>/dev/null || true'" || true)
    if echo "$out" | grep -qi "removed\|success\|not found\|does not exist\|No peer"; then
      echo -e "  ${GREEN}✓ ${name}: stale peer cleanup attempted${RESET}"
    else
      echo -e "  ${YELLOW}⚠ ${name}: peer cleanup uncertain${RESET}"
    fi
  done < <(remaining_running_nordvpn_lxcs)

  [[ "$found" == "true" ]] || echo -e "  ${DIM}No remaining running NordVPN nodes found for peer cleanup.${RESET}"
}

cleanup_mesh_routes_for_gateway() {
  local gateway_ip="$1"

  [[ -n "$gateway_ip" ]] || return 0
  if ! is_ipv4 "$gateway_ip"; then
    echo -e "  ${YELLOW}⚠ Skipping Meshnet route cleanup; invalid gateway IP: ${gateway_ip}${RESET}"
    return 0
  fi

  echo ""
  echo -e "  Cleaning Meshnet source routes that reference gateway ${gateway_ip}..."

  local found=false
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    found=true
    local vmid="${entry%% *}"
    local name="${entry##* }"
    local result
    result=$(pxm_ssh_stdin "pct exec ${vmid} -- env TARGET_GATEWAY_IP=${gateway_ip} bash -s" <<'REMOTE' || true
set -euo pipefail

state_file="/etc/nordvpn-mesh-routing/routes.tsv"
[[ -f "$state_file" ]] || { echo "none"; exit 0; }

remove_runtime_rules() {
  local src="$1" ingress_ip="$2" table_id="$3" priority="$4" lan_subnet="$5" mesh_subnet="$6"

  while ip rule del from "${src}/32" 2>/dev/null; do :; done
  while ip rule del from "${src}/32" priority "$priority" table "$table_id" 2>/dev/null; do :; done
  while iptables -D FORWARD -s "${src}/32" -o nordlynx -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -s "${src}/32" -o eth0 -j ACCEPT 2>/dev/null; do :; done
  while iptables -t mangle -D POSTROUTING -s "${src}/32" ! -d "$lan_subnet" -o eth0 -j ACCEPT 2>/dev/null; do :; done
  while iptables -t mangle -D PREROUTING -i eth0 -d "${ingress_ip}/32" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${src}/32" -d "$lan_subnet" -o nordlynx -j RETURN 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${src}/32" -d "$mesh_subnet" -o nordlynx -j RETURN 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${src}/32" -o nordlynx -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${src}/32" ! -d "$lan_subnet" ! -d "$mesh_subnet" -o nordlynx -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${src}/32" ! -d "$lan_subnet" -o eth0 -j SNAT --to-source "$ingress_ip" 2>/dev/null; do :; done
}

tmp_file="${state_file}.tmp"
> "$tmp_file"
removed=0
while IFS=$'\t' read -r src ingress_ip exit_ip mode_name table_id priority lan_subnet mesh_subnet; do
  [[ -z "${src:-}" ]] && continue
  if [[ "$ingress_ip" == "$TARGET_GATEWAY_IP" || "$exit_ip" == "$TARGET_GATEWAY_IP" ]]; then
    remove_runtime_rules "$src" "$ingress_ip" "$table_id" "$priority" "$lan_subnet" "$mesh_subnet"
    removed=$((removed + 1))
    continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$src" "$ingress_ip" "$exit_ip" "$mode_name" "$table_id" "$priority" "$lan_subnet" "$mesh_subnet" >> "$tmp_file"
done < "$state_file"

if [[ "$removed" -gt 0 ]]; then
  mv "$tmp_file" "$state_file"
  systemctl restart nordvpn-mesh-routing.service >/dev/null 2>&1 || true
  echo "removed:${removed}"
else
  rm -f "$tmp_file"
  echo "none"
fi
REMOTE
)
    case "$result" in
      removed:*) echo -e "  ${GREEN}✓ ${name}: removed ${result#removed:} stale Meshnet route(s)${RESET}" ;;
      none) echo -e "  ${DIM}${name}: no Meshnet routes referenced ${gateway_ip}${RESET}" ;;
      *) echo -e "  ${YELLOW}⚠ ${name}: route cleanup uncertain (${result})${RESET}" ;;
    esac
  done < <(remaining_running_nordvpn_lxcs)

  [[ "$found" == "true" ]] || echo -e "  ${DIM}No remaining running NordVPN nodes found for route cleanup.${RESET}"
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
target_mesh_hostname=""

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

if [[ "$target_status" == "running" ]]; then
  target_mesh_hostname=$(pxm_ssh "pct exec ${target_vmid} -- nordvpn meshnet peer list 2>/dev/null \
    | awk '/^This device/{found=1} found && /^Hostname:/{print \\$2; exit}'" || true)
fi

# ── Deregister meshnet before destroy (prevents stale device slots) ──────────
if [[ "$target_status" == "running" ]]; then
  echo ""
  echo -e "  Deregistering meshnet on LXC ${target_vmid}..."
  pxm_ssh "pct exec ${target_vmid} -- nordvpn set meshnet off 2>/dev/null || true" 2>/dev/null || true
  echo -e "  ${GREEN}✓ Meshnet deregistered (device slot freed)${RESET}"
fi

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

cleanup_mesh_peer_from_remaining_nodes "$target_mesh_hostname"
cleanup_mesh_routes_for_gateway "$lxc_ip"

# ── Clean up OpenWRT routes that pointed to this gateway ─────────────────────
OPENWRT_SCRIPT="${SCRIPT_DIR}/openwrt-switch-lan-ip-to-nordvpn-gw.sh"
if [[ -n "$lxc_ip" && -n "${OPENWRT_HOST:-}" && -n "${OPENWRT_PASSWORD:-}" && -f "$OPENWRT_SCRIPT" ]]; then
  echo ""
  echo -e "  Cleaning up OpenWRT routes for gateway ${lxc_ip}..."
  if ! bash "$OPENWRT_SCRIPT" --remove-gateway "$lxc_ip"; then
    echo -e "  ${YELLOW}⚠ OpenWRT cleanup failed — remove manually with:${RESET}"
    echo -e "  ${DIM}  $OPENWRT_SCRIPT --remove-gateway ${lxc_ip}${RESET}"
  fi
elif [[ -z "$lxc_ip" ]]; then
  echo -e "  ${YELLOW}⚠ Could not determine LXC IP — skipping OpenWRT cleanup${RESET}"
fi

echo ""
