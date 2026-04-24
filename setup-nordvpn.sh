#!/usr/bin/env bash
# setup-nordvpn.sh — single entry point to provision all NordVPN LXC nodes.
#
# Run from your LOCAL MACHINE (not the Proxmox host).
#
# Quick start:
#   cp .env.example .env          # fill in your values
#   ./setup-nordvpn.sh            # provision all nodes
#   ./setup-nordvpn.sh --force    # destroy and rebuild existing nodes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found."
  echo "  cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
  echo "  # edit .env with your Proxmox password, NordVPN token, node IPs, etc."
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# ── Validate required vars ────────────────────────────────────────────────────
required_vars=(PROXMOX_HOST PROXMOX_PASSWORD NORDVPN_TOKEN GATEWAY SUBNET)
missing=()
for v in "${required_vars[@]}"; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required variables in .env:"
  for v in "${missing[@]}"; do echo "  $v"; done
  exit 1
fi

# ── Flags ─────────────────────────────────────────────────────────────────────
FORCE_FLAG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --force) FORCE_FLAG="--force"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

PROVISIONER="${SCRIPT_DIR}/SetupNordVPN/create-nordvpn-lxc.sh"
[[ -f "$PROVISIONER" ]] || fail "SetupNordVPN/create-nordvpn-lxc.sh not found"
[[ -x "$PROVISIONER" ]] || chmod +x "$PROVISIONER"

# ── Provision each node ───────────────────────────────────────────────────────
# Nodes defined in .env as NODE_1_*, NODE_2_*, ..., NODE_n_*
# Required per node: NODE_n_VMID, NODE_n_IP, NODE_n_COUNTRY
# Optional per node: NODE_n_HOSTNAME (defaults to nordvpn-<country_lowercase>)

node_count=0
provisioned_nodes=()

for i in $(seq 1 20); do
  vmid_var="NODE_${i}_VMID"
  [[ -n "${!vmid_var:-}" ]] || break

  vmid="${!vmid_var}"
  ip_var="NODE_${i}_IP";           node_ip="${!ip_var:-}"
  country_var="NODE_${i}_COUNTRY"; country="${!country_var:-US}"
  hostname_var="NODE_${i}_HOSTNAME"
  hostname="${!hostname_var:-nordvpn-$(echo "$country" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')}"

  [[ -n "$node_ip" ]] || fail "NODE_${i}_IP is required in .env"

  echo ""
  log "══════════════════════════════════════════════════════════════"
  log "Node $i: $hostname  |  VMID $vmid  |  IP $node_ip  |  $country"
  log "══════════════════════════════════════════════════════════════"

  # shellcheck disable=SC2086
  bash "$PROVISIONER" \
    --proxmox-host     "$PROXMOX_HOST" \
    --proxmox-password "$PROXMOX_PASSWORD" \
    --vmid             "$vmid" \
    --hostname         "$hostname" \
    --ip               "$node_ip" \
    --country          "$country" \
    --subnet           "$SUBNET" \
    --gateway          "$GATEWAY" \
    --login-token      "$NORDVPN_TOKEN" \
    ${FORCE_FLAG}

  ok "Node $i ($hostname) provisioned"
  provisioned_nodes+=("$hostname|$node_ip|$country")
  ((node_count++))
done

if [[ $node_count -eq 0 ]]; then
  echo ""
  echo "ERROR: No nodes defined in .env."
  echo "  Add at least NODE_1_VMID, NODE_1_IP, NODE_1_COUNTRY to .env"
  exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log "══════════════════════════════════════════════════════════════"
log "All $node_count node(s) provisioned"
log "══════════════════════════════════════════════════════════════"
echo ""
echo "Route LAN clients through VPN by setting their default gateway:"
for entry in "${provisioned_nodes[@]}"; do
  IFS='|' read -r h ip c <<< "$entry"
  printf "  %-22s (%s)  →  gateway %s\n" "$h" "$c" "$ip"
done
echo ""
echo "For meshnet (route remote device traffic through this box):"
echo "  1. Install NordVPN on your remote device"
echo "  2. nordvpn set meshnet on"
echo "  3. nordvpn meshnet peer list   # find this node's *.nord address"
echo "  4. nordvpn meshnet peer connect <hostname>.nord"
echo ""
