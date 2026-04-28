#!/usr/bin/env bash
# create-nordvpn-lxc.sh — create a fresh NordVPN LXC on Proxmox from scratch.
#
# Run from your LOCAL MACHINE (not the Proxmox host).
# Handles everything: LXC creation, TUN passthrough, script injection,
# and full NordVPN setup in one command.
#
# Usage:
#   ./create-nordvpn-lxc.sh --login-token <PAT> [options]
#
# Options:
#   --proxmox-host      <ip>    Proxmox host IP         (default: 192.168.1.185)
#   --proxmox-password  <pass>  Proxmox root password   (uses SSH key if omitted)
#   --vmid              <id>    LXC container ID        (default: 201)
#   --hostname          <name>  LXC hostname            (default: nordvpn-us)
#   --ip                <addr>  LXC IP, no CIDR         (default: 192.168.1.51)
#   --country           <name>  NordVPN exit country    (default: US)
#   --subnet            <cidr>  LAN subnet to NAT       (default: 192.168.1.0/24)
#   --gateway           <ip>    LAN gateway             (default: 192.168.1.1)
#   --login-token       <tok>   NordVPN Personal Access Token (required)
#   --force                     Destroy existing LXC with same VMID first
#
# Examples:
#   # US exit node
#   ./create-nordvpn-lxc.sh \
#     --proxmox-password 'P@ssw0rd' \
#     --vmid 201 --hostname nordvpn-us --ip 192.168.1.51 \
#     --country US --login-token '<PAT>'
#
#   # Taiwan exit node
#   ./create-nordvpn-lxc.sh \
#     --proxmox-password 'P@ssw0rd' \
#     --vmid 200 --hostname nordvpn-taiwan --ip 192.168.1.50 \
#     --country Taiwan --login-token '<PAT>'
#
#   # Rebuild existing LXC 201 from zero
#   ./create-nordvpn-lxc.sh \
#     --proxmox-password 'P@ssw0rd' \
#     --vmid 201 --hostname nordvpn-us --ip 192.168.1.51 \
#     --country US --login-token '<PAT>' --force

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROXMOX_HOST="192.168.1.185"
PROXMOX_USER="root"
PROXMOX_PASSWORD=""
VMID="201"
LXC_HOSTNAME="nordvpn-us"
LXC_IP="192.168.1.51"
GATEWAY="192.168.1.1"
BRIDGE="vmbr0"
COUNTRY="US"
LOGIN_TOKEN=""
SUBNET="192.168.1.0/24"
TEMPLATE_PATH="/var/lib/vz/template/cache/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-zfs"
DISK_SIZE="8"
CORES="2"
MEMORY="1024"
SWAP="512"
FORCE=false

# ── Flags ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --proxmox-host)     PROXMOX_HOST="$2";     shift 2 ;;
    --proxmox-password) PROXMOX_PASSWORD="$2"; shift 2 ;;
    --vmid)             VMID="$2";             shift 2 ;;
    --hostname)         LXC_HOSTNAME="$2";     shift 2 ;;
    --ip)               LXC_IP="$2";           shift 2 ;;
    --country)          COUNTRY="$2";          shift 2 ;;
    --login-token)      LOGIN_TOKEN="$2";      shift 2 ;;
    --subnet)           SUBNET="$2";           shift 2 ;;
    --gateway)          GATEWAY="$2";          shift 2 ;;
    --force)            FORCE=true;            shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -n "$LOGIN_TOKEN" ]] || { echo "ERROR: --login-token is required"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/nordvpn-setup.sh"
WATCHDOG_SCRIPT="$SCRIPT_DIR/nordvpn-watchdog.sh"
[[ -f "$SETUP_SCRIPT" ]]    || { echo "ERROR: nordvpn-setup.sh not found at $SETUP_SCRIPT"; exit 1; }
[[ -f "$WATCHDOG_SCRIPT" ]] || { echo "ERROR: nordvpn-watchdog.sh not found at $WATCHDOG_SCRIPT"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

pxm_ssh() {
  if [[ -n "$PROXMOX_PASSWORD" ]]; then
    sshpass -p "$PROXMOX_PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o NumberOfPasswordPrompts=1 \
      "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
  else
    ssh -o StrictHostKeyChecking=no "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
  fi
}

pxm_scp() {
  if [[ -n "$PROXMOX_PASSWORD" ]]; then
    sshpass -p "$PROXMOX_PASSWORD" scp \
      -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o NumberOfPasswordPrompts=1 \
      "$@"
  else
    scp -o StrictHostKeyChecking=no "$@"
  fi
}

# ── 1. Connectivity check ─────────────────────────────────────────────────────
log "Checking Proxmox connectivity ($PROXMOX_HOST)..."
pxm_ssh "hostname" >/dev/null || fail "Cannot reach $PROXMOX_HOST — check host/password"
ok "Proxmox reachable"

# ── 2. Optionally destroy existing LXC ───────────────────────────────────────
if [[ "$FORCE" == "true" ]]; then
  log "Destroying existing LXC $VMID (--force)..."
  # Deregister meshnet first to free the device slot
  pxm_ssh "pct exec $VMID -- nordvpn set meshnet off 2>/dev/null || true" 2>/dev/null || true
  pxm_ssh "pct stop $VMID 2>/dev/null || true; pct destroy $VMID --purge 2>/dev/null || true"
  ok "LXC $VMID removed"
else
  if pxm_ssh "pct status $VMID 2>/dev/null" | grep -qi "running\|stopped"; then
    fail "LXC $VMID already exists. Add --force to destroy and recreate it."
  fi
fi

# ── 3. Create LXC ─────────────────────────────────────────────────────────────
log "Creating LXC $VMID ($LXC_HOSTNAME @ $LXC_IP)..."
pxm_ssh "pct create $VMID $TEMPLATE_PATH \
  --hostname $LXC_HOSTNAME \
  --arch amd64 \
  --cores $CORES \
  --memory $MEMORY \
  --swap $SWAP \
  --rootfs ${STORAGE}:${DISK_SIZE} \
  --net0 name=eth0,bridge=${BRIDGE},gw=${GATEWAY},ip=${LXC_IP}/24,type=veth \
  --features keyctl=1,nesting=1 \
  --unprivileged 1 \
  --onboot 1 \
  --startup order=11,up=35 \
  --ostype debian 2>&1"
ok "LXC $VMID created"

# ── 4. Add TUN device passthrough ─────────────────────────────────────────────
log "Configuring TUN device passthrough..."
pxm_ssh "printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net dev/net none bind,create=dir\n' \
  >> /etc/pve/lxc/${VMID}.conf"
ok "TUN passthrough added to /etc/pve/lxc/${VMID}.conf"

# ── 5. Start LXC ──────────────────────────────────────────────────────────────
log "Starting LXC $VMID..."
pxm_ssh "pct start $VMID"
log "Waiting for container to boot (10s)..."
sleep 10
actual_host=$(pxm_ssh "pct exec $VMID -- hostname 2>/dev/null" | tr -d '\r\n')
ok "LXC $VMID running (hostname: $actual_host)"

# ── 6. Copy scripts into LXC ─────────────────────────────────────────────────
log "Copying scripts into LXC $VMID..."
pxm_scp "$SETUP_SCRIPT"    "${PROXMOX_USER}@${PROXMOX_HOST}:/tmp/nordvpn-setup.sh"
pxm_scp "$WATCHDOG_SCRIPT" "${PROXMOX_USER}@${PROXMOX_HOST}:/tmp/nordvpn-watchdog.sh"
pxm_ssh "pct push $VMID /tmp/nordvpn-setup.sh    /usr/local/bin/nordvpn-setup.sh    && \
  pct push $VMID /tmp/nordvpn-watchdog.sh /usr/local/bin/nordvpn-watchdog.sh && \
  pct exec $VMID -- chmod +x /usr/local/bin/nordvpn-setup.sh /usr/local/bin/nordvpn-watchdog.sh && \
  rm -f /tmp/nordvpn-setup.sh /tmp/nordvpn-watchdog.sh"
ok "nordvpn-setup.sh + nordvpn-watchdog.sh deployed to LXC at /usr/local/bin/"

# ── 7. Run NordVPN setup ──────────────────────────────────────────────────────
log "Running NordVPN setup inside LXC (country=$COUNTRY)..."
pxm_ssh "pct exec $VMID -- bash /usr/local/bin/nordvpn-setup.sh \
  --country '$COUNTRY' \
  --subnet '$SUBNET' \
  --install \
  --login-token '$LOGIN_TOKEN'"

log "Done."
log "LXC $VMID ($LXC_HOSTNAME) is live at $LXC_IP"
log "Route LAN clients through VPN: set their default gateway to $LXC_IP"
