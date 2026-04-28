#!/usr/bin/env bash
# nordvpn-watchdog.sh — health daemon for NordVPN LXC gateway
#
# Driven by systemd timer (nordvpn-watchdog.timer, every 60s).
# Each run checks and self-heals:
#   1. VPN connected         → reconnect if not
#   2. nordlynx interface    → force reconnect if missing
#   3. Meshnet enabled       → re-enable if off
#   4. iptables rules intact → restore if missing
#
# Logs to syslog (tag: nordvpn-watchdog) and stdout (journald picks it up).
#
# Install: setup script pushes this to /usr/local/bin/nordvpn-watchdog.sh
# inside the LXC and installs the systemd service + timer units.

set -euo pipefail

LOG_TAG="nordvpn-watchdog"
MESHNET_SUBNET="100.64.0.0/10"

# ── Config ────────────────────────────────────────────────────────────────────
# LAN subnet: prefer env override, else read from nordvpn whitelist, else default
if [[ -n "${NORDVPN_LAN_SUBNET:-}" ]]; then
  LAN_SUBNET="$NORDVPN_LAN_SUBNET"
else
  LAN_SUBNET=$(nordvpn settings 2>/dev/null \
    | grep -i "allowlist.*subnet\|subnets" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1) || true
  LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"
fi

# Country: read from the autoconnect service ExecStart line, fall back to
# current VPN connection country, then hardcoded default.
COUNTRY=$(systemctl cat nordvpn-autoconnect.service 2>/dev/null \
  | awk '/ExecStart=.*connect/{print $NF}') || true
if [[ -z "$COUNTRY" || "$COUNTRY" == "on" ]]; then
  COUNTRY=$(nordvpn status 2>/dev/null | awk -F': ' '/^Country:/{print $2}') || true
fi
COUNTRY="${COUNTRY:-Taiwan}"

# ── Helpers ───────────────────────────────────────────────────────────────────
_log()  { local m="$*"; logger -t "$LOG_TAG" -- "$m"; echo "[$(date '+%H:%M:%S')] $m"; }
_ok()   { _log "OK  $*"; }
_warn() { _log "WARN $*"; }
_err()  { _log "ERR  $*"; }

_iptables_rule_exists() { iptables -C "$@" 2>/dev/null; }

RULES_CHANGED=false

# ── 1. VPN connectivity ───────────────────────────────────────────────────────
check_vpn() {
  local status country
  status=$(nordvpn status 2>/dev/null | awk '/^Status:/{print $2}') || status="Unknown"

  if [[ "$status" == "Connected" ]]; then
    country=$(nordvpn status 2>/dev/null | awk -F': ' '/^Country:/{print $2}') || country="?"
    _ok "VPN connected → $country"
    return 0
  fi

  _warn "VPN status=$status — reconnecting to $COUNTRY"
  local out
  out=$(nordvpn connect "$COUNTRY" 2>&1) || true
  if echo "$out" | grep -qi "You are connected"; then
    _ok "VPN reconnected to $COUNTRY"
  else
    _err "VPN reconnect failed: $(echo "$out" | head -1)"
  fi
}

# ── 2. nordlynx interface ─────────────────────────────────────────────────────
check_nordlynx() {
  if ip link show nordlynx &>/dev/null; then
    return 0
  fi
  _warn "nordlynx interface absent — waiting 10s then forcing reconnect"
  sleep 10
  if ! ip link show nordlynx &>/dev/null; then
    _err "nordlynx still missing — forcing nordvpn reconnect"
    nordvpn connect "$COUNTRY" 2>&1 | head -2 | while IFS= read -r l; do _log "$l"; done || true
  fi
}

# ── 3. Meshnet ────────────────────────────────────────────────────────────────
check_meshnet() {
  local state
  state=$(nordvpn settings 2>/dev/null | awk '/^Meshnet:/{print $2}') || state="unknown"

  if [[ "$state" == "enabled" ]]; then
    _ok "Meshnet enabled"
    return 0
  fi

  _warn "Meshnet $state — attempting re-enable"
  local out
  out=$(nordvpn set meshnet on 2>&1) || true

  if echo "$out" | grep -qi "already enabled\|successfully"; then
    _ok "Meshnet re-enabled"
  elif echo "$out" | grep -qi "maximum device count\|device limit"; then
    _err "Meshnet device limit reached — remove stale devices at:"
    _err "  https://my.nordaccount.com/dashboard/nordvpn/meshnet/"
    _err "Then run inside LXC: nordvpn set meshnet on"
  elif echo "$out" | grep -qi "trouble reaching\|connection refused"; then
    _warn "Meshnet API unreachable (transient) — will retry next cycle"
  else
    _warn "Meshnet enable: $(echo "$out" | head -1)"
  fi
}

# ── 4. iptables rules ─────────────────────────────────────────────────────────
check_iptables() {
  if ! ip link show nordlynx &>/dev/null; then
    _warn "Skipping iptables check — nordlynx not up"
    return 0
  fi

  if ! _iptables_rule_exists FORWARD -s "$MESHNET_SUBNET" -d "$LAN_SUBNET" -j ACCEPT; then
    _warn "Restoring FORWARD meshnet→LAN"
    iptables -I FORWARD 1 -s "$MESHNET_SUBNET" -d "$LAN_SUBNET" -j ACCEPT
    RULES_CHANGED=true
  fi

  if ! _iptables_rule_exists FORWARD -s "$LAN_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT; then
    _warn "Restoring FORWARD LAN→meshnet"
    iptables -I FORWARD 2 -s "$LAN_SUBNET" -d "$MESHNET_SUBNET" -j ACCEPT
    RULES_CHANGED=true
  fi

  # Use -t nat explicitly — _iptables_rule_exists prepends -C which works for FILTER
  # but nat table needs `iptables -t nat -C`.
  # Also deduplicate: remove all copies then add one, preventing accumulation when
  # nordvpnd clears and re-adds during reconnect and watchdog races it.
  local nat_count
  nat_count=$(iptables -t nat -L POSTROUTING -n 2>/dev/null \
    | grep -c "MASQUERADE.*192.168.1.0/24\|192.168.1.0/24.*MASQUERADE") || nat_count=0
  if [[ "$nat_count" -eq 0 ]]; then
    _warn "Restoring NAT MASQUERADE LAN→nordlynx"
    iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o nordlynx -j MASQUERADE
    RULES_CHANGED=true
  elif [[ "$nat_count" -gt 1 ]]; then
    _warn "Deduplicating NAT MASQUERADE ($nat_count copies → 1)"
    while iptables -t nat -D POSTROUTING -s "$LAN_SUBNET" -o nordlynx -j MASQUERADE 2>/dev/null; do :; done
    iptables -t nat -A POSTROUTING -s "$LAN_SUBNET" -o nordlynx -j MASQUERADE
    RULES_CHANGED=true
  fi

  if [[ "$RULES_CHANGED" == "true" ]]; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    _ok "iptables rules restored and persisted"
  else
    _ok "iptables rules intact"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
_log "=== cycle start (country=$COUNTRY lan=$LAN_SUBNET) ==="
check_vpn
check_nordlynx
check_meshnet
check_iptables
_log "=== cycle done ==="
