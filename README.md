# VPNinABox

A plug-and-play NordVPN appliance running on Proxmox. Each LXC container is a standalone VPN exit node that:

- Routes LAN subnet traffic through NordVPN (subnet clients set this LXC as their default gateway)
- Registers as a NordVPN Meshnet endpoint (remote devices can route traffic through it)

## Infrastructure

| Host | IP | Role |
|------|----|------|
| Proxmox | `192.168.1.185` | Hypervisor (`https://192.168.1.185:8006`) |
| LXC 200 | `192.168.1.50` | NordVPN — Taiwan exit (`nordvpn-taiwan`) |
| LXC 201 | `192.168.1.51` | NordVPN — United States exit (`nordvpn-us`) |

## Accessing the Proxmox Host

All LXC management runs through the Proxmox host via SSH. There is no direct way to run setup scripts without SSHing in first.

```bash
ssh root@192.168.1.185
# Password stored in 1Password → AIBot vault → "Hin Home Proxmox"
```

## Accessing an LXC Container

```bash
# Interactive shell inside a container (from Proxmox host)
ssh root@192.168.1.185 "pct exec 200 -- bash"   # Taiwan
ssh root@192.168.1.185 "pct exec 201 -- bash"   # US
```

---

## LXC Lifecycle Commands

Run all `pct` commands from the Proxmox host (`ssh root@192.168.1.185`).

### Start / Stop / Restart

```bash
pct start  200      # start Taiwan LXC
pct stop   200      # graceful shutdown
pct reboot 200      # restart

pct start  201      # start US LXC
pct stop   201
pct reboot 201
```

### Status & Logs

```bash
pct status 200                                               # running / stopped
pct exec 200 -- nordvpn status                              # VPN connection info
pct exec 200 -- nordvpn meshnet peer list                   # meshnet peers
pct exec 200 -- journalctl -u nordvpnd -n 50 --no-pager    # daemon logs
```

### Delete an LXC (destructive — permanently wipes disk)

```bash
pct stop    201
pct destroy 201 --purge
```

Prefer `DeleteNordVPNGateway.sh` for normal deletion. It prompts for confirmation, deregisters Meshnet on the target when possible, removes stale Meshnet peer entries from remaining running nodes, removes persisted Meshnet source routes that reference the deleted gateway, and cleans OpenWrt LAN redirects pointing at the gateway IP.

```bash
./DeleteNordVPNGateway.sh
```

### Recreate an LXC from Scratch

Use `SetupNordVPN/create-nordvpn-lxc.sh` — run this from your **local machine**, not the Proxmox host. It handles LXC creation, TUN passthrough, script injection, and full NordVPN setup in one command.

```bash
# Rebuild US exit node (destroys existing LXC 201 first)
./SetupNordVPN/create-nordvpn-lxc.sh \
  --proxmox-password 'P@ssw0rd' \
  --vmid 201 --hostname nordvpn-us --ip 192.168.1.51 \
  --country US \
  --login-token '<PAT from 1Password → AIBot → NordVPN Access Token 2>' \
  --force

# Create Taiwan exit node
./SetupNordVPN/create-nordvpn-lxc.sh \
  --proxmox-password 'P@ssw0rd' \
  --vmid 200 --hostname nordvpn-taiwan --ip 192.168.1.50 \
  --country Taiwan \
  --login-token '<PAT>' \
  --force
```

See `SetupNordVPN/create-nordvpn-lxc.sh --help` (header comments) for all options.

---

## Setting Up NordVPN in an LXC

### Prerequisites

1. Get a **Personal Access Token** (PAT) from [nordvpn.com → Account → Tokens](https://nordvpn.com/en/user/nordaccount-settings/tokens/)
   - Stored in 1Password → AIBot vault → "NordVPN Access Token 2" → field **"personal access token"**
   - Do **not** use `nordvpn token` (device token) — it cannot register new meshnet nodes on a different machine

2. Ensure the account has fewer than 10 meshnet devices
   - Check: `pct exec 200 -- nordvpn meshnet peer list`
   - Remove stale devices: `pct exec 200 -- nordvpn meshnet peer remove <hostname>.nord`

### Deploy and Run

```bash
# 1. SSH to Proxmox
ssh root@192.168.1.185

# 2. Copy script into the LXC
pct push 201 /path/to/nordvpn-setup.sh /usr/local/bin/nordvpn-setup.sh
pct exec 201 -- chmod +x /usr/local/bin/nordvpn-setup.sh

# 3. Run full setup (install + login + connect + meshnet + iptables + systemd)
pct exec 201 -- bash /usr/local/bin/nordvpn-setup.sh \
  --country US \
  --install \
  --login-token '<YOUR_PAT>'
```

Or from your local machine in one step:

```bash
scp SetupNordVPN/nordvpn-setup.sh root@192.168.1.185:/tmp/ && \
ssh root@192.168.1.185 "
  pct push 201 /tmp/nordvpn-setup.sh /usr/local/bin/nordvpn-setup.sh
  pct exec 201 -- chmod +x /usr/local/bin/nordvpn-setup.sh
  pct exec 201 -- bash /usr/local/bin/nordvpn-setup.sh --country US --install --login-token '<YOUR_PAT>'
"
```

### Script Options

| Flag | Default | Description |
|------|---------|-------------|
| `--country <name>` | `Taiwan` | NordVPN exit country |
| `--subnet <cidr>` | `192.168.1.0/24` | LAN subnet to NAT through VPN |
| `--name <hostname>` | `nordvpn-<country>` | System hostname and meshnet nickname base |
| `--login-token <tok>` | — | Personal Access Token (required on fresh install) |
| `--install` | off | Install NordVPN if not present |
| `--verify` | off | Verification checks only, no changes |

The script is **idempotent** — safe to re-run at any time without side effects.

### Re-run After Reboot or Config Change

```bash
ssh root@192.168.1.185 "pct exec 201 -- bash /usr/local/bin/nordvpn-setup.sh --country US"
```

### Verification Checks

A successful run prints all five checks green:

```
✓ VPN connected
✓ Country correct (nordvpn: United States, ipinfo: US)
✓ FORWARD rules OK
✓ NAT rule OK
✓ IP forwarding OK
```

---

## Routing LAN Clients Through the VPN

Set the LXC IP as a device's default gateway to route all its traffic through the VPN.

### macOS (temporary, reverts on reboot)

```bash
# Route through US exit
sudo route delete default
sudo route add default 192.168.1.51

# Restore home gateway
sudo route delete default 192.168.1.51
sudo route add default 192.168.1.1
```

### macOS (persistent via GUI)

System Settings → Network → your interface → Details → TCP/IP → Router → `192.168.1.51`

### Linux

```bash
sudo ip route replace default via 192.168.1.51   # via US exit
sudo ip route replace default via 192.168.1.1    # restore
```

### iPhone / Android

Settings → Wi-Fi → your network → (i) → Configure IP → Manual → Router → `192.168.1.51`

### OpenWrt Policy Routing for One LAN IP

Use `openwrt-switch-lan-ip-to-nordvpn-gw.sh` when the source is a normal LAN device IP and OpenWrt should steer that device through a selected NordVPN LXC gateway.

Flow:

```text
LAN device -> OpenWrt policy rule -> selected NordVPN LXC -> NordVPN country -> internet
```

Show current OpenWrt redirects:

```bash
./openwrt-switch-lan-ip-to-nordvpn-gw.sh --list
```

Route one LAN client through Taiwan node `192.168.1.50`:

```bash
./openwrt-switch-lan-ip-to-nordvpn-gw.sh --apply --src-ip 192.168.1.123 --gateway 192.168.1.50
```

Route the same LAN client through US node `192.168.1.51`:

```bash
./openwrt-switch-lan-ip-to-nordvpn-gw.sh --apply --src-ip 192.168.1.123 --gateway 192.168.1.51
```

Remove the redirect so the LAN client uses the normal WAN path again:

```bash
./openwrt-switch-lan-ip-to-nordvpn-gw.sh --remove 192.168.1.123
```

Remove all OpenWrt redirects that point to a deleted gateway:

```bash
./openwrt-switch-lan-ip-to-nordvpn-gw.sh --remove-gateway 192.168.1.50
```

This script persists routes in OpenWrt UCI, so they survive router reboot.

---

## Meshnet Access (Remote Devices)

NordVPN Meshnet lets remote devices route traffic through a VPN exit LXC over an encrypted peer-to-peer tunnel — no port forwarding required.

```
Remote device ──meshnet──▶ LXC (192.168.1.51) ──NordVPN──▶ Internet (US exit)
```

On any remote device with NordVPN installed:

```bash
nordvpn set meshnet on
nordvpn meshnet peer list          # LXC appears as hinyinlam-*.nord, nickname: us-exit
nordvpn meshnet peer connect hinyinlam-<name>.nord
```

### Meshnet Peer Exit Routing

Use `switch-mesh-ip-to-nordvpn-gw.sh` when the source is a Meshnet peer IP and routing should happen inside the NordVPN LXC layer, not on OpenWrt.

Flow for same-node exit:

```text
Mesh peer -> ingress LXC -> same LXC nordlynx -> NordVPN country -> internet
```

Flow for cross-node double NAT:

```text
Mesh peer -> ingress LXC -> exit LXC LAN IP -> exit LXC nordlynx -> NordVPN country -> internet
```

List saved Meshnet source routes on an ingress node:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --list --ingress-node 200
```

Preview the route plan without changing live routing:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --dry-run --apply \
  --src-mesh-ip 100.84.138.178 \
  --ingress-node 200 \
  --exit-node 201 \
  --ingress-ip 192.168.1.50 \
  --exit-ip 192.168.1.51
```

Same-node exit through node 200's current NordVPN country:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --apply --src-mesh-ip 100.84.138.178 --node 200
```

Explicit same-node form. If `--ingress-node` and `--exit-node` are the same, the script treats it as same-node VPN exit and normalizes the exit IP to the ingress IP:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --apply \
  --src-mesh-ip 100.84.138.178 \
  --ingress-node 200 \
  --exit-node 200
```

Cross-node double NAT, where mesh traffic enters Taiwan node 200 and exits through US node 201:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --apply \
  --src-mesh-ip 100.84.138.178 \
  --ingress-node 200 \
  --exit-node 201
```

Cross-node double NAT in the opposite direction, where mesh traffic enters US node 201 and exits through Taiwan node 200:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --apply \
  --src-mesh-ip 100.84.138.178 \
  --ingress-node 201 \
  --exit-node 200
```

Remove a Meshnet peer route from the ingress node:

```bash
./switch-mesh-ip-to-nordvpn-gw.sh --remove \
  --src-mesh-ip 100.84.138.178 \
  --ingress-node 200 \
  --exit-node 201
```

The script persists routes inside the ingress LXC via `/etc/nordvpn-mesh-routing/routes.tsv` and restores them through `nordvpn-mesh-routing.service` plus `nordvpn-mesh-routing.timer`.

Use `openwrt-switch-lan-ip-to-nordvpn-gw.sh` for `192.168.1.x` LAN clients. Use `switch-mesh-ip-to-nordvpn-gw.sh` for NordVPN Meshnet peer IPs, usually in `100.64.0.0/10` such as `100.84.138.178`.

---

## Quick Status Check

```bash
ssh root@192.168.1.185 "pct exec 201 -- bash -c '
  nordvpn status
  echo ---
  nordvpn meshnet peer list | head -6
  echo ---
  curl -s https://ipinfo.io/json
'"
```

---

## Repository Layout

```
VPNinABox/
├── SetupNordVPN/
│   ├── create-nordvpn-lxc.sh       # Create a Proxmox LXC and run setup
│   ├── nordvpn-setup.sh            # Idempotent NordVPN LXC setup script
│   └── nordvpn-watchdog.sh         # Periodic VPN/Meshnet/routing self-heal
├── setup-nordvpn.sh                # Provision/update all nodes from .env
├── GetAvailableNordVPNGateway.sh   # Show running NordVPN gateways
├── SwitchNordVPNConnection.sh      # Reconnect or change an LXC VPN country
├── DeleteNordVPNGateway.sh         # Delete a NordVPN LXC and clean routes
├── openwrt-switch-lan-ip-to-nordvpn-gw.sh
├── switch-mesh-ip-to-nordvpn-gw.sh
├── tests/
│   └── test_mesh_switch_script.sh
├── AGENTS.md                       # AI agent guidelines for this repo
└── README.md                       # This file
```
