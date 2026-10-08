#!/usr/bin/env bash
# Add a FIXED secondary IPv4 address to a Multipass Ubuntu VM, keeping DHCP.
#
# Why secondary and not replacing DHCP: Multipass on Hyper-V finds a VM through the
# Default Switch's DHCP/DNS record (<name>.mshome.net). A VM that stops using DHCP
# becomes unreachable for Multipass ("N/A", timeouts). So DHCP stays as the primary
# address and the fixed address is simply added next to it.
#
# Run INSIDE the VM, as root:
#   sudo bash pin-ip.sh IP PREFIX         e.g.  sudo bash pin-ip.sh 172.25.246.7 20
#   sudo bash pin-ip.sh --undo            remove the fixed address
set -euo pipefail

ROOT="${ROOT:-}"   # empty on a real VM. Only set when testing against a fake filesystem.
NETPLAN_DIR="$ROOT/etc/netplan"
DROPIN="$NETPLAN_DIR/60-fixed-ip.yaml"

if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 ..." >&2; exit 1
fi

if [ "${1:-}" = "--undo" ]; then
  rm -f "$DROPIN"
  [ -z "$ROOT" ] && command -v netplan >/dev/null && netplan apply
  echo "Fixed address removed (DHCP address untouched)."
  exit 0
fi

[ "$#" -ge 2 ] || { echo "Usage: sudo bash $0 IP PREFIX   |   sudo bash $0 --undo" >&2; exit 1; }
IP=$1; PREFIX=$2

[[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ $IP =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])(\.|$) ]] \
  || { echo "Bad IP: $IP" >&2; exit 1; }
[[ $PREFIX =~ ^[0-9]+$ ]] && [ "$PREFIX" -ge 8 ] && [ "$PREFIX" -le 30 ] || { echo "Bad prefix: $PREFIX" >&2; exit 1; }

# Use the SAME ethernet id as the existing (cloud-init) netplan file, so netplan MERGES
# this file into it instead of defining a second, conflicting interface.
ID=$(python3 - "$NETPLAN_DIR" <<'PY'
import sys, glob, yaml
ids = []
for f in sorted(glob.glob(sys.argv[1] + "/*.yaml")):
    if f.endswith("60-fixed-ip.yaml"):
        continue
    try:
        eth = (yaml.safe_load(open(f)) or {}).get("network", {}).get("ethernets", {}) or {}
    except Exception:
        continue
    for k, v in eth.items():
        ids.append((0 if (v or {}).get("dhcp4") else 1, k))
print(sorted(ids)[0][1] if ids else "eth0")
PY
)
echo "Using netplan ethernet id: $ID"

mkdir -p "$NETPLAN_DIR"
cat > "$DROPIN" <<YAML
network:
  version: 2
  ethernets:
    $ID:
      addresses:
        - $IP/$PREFIX
YAML
chmod 600 "$DROPIN"

if [ -z "$ROOT" ] && command -v netplan >/dev/null; then
  netplan generate
  echo "--- merged configuration (dhcp4 must still be true, and the new address listed) ---"
  netplan get ethernets
  netplan apply
fi
echo
echo "Done. Check:  ip -4 -o addr show   (the DHCP address AND $IP should both be listed)"
