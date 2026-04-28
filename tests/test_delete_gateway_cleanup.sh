#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/DeleteNordVPNGateway.sh"

assert_file_contains() {
  local needle="$1"

  if ! grep -Fq "$needle" "$SCRIPT"; then
    echo "Expected DeleteNordVPNGateway.sh to contain:" >&2
    echo "  $needle" >&2
    exit 1
  fi
}

bash -n "$SCRIPT"

assert_file_contains "pxm_ssh_stdin()"
assert_file_contains "target_mesh_hostname"
assert_file_contains "nordvpn meshnet peer remove"
assert_file_contains "cleanup_mesh_routes_for_gateway"
assert_file_contains "/etc/nordvpn-mesh-routing/routes.tsv"
assert_file_contains "TARGET_GATEWAY_IP"
assert_file_contains "iptables -t nat -D POSTROUTING -s \"\${src}/32\" -d \"\$lan_subnet\" -o nordlynx -j RETURN"
assert_file_contains "iptables -t nat -D POSTROUTING -s \"\${src}/32\" -d \"\$mesh_subnet\" -o nordlynx -j RETURN"

echo "delete gateway cleanup tests passed"
