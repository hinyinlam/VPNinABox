#!/usr/bin/env bash
# nordvpn-setup.sh — idempotent setup for NordVPN LXC as:
#   1. VPN exit node (LAN subnet → NordVPN)
#   2. Meshnet exit node (meshnet peers → this box → internet)
#
# Deploy to LXC:
#   pct push <vmid> nordvpn-setup.sh /usr/local/bin/nordvpn-setup.sh --perms 0755
#
# Usage:
#   nordvpn-setup.sh [--country Taiwan] [--subnet 192.168.1.0/24] [--install] [--verify]
#
# Env overrides:
#   NORDVPN_COUNTRY, NORDVPN_LAN_SUBNET, NORDVPN_INSTALL, NORDVPN_VERIFY
#
# Requires: root, nordvpn daemon running, logged in via token or browser

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
COUNTRY="${NORDVPN_COUNTRY:-Taiwan}"
LAN_SUBNET="${NORDVPN_LAN_SUBNET:-192.168.1.0/24}"
MESHNET_SUBNET="100.64.0.0/10"
INSTALL="${NORDVPN_INSTALL:-false}"
VERIFY_ONLY="${NORDVPN_VERIFY:-false}"

# ── Flags ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --country)    COUNTRY="$2";      shift 2 ;;
    --subnet)     LAN_SUBNET="$2";   shift 2 ;;
    --install)    INSTALL=true;      shift   ;;
    --verify)     VERIFY_ONLY=true;  shift   ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }
iptables_rule_exists() { iptables -C "$@" 2>/dev/null; }

[[ $EUID -eq 0 ]] || fail "Run as root"

# ── 1. Install ────────────────────────────────────────────────────────────────
install_nordvpn() {
  log "Checking NordVPN install..."
  if command -v nordvpn &>/dev/null; then
    ok "nordvpn already installed"
    return
  fi
  [[ "$INSTALL" == "true" ]] || fail "NordVPN not found. Re-run with --install to install."
  curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh
  usermod -aG nordvpn root
  systemctl enable --now nordvpnd
  sleep 5
  ok "NordVPN installed"
}

# ── 2. Login check ────────────────────────────────────────────────────────────
verify_login() {
  log "Checking login..."
  nordvpn account 2>&1 | grep -qi "email address" \
    && ok "Logged in" \
    || fail "Not logged in. Run: nordvpn login --token <TOKEN>"
}

# ── 3. NordVPN settings ───────────────────────────────────────────────────────
configure_nordvpn() {
  log "Configuring NordVPN settings..."
  nordvpn set technology NORDLYNX           2>/dev/null || true
  nordvpn set firewall on                   2>/dev/null || true
  nordvpn set routing on                    2>/dev/null || true
  nordvpn set meshnet on                    2>/dev/null || true
  nordvpn set lan-discovery on              2>/dev/null || true
  nordvpn set autoconnect on "$COUNTRY"     2>/dev/null || true
  nordvpn set killswitch off                2>/dev/null || true  # LAN stays reachable if VPN drops
  ok "Settings applied"
}

# ── 4. Meshnet peer permissions ───────────────────────────────────────────────
configure_meshnet_peers() {
  log "Enabling routing for all meshnet peers..."
  local this_host peers
  this_host=$(nordvpn meshnet peer list 2>/dev/null \
    | awk '/^This device/{found=1} found && /^Hostname:/{print $2; exit}')
  peers=$(nordvpn meshnet peer list 2>/dev/null \
    | grep "^Hostname:" | awk '{print $2}' \
    | grep -v "^${this_host}$" || true)

  if [[ -z "$peers" ]]; then
    ok "No remote peers (will apply when peers connect)"
    return
  fi

  while IFS= read -r peer; do
    [[ -z "$peer" ]] && continue
    log "  Peer: $peer"
    nordvpn meshnet peer routing allow  "$peer" 2>/dev/null && ok "    routing allowed"    || true
    nordvpn meshnet peer local allow    "$peer" 2>/dev/null && ok "    LAN access allowed" || true
    nordvpn meshnet peer incoming allow "$peer" 2>/dev/null && ok "    incoming allowed"   || true
  done <<< "$peers"
}

# ── 5. Connect VPN ────────────────────────────────────────────────────────────
connect_vpn() {
  log "Connecting to $COUNTRY..."
  local status current_country
  status=$(nordvpn status 2>/dev/null | grep "^Status:" | awk '{print $2}')
  if [[ "$status" == "Connected" ]]; then
    current_country=$(nordvpn status 2>/dev/null | grep "^Country:" | awk '{print $2}')
    if [[ "$current_country" == "$COUNTRY" ]]; then
      ok "Already connected to $COUNTRY"
      return
    fi
    log "  Switching from $current_country to $COUNTRY..."
  fi
  nordvpn connect "$COUNTRY" 2>/dev/null
  sleep 3
  nordvpn status 2>/dev/null | grep -E "^Status:|^Country:|^IP:" \
    | while read -r line; do ok "$line"; done
}

# ── 6. IP forwarding ──────────────────────────────────────────────────────────
enable_ip_forwarding() {
  log "Enabling IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nordvpn-forward.conf
  ok "IP forwarding enabled (persistent)"
}

# ── 7. iptables ───────────────────────────────────────────────────────────────
apply_iptables() {
  log "Applying iptables rules..."

  # Wait up to 20s for nordlynx to appear after connect
  local retries=10
  while ! ip link show nordlynx &>/dev/null && [[ $retries -gt 0 ]]; do
    sleep 2; ((retries--))
  done
  ip link show nordlynx &>/dev/null || fail "nordlynx interface not found — is NordVPN connected?"

  # FORWARD: meshnet ↔ LAN (for meshnet peers using this box as exit node)
  iptables_rule_exists FORWARD -s "$MESHNET_SUBNET" -d "$LAN_SUBNET" -j ACCEPT \
    && ok "FORWARD meshnet→LAN already exists" \
    || { iptables -I FORWARD 1 -s "$MESHNET_SUBNET" -d "$LAN_SUBNET" -j ACCEPT
         ok "FORWARD meshnet→LAN added"; }

  iptables_rule_exists FORWARD -s "$LAN_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT \
    && ok "FORWARD LAN→meshnet already exists" \
    || { iptables -I FORWARD 2 -s "$LAN_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT
         ok "FORWARD LAN→meshnet added"; }

  # NAT: LAN subnet clients exit via VPN (client must set gateway=this LXC's IP)
  iptables_rule_exists nat POSTROUTING -s "$LAN_SUBNET" -o nordlynx -j MASQUERADE \
    && ok "NAT LAN→nordlynx already exists" \
    || { iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o nordlynx -j MASQUERADE
         ok "NAT LAN→nordlynx MASQUERADE added"; }

  # Persist
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null && ok "iptables rules persisted" || true
}

# ── 8. Systemd services ───────────────────────────────────────────────────────
install_systemd_services() {
  log "Installing systemd services..."

  cat > /etc/systemd/system/nordvpn-autoconnect.service << EOF
[Unit]
Description=NordVPN Auto-Connect to ${COUNTRY}
After=nordvpnd.service network-online.target
Wants=network-online.target
Requires=nordvpnd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/nordvpn connect ${COUNTRY}
ExecStartPost=/usr/bin/nordvpn set meshnet on

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/nordvpn-subnet-routing.service << EOF
[Unit]
Description=NordVPN Subnet Routing (meshnet + LAN NAT)
After=nordvpnd.service nordvpn-autoconnect.service
Wants=nordvpnd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nordvpn-setup.sh --country ${COUNTRY} --subnet ${LAN_SUBNET}
ExecStop=/usr/sbin/iptables -D FORWARD -s ${MESHNET_SUBNET} -d ${LAN_SUBNET} -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -s ${LAN_SUBNET} -d ${MESHNET_SUBNET} -j ACCEPT
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s ${LAN_SUBNET} -o nordlynx -j MASQUERADE

[Install]
WantedBy=multi-user.target
EOF

  # Retire old fragmented services
  systemctl disable nordvpn-meshnet.service meshnet-routes.service 2>/dev/null || true
  systemctl stop    nordvpn-meshnet.service meshnet-routes.service 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable nordvpn-autoconnect.service nordvpn-subnet-routing.service
  ok "Services nordvpn-autoconnect + nordvpn-subnet-routing enabled"
}

# ── 9. Verify ─────────────────────────────────────────────────────────────────
verify() {
  log "=== Verification ==="
  local status country exit_ip fwd_count nat_count fwd_sysctl
  status=$(nordvpn status 2>/dev/null | grep "^Status:" | awk '{print $2}')
  country=$(nordvpn status 2>/dev/null | grep "^Country:" | awk '{print $2}')
  exit_ip=$(curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null)
  fwd_count=$(iptables -L FORWARD -n 2>/dev/null | grep -c "100.64.0.0\|${LAN_SUBNET}" || true)
  nat_count=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -c "nordlynx" || true)
  fwd_sysctl=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)

  echo "  VPN status   : $status"
  echo "  Country      : $country"
  echo "  Exit IP      : $exit_ip"
  echo "  FORWARD rules: $fwd_count"
  echo "  NAT rules    : $nat_count"
  echo "  IP forwarding: $fwd_sysctl"

  [[ "$status"     == "Connected" ]] && ok "VPN connected"    || echo "  ✗ VPN not connected"
  [[ "$country"    == "$COUNTRY"  ]] && ok "Country correct"  || echo "  ✗ Country mismatch (got: $country, want: $COUNTRY)"
  [[ $fwd_count    -ge 2          ]] && ok "FORWARD rules OK" || echo "  ✗ FORWARD rules missing"
  [[ $nat_count    -ge 1          ]] && ok "NAT rule OK"      || echo "  ✗ NAT MASQUERADE missing"
  [[ "$fwd_sysctl" == "1"         ]] && ok "IP forwarding OK" || echo "  ✗ IP forwarding disabled"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  if [[ "$VERIFY_ONLY" == "true" ]]; then
    verify
    exit 0
  fi

  log "NordVPN setup: country=$COUNTRY subnet=$LAN_SUBNET"
  install_nordvpn
  verify_login
  configure_nordvpn
  configure_meshnet_peers
  connect_vpn
  enable_ip_forwarding
  apply_iptables
  install_systemd_services
  verify
  log "Done. Clients on $LAN_SUBNET: set gateway to this LXC's LAN IP to exit via VPN."
}

main
