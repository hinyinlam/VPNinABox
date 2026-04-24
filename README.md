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

### Recreate an LXC from Scratch

```bash
pct create 201 /var/lib/vz/template/cache/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname nordvpn-us \
  --arch amd64 --cores 2 --memory 1024 --swap 512 \
  --rootfs local-zfs:8 \
  --net0 name=eth0,bridge=vmbr0,gw=192.168.1.1,ip=192.168.1.51/24,type=veth \
  --features keyctl=1,nesting=1 \
  --unprivileged 1 --onboot 1 --startup order=11,up=35 --ostype debian

# Required: TUN device passthrough so NordVPN can open /dev/net/tun
printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net dev/net none bind,create=dir\n' \
  >> /etc/pve/lxc/201.conf

pct start 201
```

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
│   └── nordvpn-setup.sh   # Idempotent NordVPN LXC setup script
├── AGENTS.md               # AI agent guidelines for this repo
└── README.md               # This file
```
