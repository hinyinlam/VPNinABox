#!/usr/bin/env bash
# switch-mesh-ip-to-nordvpn-gw.sh - route a NordVPN Meshnet peer through a
# selected NordVPN LXC gateway.
#
# Modes:
#   1. Same-node exit: mesh peer enters an LXC and exits that same LXC's nordlynx.
#   2. Cross-node exit: mesh peer enters one LXC, then double-NATs through a
#      different LAN gateway LXC that exits via its own NordVPN country.
#
# Usage:
#   ./switch-mesh-ip-to-nordvpn-gw.sh --apply --src-mesh-ip 100.x.y.z --node 200
#   ./switch-mesh-ip-to-nordvpn-gw.sh --apply --src-mesh-ip 100.x.y.z --ingress-node 201 --exit-node 200
#   ./switch-mesh-ip-to-nordvpn-gw.sh --remove --src-mesh-ip 100.x.y.z --ingress-node 201 --exit-node 200
#   ./switch-mesh-ip-to-nordvpn-gw.sh --list --ingress-node 201
#
# Dry-run/testing helpers:
#   Add --dry-run plus --ingress-ip/--exit-ip to print the command plan without SSH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults mirror the rest of this repository and can be overridden by .env/flags.
LAN_SUBNET="192.168.1.0/24"
MESH_SUBNET="100.64.0.0/10"
PROXMOX_HOST=""
PROXMOX_PASSWORD=""
PROXMOX_USER="root"

MODE=""
SRC_MESH_IP=""
INGRESS_NODE=""
EXIT_NODE=""
INGRESS_IP=""
EXIT_IP=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage:
  switch-mesh-ip-to-nordvpn-gw.sh --apply --src-mesh-ip <100.x.y.z> --node <vmid>
  switch-mesh-ip-to-nordvpn-gw.sh --apply --src-mesh-ip <100.x.y.z> --ingress-node <vmid> --exit-node <vmid>
  switch-mesh-ip-to-nordvpn-gw.sh --remove --src-mesh-ip <100.x.y.z> --ingress-node <vmid> --exit-node <vmid>
  switch-mesh-ip-to-nordvpn-gw.sh --list --ingress-node <vmid>

Options:
  --node <vmid>          Same-node shortcut; sets ingress-node and exit-node.
  --ingress-node <vmid>  LXC receiving traffic from the Meshnet source.
  --exit-node <vmid>     LXC used as the NordVPN exit gateway.
  --src-mesh-ip <ip>     Meshnet source IP to route.
  --ingress-ip <ip>      Optional/manual ingress LXC LAN IP; required with --dry-run.
  --exit-ip <ip>         Optional/manual exit LXC LAN IP; required with --dry-run.
  --lan-subnet <cidr>    LAN subnet routed locally before default VPN exit.
  --mesh-subnet <cidr>   Meshnet subnet, default 100.64.0.0/10.
  --dry-run              Print the route/NAT plan without SSH or route changes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --remove) MODE="remove"; shift ;;
    --list) MODE="list"; shift ;;
    --node) INGRESS_NODE="$2"; EXIT_NODE="$2"; shift 2 ;;
    --ingress-node) INGRESS_NODE="$2"; shift 2 ;;
    --exit-node) EXIT_NODE="$2"; shift 2 ;;
    --src-mesh-ip) SRC_MESH_IP="$2"; shift 2 ;;
    --ingress-ip) INGRESS_IP="$2"; shift 2 ;;
    --exit-ip) EXIT_IP="$2"; shift 2 ;;
    --lan-subnet) LAN_SUBNET="$2"; shift 2 ;;
    --mesh-subnet) MESH_SUBNET="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }

is_ipv4() {
  local ip="$1" part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

is_cidr() {
  local cidr="$1" ip prefix
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  is_ipv4 "$ip" || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1
}

require_vmid() {
  local value="$1" label="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$label must be a numeric Proxmox VMID"
}

last_octet() {
  local ip="$1"
  echo "${ip##*.}"
}

table_id_for_exit_ip() {
  local ip="$1"
  echo $((1000 + $(last_octet "$ip")))
}

priority_for_src_ip() {
  local ip="$1"
  echo $((10000 + $(last_octet "$ip")))
}

load_env() {
  local env_file="${SCRIPT_DIR}/.env"
  [[ -f "$env_file" ]] || fail ".env not found. Copy .env.example to .env and fill in Proxmox credentials."

  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a

  PROXMOX_HOST="${PROXMOX_HOST:-}"
  PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
  LAN_SUBNET="${SUBNET:-$LAN_SUBNET}"

  [[ -n "$PROXMOX_HOST" ]] || fail "PROXMOX_HOST missing in .env"
  [[ -n "$PROXMOX_PASSWORD" ]] || fail "PROXMOX_PASSWORD missing in .env"
}

pxm_ssh() {
  sshpass -p "$PROXMOX_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=8 \
    "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
}

discover_lxc_ip() {
  local vmid="$1"
  pxm_ssh "pct config ${vmid}" \
    | awk '/^net0:/ { if (match($0, /ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) { print substr($0, RSTART + 3, RLENGTH - 3); exit } }'
}

validate_common() {
  [[ -n "$MODE" ]] || { usage; exit 1; }
  [[ "$MODE" == "apply" || "$MODE" == "remove" || "$MODE" == "list" ]] || fail "invalid mode: $MODE"

  [[ -n "$INGRESS_NODE" ]] || fail "--ingress-node or --node is required"
  require_vmid "$INGRESS_NODE" "--ingress-node"

  is_cidr "$LAN_SUBNET" || fail "--lan-subnet must be a valid IPv4 CIDR"
  is_cidr "$MESH_SUBNET" || fail "--mesh-subnet must be a valid IPv4 CIDR"

  if [[ "$MODE" != "list" ]]; then
    [[ -n "$SRC_MESH_IP" ]] || fail "--src-mesh-ip is required"
    is_ipv4 "$SRC_MESH_IP" || fail "--src-mesh-ip must be a valid IPv4 address"
    [[ -n "$EXIT_NODE" ]] || fail "--exit-node or --node is required"
    require_vmid "$EXIT_NODE" "--exit-node"
  fi
}

resolve_ips() {
  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$MODE" != "list" ]]; then
      [[ -n "$INGRESS_IP" ]] || fail "--ingress-ip is required with --dry-run"
      [[ -n "$EXIT_IP" ]] || fail "--exit-ip is required with --dry-run"
    fi
  else
    load_env
    [[ -n "$INGRESS_IP" ]] || INGRESS_IP="$(discover_lxc_ip "$INGRESS_NODE")"
    if [[ "$MODE" != "list" ]]; then
      [[ -n "$EXIT_IP" ]] || EXIT_IP="$(discover_lxc_ip "$EXIT_NODE")"
    fi
  fi

  if [[ "$MODE" != "list" ]]; then
    is_ipv4 "$INGRESS_IP" || fail "could not determine a valid ingress LXC IP"
    is_ipv4 "$EXIT_IP" || fail "could not determine a valid exit LXC IP"
  fi
}

route_mode() {
  if [[ "$INGRESS_NODE" == "$EXIT_NODE" || "$INGRESS_IP" == "$EXIT_IP" ]]; then
    echo "same-node"
  else
    echo "cross-node-double-nat"
  fi
}

normalize_same_node_exit() {
  if [[ "$INGRESS_NODE" == "$EXIT_NODE" || "$INGRESS_IP" == "$EXIT_IP" ]]; then
    EXIT_NODE="$INGRESS_NODE"
    EXIT_IP="$INGRESS_IP"
  fi
}

render_plan() {
  local action="$1" mode_name="$2" table_id="$3" priority="$4"

  echo "ACTION=${action}"
  echo "MODE=${mode_name}"
  echo "INGRESS_NODE=${INGRESS_NODE}"
  [[ -n "$EXIT_NODE" ]] && echo "EXIT_NODE=${EXIT_NODE}"
  [[ -n "$SRC_MESH_IP" ]] && echo "SRC_MESH_IP=${SRC_MESH_IP}"
  [[ -n "$INGRESS_IP" ]] && echo "INGRESS_IP=${INGRESS_IP}"
  [[ -n "$EXIT_IP" ]] && echo "EXIT_IP=${EXIT_IP}"
  echo "LAN_SUBNET=${LAN_SUBNET}"
  echo "MESH_SUBNET=${MESH_SUBNET}"
  echo "TABLE_ID=${table_id}"
  echo "PRIORITY=${priority}"
  echo ""

  if [[ "$action" == "list" ]]; then
    echo "cat /etc/nordvpn-mesh-routing/routes.tsv"
    echo "ip rule list"
    return
  fi

  if [[ "$action" == "apply" ]]; then
    echo "ip route replace ${LAN_SUBNET} dev eth0 table ${table_id}"
    echo "ip route replace ${MESH_SUBNET} dev nordlynx table ${table_id}"
    if [[ "$mode_name" == "same-node" ]]; then
      echo "ip route replace default dev nordlynx table ${table_id}"
    else
      echo "ip route replace default via ${EXIT_IP} dev eth0 table ${table_id}"
    fi
    echo "ip rule add from ${SRC_MESH_IP}/32 priority ${priority} table ${table_id}"
    if [[ "$mode_name" == "same-node" ]]; then
      echo "iptables -C FORWARD -s ${SRC_MESH_IP}/32 -o nordlynx -j ACCEPT"
      echo "iptables -t nat -C POSTROUTING -s ${SRC_MESH_IP}/32 -d ${LAN_SUBNET} -o nordlynx -j RETURN"
      echo "iptables -t nat -C POSTROUTING -s ${SRC_MESH_IP}/32 -d ${MESH_SUBNET} -o nordlynx -j RETURN"
      echo "iptables -t nat -C POSTROUTING -s ${SRC_MESH_IP}/32 -o nordlynx -j MASQUERADE"
    else
      echo "iptables -C FORWARD -s ${SRC_MESH_IP}/32 -o eth0 -j ACCEPT"
      echo "iptables -t mangle -C POSTROUTING -s ${SRC_MESH_IP}/32 ! -d ${LAN_SUBNET} -o eth0 -j ACCEPT"
      echo "iptables -t mangle -C PREROUTING -i eth0 -d ${INGRESS_IP}/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
      echo "iptables -t nat -C POSTROUTING -s ${SRC_MESH_IP}/32 ! -d ${LAN_SUBNET} -o eth0 -j SNAT --to-source ${INGRESS_IP}"
    fi
    return
  fi

  echo "ip rule del from ${SRC_MESH_IP}/32 priority ${priority} table ${table_id}"
  echo "iptables -D FORWARD -s ${SRC_MESH_IP}/32 -o nordlynx -j ACCEPT"
  echo "iptables -D FORWARD -s ${SRC_MESH_IP}/32 -o eth0 -j ACCEPT"
  echo "iptables -t mangle -D POSTROUTING -s ${SRC_MESH_IP}/32 ! -d ${LAN_SUBNET} -o eth0 -j ACCEPT"
  echo "iptables -t mangle -D PREROUTING -i eth0 -d ${INGRESS_IP}/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  echo "iptables -t nat -D POSTROUTING -s ${SRC_MESH_IP}/32 -d ${LAN_SUBNET} -o nordlynx -j RETURN"
  echo "iptables -t nat -D POSTROUTING -s ${SRC_MESH_IP}/32 -d ${MESH_SUBNET} -o nordlynx -j RETURN"
  echo "iptables -t nat -D POSTROUTING -s ${SRC_MESH_IP}/32 -o nordlynx -j MASQUERADE"
  echo "iptables -t nat -D POSTROUTING -s ${SRC_MESH_IP}/32 ! -d ${LAN_SUBNET} -o eth0 -j SNAT --to-source ${INGRESS_IP}"
}

run_lxc_route_update() {
  local action="$1" mode_name="$2" table_id="$3" priority="$4"

  pxm_ssh "pct exec ${INGRESS_NODE} -- env ACTION=${action} SRC_MESH_IP=${SRC_MESH_IP} INGRESS_IP=${INGRESS_IP} EXIT_IP=${EXIT_IP} MODE_NAME=${mode_name} TABLE_ID=${table_id} PRIORITY=${priority} LAN_SUBNET=${LAN_SUBNET} MESH_SUBNET=${MESH_SUBNET} bash -s" <<'REMOTE'
set -euo pipefail

STATE_DIR="/etc/nordvpn-mesh-routing"
STATE_FILE="${STATE_DIR}/routes.tsv"
RESTORE_SCRIPT="/usr/local/bin/nordvpn-mesh-route-restore.sh"
SERVICE_FILE="/etc/systemd/system/nordvpn-mesh-routing.service"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

cat > "$RESTORE_SCRIPT" <<'RESTORE'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/etc/nordvpn-mesh-routing/routes.tsv"
[[ -f "$STATE_FILE" ]] || exit 0

iptables_rule_exists() { iptables -C "$@" 2>/dev/null; }
nat_rule_exists() { iptables -t nat -C "$@" 2>/dev/null; }
mangle_rule_exists() { iptables -t mangle -C "$@" 2>/dev/null; }

remove_rules_for_source() {
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

wait_for_nordlynx() {
  local retries=10
  while ! ip link show nordlynx >/dev/null 2>&1 && [[ $retries -gt 0 ]]; do
    sleep 2
    retries=$((retries - 1))
  done
  ip link show nordlynx >/dev/null 2>&1
}

while IFS=$'\t' read -r src ingress_ip exit_ip mode_name table_id priority lan_subnet mesh_subnet; do
  [[ -z "${src:-}" || "${src:0:1}" == "#" ]] && continue

  if [[ "$mode_name" == "same-node" ]]; then
    wait_for_nordlynx || { echo "nordlynx not ready; skipping ${src}" >&2; continue; }
    remove_rules_for_source "$src" "$ingress_ip" "$table_id" "$priority" "$lan_subnet" "$mesh_subnet"
    ip route replace "$lan_subnet" dev eth0 table "$table_id"
    ip route replace "$mesh_subnet" dev nordlynx table "$table_id"
    ip route replace default dev nordlynx table "$table_id"
    ip rule add from "${src}/32" priority "$priority" table "$table_id"
    iptables_rule_exists FORWARD -s "${src}/32" -o nordlynx -j ACCEPT \
      || iptables -I FORWARD 1 -s "${src}/32" -o nordlynx -j ACCEPT
    nat_rule_exists POSTROUTING -s "${src}/32" -d "$lan_subnet" -o nordlynx -j RETURN \
      || iptables -t nat -I POSTROUTING 1 -s "${src}/32" -d "$lan_subnet" -o nordlynx -j RETURN
    nat_rule_exists POSTROUTING -s "${src}/32" -d "$mesh_subnet" -o nordlynx -j RETURN \
      || iptables -t nat -I POSTROUTING 1 -s "${src}/32" -d "$mesh_subnet" -o nordlynx -j RETURN
    nat_rule_exists POSTROUTING -s "${src}/32" -o nordlynx -j MASQUERADE \
      || iptables -t nat -A POSTROUTING -s "${src}/32" -o nordlynx -j MASQUERADE
  else
    wait_for_nordlynx || true
    remove_rules_for_source "$src" "$ingress_ip" "$table_id" "$priority" "$lan_subnet" "$mesh_subnet"
    ip route replace "$lan_subnet" dev eth0 table "$table_id"
    if ip link show nordlynx >/dev/null 2>&1; then
      ip route replace "$mesh_subnet" dev nordlynx table "$table_id"
    fi
    ip route replace default via "$exit_ip" dev eth0 table "$table_id"
    ip rule add from "${src}/32" priority "$priority" table "$table_id"
    iptables_rule_exists FORWARD -s "${src}/32" -o eth0 -j ACCEPT \
      || iptables -I FORWARD 1 -s "${src}/32" -o eth0 -j ACCEPT
    mangle_rule_exists POSTROUTING -s "${src}/32" ! -d "$lan_subnet" -o eth0 -j ACCEPT \
      || iptables -t mangle -I POSTROUTING 1 -s "${src}/32" ! -d "$lan_subnet" -o eth0 -j ACCEPT
    mangle_rule_exists PREROUTING -i eth0 -d "${ingress_ip}/32" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT \
      || iptables -t mangle -I PREROUTING 1 -i eth0 -d "${ingress_ip}/32" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    nat_rule_exists POSTROUTING -s "${src}/32" ! -d "$lan_subnet" -o eth0 -j SNAT --to-source "$ingress_ip" \
      || iptables -t nat -I POSTROUTING 1 -s "${src}/32" ! -d "$lan_subnet" -o eth0 -j SNAT --to-source "$ingress_ip"
  fi
done < "$STATE_FILE"
RESTORE

chmod +x "$RESTORE_SCRIPT"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NordVPN mesh source routing restore
After=network-online.target nordvpnd.service nordvpn-autoconnect.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RESTORE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/nordvpn-mesh-routing.timer <<EOF
[Unit]
Description=Restore NordVPN mesh source routing periodically
Requires=nordvpn-mesh-routing.service

[Timer]
OnBootSec=120s
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

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

tmp_file="${STATE_FILE}.tmp"
grep -v -F "${SRC_MESH_IP}"$'\t' "$STATE_FILE" > "$tmp_file" || true

if [[ "$ACTION" == "apply" ]]; then
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$SRC_MESH_IP" "$INGRESS_IP" "$EXIT_IP" "$MODE_NAME" "$TABLE_ID" "$PRIORITY" "$LAN_SUBNET" "$MESH_SUBNET" \
    >> "$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
  systemctl daemon-reload
  systemctl enable nordvpn-mesh-routing.service >/dev/null 2>&1 || true
  systemctl enable --now nordvpn-mesh-routing.timer >/dev/null 2>&1 || true
  "$RESTORE_SCRIPT"
else
  mv "$tmp_file" "$STATE_FILE"
  remove_runtime_rules "$SRC_MESH_IP" "$INGRESS_IP" "$TABLE_ID" "$PRIORITY" "$LAN_SUBNET" "$MESH_SUBNET"
fi

echo "${ACTION} complete for ${SRC_MESH_IP} (${MODE_NAME})"
REMOTE
}

run_lxc_list() {
  pxm_ssh "pct exec ${INGRESS_NODE} -- bash -s" <<'REMOTE'
set -euo pipefail
state_file="/etc/nordvpn-mesh-routing/routes.tsv"
echo "Saved mesh routes:"
if [[ -f "$state_file" && -s "$state_file" ]]; then
  cat "$state_file"
else
  echo "(none)"
fi
echo ""
echo "Active source rules:"
ip rule list | grep '100\.' || true
REMOTE
}

main() {
  validate_common
  resolve_ips
  is_cidr "$LAN_SUBNET" || fail "SUBNET from .env must be a valid IPv4 CIDR"
  is_cidr "$MESH_SUBNET" || fail "--mesh-subnet must be a valid IPv4 CIDR"
  normalize_same_node_exit

  local mode_name="list" table_id="" priority=""
  if [[ "$MODE" != "list" ]]; then
    mode_name="$(route_mode)"
    table_id="$(table_id_for_exit_ip "$EXIT_IP")"
    priority="$(priority_for_src_ip "$SRC_MESH_IP")"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    render_plan "$MODE" "$mode_name" "${table_id:-}" "${priority:-}"
    exit 0
  fi

  if [[ "$MODE" == "list" ]]; then
    run_lxc_list
    exit 0
  fi

  log "${MODE}: mesh ${SRC_MESH_IP} ingress=${INGRESS_NODE}/${INGRESS_IP} exit=${EXIT_NODE}/${EXIT_IP} mode=${mode_name}"
  run_lxc_route_update "$MODE" "$mode_name" "$table_id" "$priority"
}

main
