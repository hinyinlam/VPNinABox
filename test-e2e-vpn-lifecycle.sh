#!/usr/bin/env bash
# test-e2e-vpn-lifecycle.sh — non-interactive end-to-end test of the full VPN gateway lifecycle.
#
# Tests: Create LXC → apply OpenWRT redirect → delete LXC →
#        verify no leftover state that would disrupt other devices.
#
# Usage:
#   ./test-e2e-vpn-lifecycle.sh                    # full lifecycle (create + test + delete)
#   ./test-e2e-vpn-lifecycle.sh --skip-create      # skip LXC creation (--vmid must already exist)
#   ./test-e2e-vpn-lifecycle.sh --skip-delete      # leave LXC running after test
#
# Options:
#   --vmid <id>         Test LXC VMID              (default: 299)
#   --ip <addr>         Test LXC IP                (default: 192.168.1.99)
#   --country <name>    NordVPN exit country        (default: US)
#   --test-client <ip>  Fake client IP for redirect (default: 192.168.1.253)
#   --skip-create       Skip LXC creation
#   --skip-delete       Leave LXC running after test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found."; exit 1; }
set -a; source "$ENV_FILE"; set +a

[[ -n "${PROXMOX_HOST:-}"     ]] || { echo "ERROR: PROXMOX_HOST missing in .env";     exit 1; }
[[ -n "${PROXMOX_PASSWORD:-}" ]] || { echo "ERROR: PROXMOX_PASSWORD missing in .env"; exit 1; }
[[ -n "${NORDVPN_TOKEN:-}"    ]] || { echo "ERROR: NORDVPN_TOKEN missing in .env";    exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
TEST_VMID=299
TEST_IP=192.168.1.99
TEST_COUNTRY=US
TEST_CLIENT=192.168.1.253
SKIP_CREATE=false
SKIP_DELETE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --vmid)        TEST_VMID="$2";    shift 2 ;;
    --ip)          TEST_IP="$2";      shift 2 ;;
    --country)     TEST_COUNTRY="$2"; shift 2 ;;
    --test-client) TEST_CLIENT="$2";  shift 2 ;;
    --skip-create) SKIP_CREATE=true;  shift ;;
    --skip-delete) SKIP_DELETE=true;  shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Colors / counters ─────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; RESET='\033[0m'

PASS=0; FAIL=0
pass() { echo -e "    ${GREEN}✓ PASS${RESET}  $*"; PASS=$((PASS+1)); }
fail() { echo -e "    ${RED}✗ FAIL${RESET}  $*"; FAIL=$((FAIL+1)); }
step() { echo ""; echo -e "  ${BOLD}${CYAN}── $* ──${RESET}"; }

# ── SSH helpers ───────────────────────────────────────────────────────────────
pxm_ssh() {
  sshpass -p "$PROXMOX_PASSWORD" ssh \
    -n -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 \
    "root@${PROXMOX_HOST}" "$@" 2>/dev/null
}

owrt_ssh() {
  sshpass -p "$OPENWRT_PASSWORD" ssh \
    -n -p "${OPENWRT_SSH_PORT:-22}" \
    -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 -o ConnectTimeout=8 \
    "root@${OPENWRT_HOST}" "$@" 2>/dev/null
}

OPENWRT_AVAILABLE=false
if [[ -n "${OPENWRT_HOST:-}" && -n "${OPENWRT_PASSWORD:-}" ]]; then
  owrt_ssh "echo ok" >/dev/null 2>&1 && OPENWRT_AVAILABLE=true || true
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       VPN Gateway Lifecycle — E2E Test                           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
printf "  %-18s %s\n" "Test VMID:"    "$TEST_VMID"
printf "  %-18s %s\n" "Test LXC IP:"  "$TEST_IP"
printf "  %-18s %s\n" "Country:"      "$TEST_COUNTRY"
printf "  %-18s %s\n" "Test client:"  "$TEST_CLIENT  (fake device for redirect test)"
printf "  %-18s %s\n" "Skip create:"  "$SKIP_CREATE"
printf "  %-18s %s\n" "Skip delete:"  "$SKIP_DELETE"
if [[ "$OPENWRT_AVAILABLE" == "true" ]]; then
  printf "  %-18s %s\n" "OpenWRT:"    "reachable at ${OPENWRT_HOST}"
else
  printf "  %-18s %s\n" "OpenWRT:" "unreachable — redirect steps will be skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Create LXC
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_CREATE" == "false" ]]; then
  step "Step 1: Create test LXC ${TEST_VMID} @ ${TEST_IP} (${TEST_COUNTRY})"

  PROVISIONER="${SCRIPT_DIR}/SetupNordVPN/create-nordvpn-lxc.sh"
  [[ -f "$PROVISIONER" ]] || { echo "ERROR: SetupNordVPN/create-nordvpn-lxc.sh not found"; exit 1; }

  # Destroy pre-existing LXC from a prior failed run
  if pxm_ssh "pct status ${TEST_VMID} 2>/dev/null" 2>/dev/null | grep -qi "running\|stopped"; then
    echo -e "  ${YELLOW}⚠ LXC ${TEST_VMID} already exists — destroying before test${RESET}"
    pxm_ssh "pct stop ${TEST_VMID} 2>/dev/null || true; pct destroy ${TEST_VMID} --purge 2>/dev/null || true"
    sleep 3
  fi

  bash "$PROVISIONER" \
    --proxmox-host     "$PROXMOX_HOST" \
    --proxmox-password "$PROXMOX_PASSWORD" \
    --vmid             "$TEST_VMID" \
    --hostname         "nordvpn-test-${TEST_VMID}" \
    --ip               "$TEST_IP" \
    --country          "$TEST_COUNTRY" \
    --subnet           "${SUBNET:-192.168.1.0/24}" \
    --gateway          "${GATEWAY:-192.168.1.1}" \
    --login-token      "$NORDVPN_TOKEN"
else
  step "Step 1: Skipped (--skip-create) — using existing LXC ${TEST_VMID}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Verify VPN connected inside LXC
# ═══════════════════════════════════════════════════════════════════════════════
step "Step 2: Verify LXC ${TEST_VMID} VPN connected"

vpn_connected=false
vpn_country=""
vpn_server=""
for attempt in 1 2 3 4 5; do
  raw=$(pxm_ssh "pct exec ${TEST_VMID} -- nordvpn status 2>/dev/null") || raw=""
  status=$(echo "$raw" | awk -F': ' '/^Status:/{print $2}')
  if [[ "$status" == "Connected" ]]; then
    vpn_connected=true
    vpn_country=$(echo "$raw" | awk -F': ' '/^Country:/{print $2}')
    vpn_server=$(echo  "$raw" | awk -F': ' '/^Server:/{print $2}')
    pass "VPN connected — ${vpn_country} / ${vpn_server}"
    break
  fi
  echo -e "  ${DIM}  attempt ${attempt}/5: status='${status:-unknown}' — waiting 10s...${RESET}"
  sleep 10
done

if [[ "$vpn_connected" == "false" ]]; then
  fail "VPN not connected after 5 attempts"
  echo -e "  ${RED}Cannot continue without an active VPN connection.${RESET}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Apply OpenWRT redirect for test client
# ═══════════════════════════════════════════════════════════════════════════════
step "Step 3: Apply OpenWRT redirect  ${TEST_CLIENT} → ${TEST_IP}"

if [[ "$OPENWRT_AVAILABLE" == "true" ]]; then
  OWRT_SCRIPT="${SCRIPT_DIR}/openwrt-switch-ip-to-nordvpn-gw.sh"
  [[ -f "$OWRT_SCRIPT" ]] || { echo "ERROR: openwrt-switch-ip-to-nordvpn-gw.sh not found"; exit 1; }
  bash "$OWRT_SCRIPT" --apply --src-ip "$TEST_CLIENT" --gateway "$TEST_IP"
  pass "Redirect applied"
else
  echo -e "  ${DIM}Skipped — OpenWRT not reachable${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Verify redirect is live and persisted
# ═══════════════════════════════════════════════════════════════════════════════
step "Step 4: Verify redirect active and persisted"

if [[ "$OPENWRT_AVAILABLE" == "true" ]]; then
  table_id=$(( 200 + ${TEST_IP##*.} ))

  rule_line=$(owrt_ssh "ip rule list | grep 'from ${TEST_CLIENT}'" || true)
  if [[ -n "$rule_line" ]]; then
    pass "Live ip rule: ${rule_line}"
  else
    fail "ip rule for ${TEST_CLIENT} missing from 'ip rule list'"
  fi

  table_route=$(owrt_ssh "ip route show table ${table_id} 2>/dev/null | grep default" || true)
  if echo "$table_route" | grep -q "${TEST_IP}"; then
    pass "Table ${table_id} default via ${TEST_IP}"
  else
    fail "Table ${table_id} missing default via ${TEST_IP} (got: '${table_route}')"
  fi

  uci_rule=$(owrt_ssh "uci show network 2>/dev/null | grep -F '${TEST_CLIENT}'" || true)
  if [[ -n "$uci_rule" ]]; then
    pass "UCI rule persisted (survives reboot)"
  else
    fail "UCI rule for ${TEST_CLIENT} missing — would not survive reboot"
  fi
else
  echo -e "  ${DIM}Skipped — OpenWRT not reachable${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Delete LXC non-interactively
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DELETE" == "false" ]]; then
  step "Step 5: Delete LXC ${TEST_VMID} (non-interactive)"

  lxc_status=$(pxm_ssh "pct status ${TEST_VMID} 2>/dev/null || echo not_found") || lxc_status="not_found"
  if echo "$lxc_status" | grep -qi "running"; then
    echo -e "  ${DIM}Stopping LXC ${TEST_VMID}...${RESET}"
    pxm_ssh "pct stop ${TEST_VMID}"
    sleep 3
  fi
  echo -e "  ${DIM}Destroying LXC ${TEST_VMID} --purge...${RESET}"
  pxm_ssh "pct destroy ${TEST_VMID} --purge"
  pass "LXC ${TEST_VMID} destroyed"
else
  step "Step 5: Skipped (--skip-delete)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Clean up OpenWRT routes for the deleted gateway
# ═══════════════════════════════════════════════════════════════════════════════
step "Step 6: Clean OpenWRT routes for gateway ${TEST_IP}"

if [[ "$OPENWRT_AVAILABLE" == "true" ]]; then
  OWRT_SCRIPT="${SCRIPT_DIR}/openwrt-switch-ip-to-nordvpn-gw.sh"
  bash "$OWRT_SCRIPT" --remove-gateway "$TEST_IP"
  pass "OpenWRT --remove-gateway ${TEST_IP} completed"
else
  echo -e "  ${DIM}Skipped — OpenWRT not reachable${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: Verify clean state — no leftover that breaks other devices
# ═══════════════════════════════════════════════════════════════════════════════
step "Step 7: Verify no leftover state"

# 7a. LXC gone from Proxmox
if [[ "$SKIP_DELETE" == "false" ]]; then
  lxc_check=$(pxm_ssh "pct status ${TEST_VMID} 2>&1 || echo not_found") || lxc_check="not_found"
  if echo "$lxc_check" | grep -qiE "not_found|no such|does not exist"; then
    pass "LXC ${TEST_VMID} no longer on Proxmox"
  else
    fail "LXC ${TEST_VMID} still present: ${lxc_check}"
  fi
fi

if [[ "$OPENWRT_AVAILABLE" == "true" ]]; then

  # 7b. No UCI rules for test client or gateway
  uci_rules=$(owrt_ssh "uci show network 2>/dev/null | grep '@rule'" || true)
  stale_rules=$(echo "$uci_rules" | grep -E "${TEST_CLIENT}|${TEST_IP}" || true)
  if [[ -z "$stale_rules" ]]; then
    pass "No UCI rules for test client/gateway remain"
  else
    fail "Stale UCI rules present: ${stale_rules}"
  fi

  # 7c. No UCI routes for test gateway (LuCI Static Routes page clean)
  uci_routes=$(owrt_ssh "uci show network 2>/dev/null | grep '@route'" || true)
  stale_routes=$(echo "$uci_routes" | grep "${TEST_IP}" || true)
  if [[ -z "$stale_routes" ]]; then
    pass "No UCI routes for ${TEST_IP} (LuCI Static Routes page clean)"
  else
    fail "Stale UCI routes present: ${stale_routes}"
  fi

  # 7d. No live ip rule for test client — it falls back to main/WAN
  stale_rule=$(owrt_ssh "ip rule list | grep 'from ${TEST_CLIENT}'" || true)
  if [[ -z "$stale_rule" ]]; then
    pass "No live ip rule for ${TEST_CLIENT} — falls back to default WAN"
  else
    fail "ip rule for ${TEST_CLIENT} still active: ${stale_rule}"
  fi

  # 7e. WAN default route still intact — critical for all other LAN devices
  wan_default=$(owrt_ssh "ip route show table main | grep '^default'" || true)
  if [[ -n "$wan_default" ]]; then
    pass "WAN default route intact: ${wan_default}"
  else
    fail "WAN default route MISSING — other LAN devices will lose internet!"
  fi

  # 7f. ip rule list has only the three system entries (0, 32766, 32767)
  custom_rules=$(owrt_ssh "ip rule list | grep -vE '^(0|32766|32767):'" || true)
  if [[ -z "$custom_rules" ]]; then
    pass "ip rule list clean — only system defaults remain"
  else
    fail "Unexpected ip rules still active:\n      ${custom_rules}"
  fi

fi

# ═══════════════════════════════════════════════════════════════════════════════
# Final report
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
total=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
  printf "${BOLD}║  ${GREEN}ALL PASS${RESET}${BOLD}  (%d/%d checks passed)%-36s║${RESET}\n" "$PASS" "$total" ""
else
  printf "${BOLD}║  ${RED}FAILED${RESET}${BOLD}    (%d passed, %d FAILED / %d total)%-25s║${RESET}\n" "$PASS" "$FAIL" "$total" ""
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

[[ $FAIL -eq 0 ]] || exit 1
