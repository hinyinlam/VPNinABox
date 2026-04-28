#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/switch-mesh-ip-to-nordvpn-gw.sh"
LAN_SCRIPT="${ROOT_DIR}/openwrt-switch-lan-ip-to-nordvpn-gw.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain:" >&2
    echo "  $needle" >&2
    echo "Actual output:" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "$haystack" == *"$needle"* ]]; then
    echo "Expected output not to contain:" >&2
    echo "  $needle" >&2
    echo "Actual output:" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

bash -n "$LAN_SCRIPT"
bash -n "$SCRIPT"

same_node_plan=$("$SCRIPT" \
  --dry-run \
  --apply \
  --src-mesh-ip 100.64.1.25 \
  --ingress-node 200 \
  --exit-node 200 \
  --ingress-ip 192.168.1.50 \
  --exit-ip 192.168.1.50)

assert_contains "$same_node_plan" "MODE=same-node"
assert_contains "$same_node_plan" "ip rule add from 100.64.1.25/32 priority 10025 table 1050"
assert_contains "$same_node_plan" "ip route replace default dev nordlynx table 1050"
assert_contains "$same_node_plan" "iptables -t nat -C POSTROUTING -s 100.64.1.25/32 -d 192.168.1.0/24 -o nordlynx -j RETURN"
assert_contains "$same_node_plan" "iptables -t nat -C POSTROUTING -s 100.64.1.25/32 -d 100.64.0.0/10 -o nordlynx -j RETURN"
assert_contains "$same_node_plan" "iptables -t nat -C POSTROUTING -s 100.64.1.25/32 -o nordlynx -j MASQUERADE"
assert_not_contains "$same_node_plan" "! -d 192.168.1.0/24 ! -d 100.64.0.0/10 -o nordlynx"
assert_not_contains "$same_node_plan" "-o eth0 -j SNAT"
assert_not_contains "$same_node_plan" "iptables -t mangle -C POSTROUTING"

same_node_remove_plan=$("$SCRIPT" \
  --dry-run \
  --remove \
  --src-mesh-ip 100.64.1.25 \
  --ingress-node 200 \
  --exit-node 200 \
  --ingress-ip 192.168.1.50 \
  --exit-ip 192.168.1.50)

assert_contains "$same_node_remove_plan" "iptables -t nat -D POSTROUTING -s 100.64.1.25/32 -d 192.168.1.0/24 -o nordlynx -j RETURN"
assert_contains "$same_node_remove_plan" "iptables -t nat -D POSTROUTING -s 100.64.1.25/32 -d 100.64.0.0/10 -o nordlynx -j RETURN"
assert_contains "$same_node_remove_plan" "iptables -t nat -D POSTROUTING -s 100.64.1.25/32 -o nordlynx -j MASQUERADE"
assert_not_contains "$same_node_remove_plan" "! -d 192.168.1.0/24 ! -d 100.64.0.0/10 -o nordlynx"

same_node_mismatched_exit_ip_plan=$("$SCRIPT" \
  --dry-run \
  --apply \
  --src-mesh-ip 100.64.1.25 \
  --ingress-node 200 \
  --exit-node 200 \
  --ingress-ip 192.168.1.50 \
  --exit-ip 192.168.1.51)

assert_contains "$same_node_mismatched_exit_ip_plan" "MODE=same-node"
assert_contains "$same_node_mismatched_exit_ip_plan" "EXIT_IP=192.168.1.50"
assert_contains "$same_node_mismatched_exit_ip_plan" "TABLE_ID=1050"
assert_contains "$same_node_mismatched_exit_ip_plan" "ip route replace default dev nordlynx table 1050"
assert_not_contains "$same_node_mismatched_exit_ip_plan" "ip route replace default via"
assert_not_contains "$same_node_mismatched_exit_ip_plan" "-o eth0 -j SNAT"
assert_not_contains "$same_node_mismatched_exit_ip_plan" "iptables -t mangle -C POSTROUTING"

cross_node_plan=$("$SCRIPT" \
  --dry-run \
  --apply \
  --src-mesh-ip 100.64.1.25 \
  --ingress-node 201 \
  --exit-node 200 \
  --ingress-ip 192.168.1.51 \
  --exit-ip 192.168.1.50)

assert_contains "$cross_node_plan" "MODE=cross-node-double-nat"
assert_contains "$cross_node_plan" "ip route replace default via 192.168.1.50 dev eth0 table 1050"
assert_contains "$cross_node_plan" "iptables -t mangle -C POSTROUTING -s 100.64.1.25/32 ! -d 192.168.1.0/24 -o eth0 -j ACCEPT"
assert_contains "$cross_node_plan" "iptables -t mangle -C PREROUTING -i eth0 -d 192.168.1.51/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
assert_contains "$cross_node_plan" "iptables -t nat -C POSTROUTING -s 100.64.1.25/32 ! -d 192.168.1.0/24 -o eth0 -j SNAT --to-source 192.168.1.51"

remove_plan=$("$SCRIPT" \
  --dry-run \
  --remove \
  --src-mesh-ip 100.64.1.25 \
  --ingress-node 201 \
  --exit-node 200 \
  --ingress-ip 192.168.1.51 \
  --exit-ip 192.168.1.50)

assert_contains "$remove_plan" "ACTION=remove"
assert_contains "$remove_plan" "MODE=cross-node-double-nat"
assert_contains "$remove_plan" "ip rule del from 100.64.1.25/32 priority 10025 table 1050"
assert_contains "$remove_plan" "iptables -t mangle -D POSTROUTING -s 100.64.1.25/32 ! -d 192.168.1.0/24 -o eth0 -j ACCEPT"
assert_contains "$remove_plan" "iptables -t mangle -D PREROUTING -i eth0 -d 192.168.1.51/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
assert_contains "$remove_plan" "iptables -t nat -D POSTROUTING -s 100.64.1.25/32 ! -d 192.168.1.0/24 -o eth0 -j SNAT --to-source 192.168.1.51"

echo "mesh switch script tests passed"
