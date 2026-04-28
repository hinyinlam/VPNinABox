#!/usr/bin/env bash
# nordvpn-setup.sh — idempotent setup for NordVPN LXC as:
#   1. VPN exit node (LAN subnet → NordVPN)
#   2. Meshnet exit node (meshnet peers → this box → internet)
#
# Deploy to LXC:
#   pct push <vmid> nordvpn-setup.sh /usr/local/bin/nordvpn-setup.sh --perms 0755
#
# Usage:
#   nordvpn-setup.sh [options]
#
# Options:
#   --country   <name>   VPN exit country (default: Taiwan)
#   --subnet    <cidr>   LAN subnet to forward through VPN (default: 192.168.1.0/24)
#   --name      <str>    Hostname to use for this machine + NordVPN meshnet identity.
#                        Defaults to nordvpn-<country_lowercase> (e.g. nordvpn-us, nordvpn-taiwan).
#   --login-token <tok>  NordVPN Personal Access Token for non-interactive login.
#                        IMPORTANT: Use a PAT from nordvpn.com/en/user/nordaccount-settings/tokens
#                        NOT the device token from "nordvpn token" — device tokens cannot
#                        register a new meshnet node on a different machine.
#   --install            Install NordVPN if not present
#   --verify             Only run verification checks, no changes
#
# Env overrides:
#   NORDVPN_COUNTRY, NORDVPN_LAN_SUBNET, NORDVPN_HOSTNAME, NORDVPN_TOKEN, NORDVPN_INSTALL, NORDVPN_VERIFY
#
# Requires: root, Debian/Ubuntu LXC

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
COUNTRY="${NORDVPN_COUNTRY:-Taiwan}"
LAN_SUBNET="${NORDVPN_LAN_SUBNET:-192.168.1.0/24}"
MESHNET_SUBNET="100.64.0.0/10"
DESIRED_HOSTNAME="${NORDVPN_HOSTNAME:-}"   # set after flag parsing; default derived from country
LOGIN_TOKEN="${NORDVPN_TOKEN:-}"
INSTALL="${NORDVPN_INSTALL:-false}"
VERIFY_ONLY="${NORDVPN_VERIFY:-false}"

# ── Flags ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --country)      COUNTRY="$2";           shift 2 ;;
    --subnet)       LAN_SUBNET="$2";        shift 2 ;;
    --name)         DESIRED_HOSTNAME="$2";  shift 2 ;;
    --login-token)  LOGIN_TOKEN="$2";       shift 2 ;;
    --install)      INSTALL=true;           shift   ;;
    --verify)       VERIFY_ONLY=true;       shift   ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Derive default hostname from country if not explicitly set
if [[ -z "$DESIRED_HOSTNAME" ]]; then
  DESIRED_HOSTNAME="nordvpn-$(echo "$COUNTRY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }
iptables_rule_exists() { iptables -C "$@" 2>/dev/null; }

# Run nordvpn command, retry up to N times on transient "trouble reaching servers" errors
nordvpn_retry() {
  local max="${1}"; shift
  local delay=5
  local attempt=0
  while [[ $attempt -lt $max ]]; do
    local out
    out=$(nordvpn "$@" 2>&1) && { echo "$out"; return 0; }
    if echo "$out" | grep -qi "trouble reaching\|connection refused\|daemon"; then
      ((attempt++))
      warn "nordvpn $* failed (attempt $attempt/$max), retrying in ${delay}s..."
      sleep "$delay"
    else
      echo "$out"
      return 0  # non-transient failure — return but don't abort (callers use || true)
    fi
  done
  echo "$out"
  return 1
}

[[ $EUID -eq 0 ]] || fail "Run as root"

# ── 0. Hostname ───────────────────────────────────────────────────────────────
# Sets system hostname = NordVPN meshnet identity for this node.
# nordvpnd reads /etc/hostname on registration; restart daemon after any change.
set_hostname() {
  local current
  current=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")
  if [[ "$current" == "$DESIRED_HOSTNAME" ]]; then
    ok "Hostname already set to $DESIRED_HOSTNAME"
    return
  fi
  log "Setting hostname: $current → $DESIRED_HOSTNAME"
  hostnamectl set-hostname "$DESIRED_HOSTNAME" 2>/dev/null \
    || echo "$DESIRED_HOSTNAME" > /etc/hostname

  # Update /etc/hosts — replace old hostname entry so DNS resolves locally
  if grep -q "$current" /etc/hosts 2>/dev/null; then
    sed -i "s/\b${current}\b/$DESIRED_HOSTNAME/g" /etc/hosts
  else
    grep -q "127.0.1.1" /etc/hosts \
      && sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$DESIRED_HOSTNAME/" /etc/hosts \
      || echo "127.0.1.1	$DESIRED_HOSTNAME" >> /etc/hosts
  fi

  # Restart nordvpnd if running so it re-registers with the new hostname in meshnet
  if systemctl is-active --quiet nordvpnd 2>/dev/null; then
    systemctl restart nordvpnd
    sleep 5
    ok "nordvpnd restarted — will register as $DESIRED_HOSTNAME in meshnet"
  fi
  ok "Hostname set to $DESIRED_HOSTNAME"
}

# ── 1. Install ────────────────────────────────────────────────────────────────
install_nordvpn() {
  log "Checking NordVPN install..."
  if command -v nordvpn &>/dev/null; then
    ok "nordvpn already installed ($(nordvpn --version 2>/dev/null | head -1))"
    return
  fi
  [[ "$INSTALL" == "true" ]] || fail "NordVPN not found. Re-run with --install to install."

  log "Installing prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y gnupg curl ca-certificates iptables iptables-persistent -qq

  log "Adding NordVPN apt repo..."
  rm -f /usr/share/keyrings/nordvpn.gpg
  curl -fsSL https://repo.nordvpn.com/gpg/nordvpn_public.asc \
    | gpg --batch --dearmor -o /usr/share/keyrings/nordvpn.gpg
  echo "deb [signed-by=/usr/share/keyrings/nordvpn.gpg] https://repo.nordvpn.com/deb/nordvpn/debian stable main" \
    > /etc/apt/sources.list.d/nordvpn.list
  apt-get update -qq
  apt-get install -y nordvpn -qq

  usermod -aG nordvpn root
  # Pin version to avoid unexpected meshnet-breaking upgrades
  apt-mark hold nordvpn 2>/dev/null || true
  systemctl enable --now nordvpnd
  sleep 5
  ok "NordVPN installed ($(nordvpn --version 2>/dev/null | head -1))"
}

# ── 2. Login ──────────────────────────────────────────────────────────────────
do_login() {
  if [[ -z "$LOGIN_TOKEN" ]]; then
    fail "Not logged in. Re-run with --login-token <TOKEN>  (get token from existing device: nordvpn token)"
  fi
  log "Logging in with token..."
  # First-run prompts for privacy consent — answer 'y' non-interactively
  printf 'y\n' | nordvpn login --token "$LOGIN_TOKEN" 2>&1 \
    | grep -v "^$" | head -5 || true
  sleep 3  # daemon needs time to register token before account check is valid
  ok "Logged in"
}

verify_login() {
  log "Checking login..."
  if nordvpn account 2>&1 | grep -qi "email address"; then
    ok "Logged in ($(nordvpn account 2>/dev/null | grep -i 'email address' | awk -F': ' '{print $2}'))"
  else
    do_login
    # Re-verify
    nordvpn account 2>&1 | grep -qi "email address" \
      && ok "Logged in" \
      || fail "Login failed. Check token."
  fi
}

# ── 3. NordVPN settings ───────────────────────────────────────────────────────
configure_nordvpn() {
  log "Configuring NordVPN settings..."
  nordvpn_retry 3 set technology NORDLYNX       2>/dev/null || true
  nordvpn_retry 3 set firewall on               2>/dev/null || true
  nordvpn_retry 3 set routing on                2>/dev/null || true
  nordvpn_retry 3 set lan-discovery on          2>/dev/null || true
  nordvpn_retry 3 set autoconnect on "$COUNTRY" 2>/dev/null || true
  nordvpn_retry 3 set killswitch off            2>/dev/null || true

  # Meshnet needs API access — retry with backoff on fresh installs
  log "  Enabling meshnet (retrying until API is reachable)..."
  local retries=6
  while [[ $retries -gt 0 ]]; do
    local out
    out=$(nordvpn set meshnet on 2>&1) || true
    if echo "$out" | grep -qi "already enabled\|successfully"; then
      ok "Meshnet enabled"
      # Set this device's meshnet nickname to the system hostname.
      # NordVPN rejects names starting with "nordvpn-" (reserved prefix),
      # so strip it: "nordvpn-us" → "us-exit", plain names used as-is.
      local raw_nick="${DESIRED_HOSTNAME#nordvpn-}"
      local mesh_nick="${raw_nick}-exit"
      local nick_out
      nick_out=$(nordvpn meshnet set nickname "$mesh_nick" 2>&1) || true
      if echo "$nick_out" | grep -qi "now set to"; then
        ok "Meshnet nickname set to $mesh_nick"
      elif echo "$nick_out" | grep -qi "already\|unavailable"; then
        warn "Meshnet nickname skipped: $nick_out"
      elif echo "$nick_out" | grep -qi "trouble\|having trouble\|it's not you"; then
        warn "Meshnet nickname API transiently unavailable — will retry on next run"
      else
        warn "Meshnet nickname: $nick_out"
      fi
      break
    elif echo "$out" | grep -qi "maximum device count\|device limit"; then
      warn "Meshnet device limit reached on this NordVPN account."
      warn "Remove stale devices at: https://my.nordaccount.com/dashboard/nordvpn/meshnet/"
      warn "Then re-run: nordvpn set meshnet on   (or let the watchdog service retry)"
      break
    elif echo "$out" | grep -qi "trouble reaching\|connection refused"; then
      ((retries--))
      warn "Meshnet API not ready, retrying in 10s... ($retries left)"
      sleep 10
    else
      warn "Meshnet: $out"
      break
    fi
  done

  ok "Settings applied"
}

# ── 4. Meshnet peer permissions ───────────────────────────────────────────────
configure_meshnet_peers() {
  log "Enabling routing for all meshnet peers..."

  # Guard: bail gracefully if meshnet is not enabled yet
  local peer_list
  peer_list=$(nordvpn meshnet peer list 2>&1) || true
  if echo "$peer_list" | grep -qi "not enabled\|trouble reaching\|connection refused"; then
    warn "Meshnet not ready — skipping peer config (re-run script after VPN connects)"
    return
  fi

  # Safe extraction — avoid pipefail on empty results
  local this_host
  this_host=$(echo "$peer_list" \
    | awk '/^This device/{found=1} found && /^Hostname:/{print $2; exit}') || true

  local peers
  peers=$(echo "$peer_list" \
    | grep "^Hostname:" | awk '{print $2}' \
    | { [[ -n "$this_host" ]] && grep -v "^${this_host}$" || cat; }) || true

  if [[ -z "$peers" ]]; then
    ok "No remote peers found (will apply when peers connect)"
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

  # Retry connect — API may be briefly unreachable after fresh setup
  local retries=5
  while [[ $retries -gt 0 ]]; do
    status=$(nordvpn status 2>/dev/null | grep "^Status:" | awk '{print $2}' || echo "Unknown")
    if [[ "$status" == "Connected" ]]; then
      # Use grep -i for case-insensitive partial match (handles "United States" vs "US")
      if nordvpn status 2>/dev/null | grep -qi "Country:.*${COUNTRY}"; then
        ok "Already connected to $COUNTRY"
        return
      fi
      current_country=$(nordvpn status 2>/dev/null | grep "^Country:" | awk -F': ' '{print $2}')
      log "  Switching from $current_country to $COUNTRY..."
    fi

    local out
    out=$(nordvpn connect "$COUNTRY" 2>&1) || true
    if echo "$out" | grep -qi "You are connected"; then
      nordvpn status 2>/dev/null | grep -E "^Status:|^Country:|^IP:" \
        | while read -r line; do ok "$line"; done
      return
    elif echo "$out" | grep -qi "trouble reaching\|connection refused"; then
      ((retries--))
      warn "VPN connect failed, retrying in 10s... ($retries left)"
      sleep 10
    else
      # Non-transient error (e.g. invalid country)
      fail "VPN connect failed: $out"
    fi
  done
  fail "VPN connect to $COUNTRY failed after retries"
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

  # FORWARD: meshnet ↔ LAN (meshnet peers route through this box)
  iptables_rule_exists FORWARD -s "$MESHNET_SUBNET" -d "$LAN_SUBNET" -j ACCEPT \
    && ok "FORWARD meshnet→LAN already exists" \
    || { iptables -I FORWARD 1 -s "$MESHNET_SUBNET" -d "$LAN_SUBNET" -j ACCEPT
         ok "FORWARD meshnet→LAN added"; }

  iptables_rule_exists FORWARD -s "$LAN_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT \
    && ok "FORWARD LAN→meshnet already exists" \
    || { iptables -I FORWARD 2 -s "$LAN_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT
         ok "FORWARD LAN→meshnet added"; }

  # NAT: LAN subnet clients exit via VPN (client sets gateway to this LXC's IP)
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

  local token_arg=""
  [[ -n "$LOGIN_TOKEN" ]] && token_arg=" --login-token ${LOGIN_TOKEN}"

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
ExecStart=/usr/local/bin/nordvpn-setup.sh --country ${COUNTRY} --subnet ${LAN_SUBNET}${token_arg}
ExecStop=/usr/sbin/iptables -D FORWARD -s ${MESHNET_SUBNET} -d ${LAN_SUBNET} -j ACCEPT
ExecStop=/usr/sbin/iptables -D FORWARD -s ${LAN_SUBNET} -d ${MESHNET_SUBNET} -j ACCEPT
ExecStop=/usr/sbin/iptables -t nat -D POSTROUTING -s ${LAN_SUBNET} -o nordlynx -j MASQUERADE

[Install]
WantedBy=multi-user.target
EOF

  # Watchdog: checks VPN + meshnet + iptables every 60s, self-heals if anything is down
  cat > /etc/systemd/system/nordvpn-watchdog.service << EOF
[Unit]
Description=NordVPN watchdog health check
After=nordvpnd.service nordvpn-autoconnect.service
Wants=nordvpnd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nordvpn-watchdog.sh
Environment=NORDVPN_LAN_SUBNET=${LAN_SUBNET}
StandardOutput=journal
StandardError=journal
EOF

  cat > /etc/systemd/system/nordvpn-watchdog.timer << EOF
[Unit]
Description=NordVPN watchdog — run every 60s
Requires=nordvpn-watchdog.service

[Timer]
OnBootSec=120s
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  # Retire old fragmented services
  systemctl disable nordvpn-meshnet.service meshnet-routes.service 2>/dev/null || true
  systemctl stop    nordvpn-meshnet.service meshnet-routes.service 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable nordvpn-autoconnect.service nordvpn-subnet-routing.service
  systemctl enable --now nordvpn-watchdog.timer
  ok "Services nordvpn-autoconnect + nordvpn-subnet-routing + nordvpn-watchdog enabled"
}

# ── 9. Verify ─────────────────────────────────────────────────────────────────
verify() {
  log "=== Verification ==="
  local status country exit_ip fwd_count nat_count fwd_sysctl
  status=$(nordvpn status 2>/dev/null | grep "^Status:" | awk '{print $2}' || echo "Unknown")
  country=$(nordvpn status 2>/dev/null | grep "^Country:" | awk -F': ' '{print $2}' || echo "Unknown")
  exit_ip=$(curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null || echo "unreachable")
  fwd_count=$(iptables -L FORWARD -n 2>/dev/null | grep -c "100.64.0.0\|${LAN_SUBNET}" || true)
  nat_count=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -c "nordlynx" || true)
  fwd_sysctl=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")

  local mesh_hostname mesh_nickname
  mesh_hostname=$(nordvpn meshnet peer list 2>/dev/null \
    | awk '/^This device/{found=1} found && /^Hostname:/{print $2; exit}') || true
  mesh_nickname=$(nordvpn meshnet peer list 2>/dev/null \
    | awk '/^This device/{found=1} found && /^Nickname:/{if(NF>1) print $2; else print "-"; exit}') || true

  echo "  VPN status   : $status"
  echo "  Country      : $country"
  echo "  Exit IP      : $exit_ip"
  echo "  Mesh hostname: ${mesh_hostname:-not registered yet}"
  echo "  Mesh nickname: ${mesh_nickname:--}"
  echo "  System host  : $(hostname)"
  echo "  FORWARD rules: $fwd_count"
  echo "  NAT rules    : $nat_count"
  echo "  IP forwarding: $fwd_sysctl"

  [[ "$status" == "Connected" ]] && ok "VPN connected" || echo "  ✗ VPN not connected"
  # Verify exit country via ipinfo (handles code vs full-name mismatch, e.g. "US" vs "United States")
  local exit_country
  exit_country=$(curl -s --max-time 8 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ -n "$exit_country" ]]; then
    # Accept if nordvpn status country contains --country arg OR ipinfo country code present
    if nordvpn status 2>/dev/null | grep -qi "Country:.*${COUNTRY}" \
      || echo "$country" | grep -qi "$COUNTRY" \
      || echo "$COUNTRY" | grep -qi "$exit_country"; then
      ok "Country correct (nordvpn: $country, ipinfo: $exit_country)"
    else
      echo "  ✗ Country mismatch (nordvpn: $country, ipinfo: $exit_country, want: $COUNTRY)"
    fi
  else
    warn "Could not verify country via ipinfo (offline?)"
  fi
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

  log "NordVPN setup: country=$COUNTRY subnet=$LAN_SUBNET name=$DESIRED_HOSTNAME"
  set_hostname
  install_nordvpn
  verify_login
  configure_nordvpn
  connect_vpn
  # Retry meshnet after VPN connects — API is reachable now
  configure_nordvpn   # re-enables meshnet now that VPN is up
  configure_meshnet_peers
  enable_ip_forwarding
  apply_iptables
  install_systemd_services
  verify
  log "Done. Clients on $LAN_SUBNET: set gateway to this LXC's IP to exit via VPN."
}

main
