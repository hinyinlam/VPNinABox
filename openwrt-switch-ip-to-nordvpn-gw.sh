#!/usr/bin/env bash
# openwrt-switch-ip-to-nordvpn-gw.sh — policy-route a LAN device through a
# chosen NordVPN gateway on OpenWRT using proper UCI persistence.
#
# How it works:
#   Each NordVPN gateway gets a dedicated routing table (200 + last IP octet).
#   e.g. gateway 192.168.1.51 → table 251, gateway 192.168.1.50 → table 250.
#   A UCI 'rule' maps the source device IP to that table.
#   UCI 'route' puts a default route via the gateway in that table.
#   All persisted via 'uci commit + network reload' — survives reboots cleanly.
#
# Usage:
#   ./openwrt-switch-ip-to-nordvpn-gw.sh              # interactive
#   ./openwrt-switch-ip-to-nordvpn-gw.sh --list       # show current redirects
#   ./openwrt-switch-ip-to-nordvpn-gw.sh --remove <source-ip>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found."; exit 1; }
set -a; source "$ENV_FILE"; set +a

[[ -n "${OPENWRT_HOST:-}"     ]] || { echo "ERROR: OPENWRT_HOST missing in .env";     exit 1; }
[[ -n "${OPENWRT_PASSWORD:-}" ]] || { echo "ERROR: OPENWRT_PASSWORD missing in .env"; exit 1; }
[[ -n "${PROXMOX_HOST:-}"     ]] || { echo "ERROR: PROXMOX_HOST missing in .env";     exit 1; }
[[ -n "${PROXMOX_PASSWORD:-}" ]] || { echo "ERROR: PROXMOX_PASSWORD missing in .env"; exit 1; }

# ── Flags ─────────────────────────────────────────────────────────────────────
MODE="interactive"
REMOVE_IP=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --list)   MODE="list";                    shift ;;
    --remove) MODE="remove"; REMOVE_IP="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── SSH helpers ───────────────────────────────────────────────────────────────
owrt_ssh() {
  sshpass -p "$OPENWRT_PASSWORD" ssh \
    -n \
    -p "${OPENWRT_SSH_PORT:-22}" \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=8 \
    "root@${OPENWRT_HOST}" "$@" 2>/dev/null
}

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

# ── Connectivity check ────────────────────────────────────────────────────────
owrt_ssh "echo ok" >/dev/null || { echo "ERROR: Cannot reach OpenWRT at ${OPENWRT_HOST}:${OPENWRT_SSH_PORT:-22}"; exit 1; }

# ── Table ID from gateway IP (200 + last octet) ───────────────────────────────
# e.g. 192.168.1.51 → table 251, 192.168.1.50 → table 250
table_id_for_gw() {
  local gw="$1"
  local last_octet="${gw##*.}"
  echo $((200 + last_octet))
}

# ── Register table in /etc/iproute2/rt_tables (idempotent) ───────────────────
ensure_rt_table() {
  local table_id="$1"
  local table_name="$2"
  owrt_ssh "grep -q '^${table_id}' /etc/iproute2/rt_tables \
    || echo '${table_id}  ${table_name}' >> /etc/iproute2/rt_tables"
}

# ── List current redirects ────────────────────────────────────────────────────
list_redirects() {
  echo ""
  echo -e "${BOLD}  Current VPN redirects on OpenWRT (${OPENWRT_HOST})${RESET}"
  echo -e "  ─────────────────────────────────────────────────────"

  local uci_rules
  uci_rules=$(owrt_ssh "uci show network 2>/dev/null | grep '@rule'") || uci_rules=""

  if [[ -z "$uci_rules" ]]; then
    echo -e "  ${DIM}No redirects configured.${RESET}"
    echo ""
    return
  fi

  # Get all rule indices with a lookup value
  local found=0
  local indices
  indices=$(owrt_ssh "uci show network 2>/dev/null \
    | grep '@rule\[.*\].lookup' \
    | grep -oE '@rule\[[0-9]+\]' \
    | tr -d '@rule[]'" 2>/dev/null) || indices=""

  for idx in $indices; do
    local src lookup
    src=$(owrt_ssh    "uci get network.@rule[${idx}].src    2>/dev/null") || src=""
    lookup=$(owrt_ssh "uci get network.@rule[${idx}].lookup 2>/dev/null") || lookup=""
    [[ -z "$src" || -z "$lookup" ]] && continue

    # Find gateway for this table
    local gw
    gw=$(owrt_ssh "ip route show table ${lookup} 2>/dev/null | awk '/default/{print \$3}'") || gw="unknown"

    printf "  %-20s  →  table %-5s  gateway %s\n" "${src%/32}" "$lookup" "$gw"
    found=$((found + 1))
  done

  [[ $found -eq 0 ]] && echo -e "  ${DIM}No redirects configured.${RESET}"
  echo ""
}

# ── Remove redirect for a source IP ──────────────────────────────────────────
remove_redirect() {
  local src_ip="$1"
  echo ""
  echo -e "  Removing redirect for ${src_ip}..."

  owrt_ssh "
    changed=0
    count=\$(uci show network 2>/dev/null | grep -c '@rule\[' || true)
    i=0
    while [ \$i -lt \$count ]; do
      src=\$(uci get network.@rule[\$i].src 2>/dev/null) || { i=\$((i+1)); continue; }
      if [ \"\$src\" = \"${src_ip}/32\" ] || [ \"\$src\" = \"${src_ip}\" ]; then
        uci delete network.@rule[\$i]
        uci commit network
        changed=1
        break
      fi
      i=\$((i+1))
    done
    if [ \$changed -eq 1 ]; then
      /etc/init.d/network reload >/dev/null 2>&1
      echo 'removed'
    else
      echo 'not_found'
    fi
  "

  echo -e "  ${GREEN}✓ Redirect for ${src_ip} removed and persisted${RESET}"
  echo ""
}

# ── Apply redirect ────────────────────────────────────────────────────────────
apply_redirect() {
  local src_ip="$1"
  local gw_ip="$2"
  local gw_label="$3"
  local table_id
  table_id=$(table_id_for_gw "$gw_ip")
  local table_name="nordvpn-${gw_ip##*.}"   # e.g. nordvpn-51

  echo ""
  echo -e "  Applying: ${src_ip} → table ${table_id} → ${gw_ip} (${gw_label})..."

  owrt_ssh "
    # 1. Register routing table
    grep -q '^${table_id}' /etc/iproute2/rt_tables \
      || echo '${table_id}  ${table_name}' >> /etc/iproute2/rt_tables

    # 2. Ensure a UCI route exists for this table (default via gateway)
    #    Reuse existing route for this table or add a new one
    route_idx=-1
    i=0
    while true; do
      t=\$(uci get network.@route[\$i].table 2>/dev/null) || break
      if [ \"\$t\" = \"${table_id}\" ]; then
        route_idx=\$i
        break
      fi
      i=\$((i+1))
    done

    if [ \$route_idx -ge 0 ]; then
      # Update existing route
      uci set network.@route[\${route_idx}].gateway='${gw_ip}'
    else
      # Add new route
      uci add network route
      uci set network.@route[-1].interface='lan'
      uci set network.@route[-1].target='0.0.0.0'
      uci set network.@route[-1].netmask='0.0.0.0'
      uci set network.@route[-1].gateway='${gw_ip}'
      uci set network.@route[-1].table='${table_id}'
    fi
    uci commit network

    # 3. Remove any existing UCI rule for this source IP (idempotent)
    changed=1
    while [ \$changed -eq 1 ]; do
      changed=0
      i=0
      while true; do
        src=\$(uci get network.@rule[\$i].src 2>/dev/null) || break
        if [ \"\$src\" = \"${src_ip}/32\" ] || [ \"\$src\" = \"${src_ip}\" ]; then
          uci delete network.@rule[\$i]
          uci commit network
          changed=1
          break
        fi
        i=\$((i+1))
      done
    done

    # 4. Add new rule
    uci add network rule
    uci set network.@rule[-1].src='${src_ip}/32'
    uci set network.@rule[-1].lookup='${table_id}'
    uci set network.@rule[-1].priority='100'
    uci commit network

    # 5. Reload
    /etc/init.d/network reload >/dev/null 2>&1
    echo 'applied'
  "

  echo -e "  ${GREEN}✓ ${src_ip} → ${gw_label} (${gw_ip})${RESET}"
  echo -e "  ${GREEN}✓ Persisted via UCI — survives reboot${RESET}"

  # Verify
  sleep 2
  local rule_check
  rule_check=$(owrt_ssh "ip rule list | grep 'from ${src_ip}'") || rule_check=""
  local route_check
  route_check=$(owrt_ssh "ip route show table ${table_id} | grep default") || route_check=""
  echo -e "  ${DIM}ip rule: ${rule_check}${RESET}"
  echo -e "  ${DIM}table:   ${route_check}${RESET}"
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
    local lxc_name="${rest##* }"
    local lxc_ip
    lxc_ip=$(pxm_ssh "pct config ${vmid}" \
      | grep "^net0:" \
      | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
      | cut -d= -f2) || lxc_ip=""
    [[ -z "$lxc_ip" ]] && continue
    local country
    country=$(pxm_ssh "pct exec ${vmid} -- nordvpn status 2>/dev/null" \
      | awk -F': ' '/^Country:/{print $2}') || country="Unknown"
    gw_list+=("${lxc_ip}|${lxc_name}|${country}")
  done < <(echo "$raw" | awk 'NR>1 && $2=="running" && tolower($NF) ~ /nordvpn/ {print $1 " " $2 " " $NF}')
}

# ── --list ────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
  list_redirects
  exit 0
fi

# ── --remove ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "remove" ]]; then
  [[ -n "$REMOVE_IP" ]] || { echo "ERROR: --remove requires an IP"; exit 1; }
  remove_redirect "$REMOVE_IP"
  exit 0
fi

# ── Interactive ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       OpenWRT → NordVPN Policy Routing                          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"

list_redirects

echo -e "  ${DIM}Querying Proxmox for running NordVPN gateways...${RESET}"
discover_gateways

if [[ ${#gw_list[@]} -eq 0 ]]; then
  echo -e "${RED}  No running NordVPN LXCs found.${RESET}"; exit 1
fi

echo -e "${BOLD}  Step 1: Source IP to redirect${RESET}"
echo -e "  (Enter IP of the LAN device whose traffic you want to route via VPN)"
read -rp "  Source IP: " src_ip || true
src_ip="${src_ip// /}"
[[ -z "$src_ip" ]] && { echo -e "  ${DIM}Cancelled.${RESET}"; exit 0; }
echo "$src_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo -e "  ${RED}Invalid IP: ${src_ip}${RESET}"; exit 1; }

echo ""
echo -e "${BOLD}  Step 2: Choose NordVPN gateway${RESET}"
echo ""
i=1
for entry in "${gw_list[@]}"; do
  IFS='|' read -r gw name country <<< "$entry"
  local_table=$(table_id_for_gw "$gw")
  printf "  ${CYAN}[%d]${RESET}  %-14s  %-24s  %-12s  (table %s)\n" \
    "$i" "$gw" "$name" "$country" "$local_table"
  i=$((i + 1))
done
echo ""
echo -e "  ${CYAN}[0]${RESET}  Remove redirect for ${src_ip}"
echo ""
read -rp "  Choice: " gw_choice || true

if [[ "$gw_choice" == "0" ]]; then
  remove_redirect "$src_ip"
  exit 0
fi

[[ "$gw_choice" =~ ^[0-9]+$ ]] && [[ "$gw_choice" -ge 1 ]] && [[ "$gw_choice" -le ${#gw_list[@]} ]] \
  || { echo -e "  ${RED}Invalid choice.${RESET}"; exit 1; }

IFS='|' read -r gw_ip gw_name gw_country <<< "${gw_list[$((gw_choice - 1))]}"
apply_redirect "$src_ip" "$gw_ip" "${gw_name} / ${gw_country}"

list_redirects
