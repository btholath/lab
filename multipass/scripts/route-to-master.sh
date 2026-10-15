#!/usr/bin/env bash
# route-to-master.sh
#
# Gives a WORKER a permanent, direct route to the master's fixed address.
#
# Why: the master keeps a fixed secondary address (see pin-ip.sh). The kubelets, kube-proxy
# and the API server's certificate all use it. Hyper-V's Default Switch can hand the VMs a
# different subnet after the host restarts. A worker then has no route to the fixed address
# except through the gateway, which does not know it, so the node goes NotReady. A host
# route straight out of the network interface makes the worker look for that address on the
# local network, where the master answers, whatever subnet the switch picked.
#
# What it does (without disturbing the node):
#   1. writes /etc/netplan/61-master-route.yaml, which makes the route permanent at boot
#   2. checks the file with `netplan generate` (and removes it again if netplan rejects it)
#   3. adds the same route to the RUNNING system with `ip route replace`
#
# It does NOT run `netplan apply`. On a node that runs Kubernetes that command re-applies the
# whole network configuration, and on a worker it was followed by a dead pod network (every
# pod path through that node failed while the node still showed Ready) until the VM was
# restarted. Use --apply only if you accept that risk.
#
# Run INSIDE each worker, as root:
#   sudo bash route-to-master.sh              uses the address in /etc/kubernetes/kubelet.conf
#   sudo bash route-to-master.sh 172.25.246.7 uses the address you give
#   sudo bash route-to-master.sh --apply      also runs `netplan apply` (see above)
#   sudo bash route-to-master.sh --undo       removes the drop-in (the live route stays until reboot)
#
# From PowerShell:
#   multipass transfer route-to-master.sh worker1:/home/ubuntu/
#   multipass exec worker1 -- sudo bash /home/ubuntu/route-to-master.sh
set -euo pipefail

ROOT="${ROOT:-}"   # empty on a real VM. Only set when testing against a fake filesystem.
NETPLAN_DIR="${NETPLAN_DIR:-$ROOT/etc/netplan}"
DROPIN="$NETPLAN_DIR/61-master-route.yaml"

IP=""; APPLY=0; UNDO=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --undo)  UNDO=1 ;;
    -*)      echo "Unknown option: $arg" >&2; exit 1 ;;
    *)       IP="$arg" ;;
  esac
done

if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 ..." >&2; exit 1
fi

if [ "$UNDO" = 1 ]; then
  rm -f "$DROPIN"
  echo "Route drop-in removed. The live route stays until the next reboot."
  echo "To remove it now as well:  sudo ip route del <master-ip>/32 dev eth0   (only if you are sure)"
  exit 0
fi

if [ -z "$IP" ] && [ -r "$ROOT/etc/kubernetes/kubelet.conf" ]; then
  IP=$(sed -nE 's#^[[:space:]]+server:[[:space:]]*https?://([0-9.]+)(:[0-9]+)?.*#\1#p' \
        "$ROOT/etc/kubernetes/kubelet.conf" | head -1)
fi
[ -n "$IP" ] || { echo "Usage: sudo bash $0 [MASTER_IP] [--apply] | --undo   (no address found in kubelet.conf)" >&2; exit 1; }

[[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ $IP =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])(\.|$) ]] \
  || { echo "Bad IP: $IP" >&2; exit 1; }

# Use the SAME ethernet id as the existing (cloud-init) netplan file, so netplan MERGES this
# file into it instead of defining a second, conflicting entry for the same interface.
# If no DHCP ethernet is found, refuse to guess.
ID=$(python3 - "$NETPLAN_DIR" <<'PY'
import sys, glob, yaml
ids = []
for f in sorted(glob.glob(sys.argv[1] + "/*.yaml")):
    if f.endswith(("60-fixed-ip.yaml", "61-master-route.yaml")):
        continue
    try:
        eth = (yaml.safe_load(open(f)) or {}).get("network", {}).get("ethernets", {}) or {}
    except Exception:
        continue
    for k, v in eth.items():
        if (v or {}).get("dhcp4"):
            ids.append(k)
print(ids[0] if ids else "")
PY
)
[ -n "$ID" ] || { echo "No DHCP ethernet found in $NETPLAN_DIR; refusing to guess." >&2; exit 1; }
echo "Using netplan ethernet id: $ID"
echo "Route: $IP/32, directly on the local network"

mkdir -p "$NETPLAN_DIR"
cat > "$DROPIN" <<YAML
network:
  version: 2
  ethernets:
    $ID:
      routes:
        - to: $IP/32
          scope: link
YAML
chmod 600 "$DROPIN"

if [ -n "$ROOT" ]; then
  echo "Wrote $DROPIN (test mode: nothing else was done)."
  exit 0
fi

if ! netplan generate; then
  rm -f "$DROPIN"
  echo "netplan rejected the file. It was removed and nothing was changed." >&2
  exit 1
fi
echo "netplan accepts the file. The route becomes permanent at the next boot."

DEV=$(ip route show default | awk '{print $5; exit}')
ip route replace "$IP/32" dev "$DEV"
echo "Added to the running system: $IP/32 dev $DEV"

if [ "$APPLY" = 1 ]; then
  echo "Running netplan apply, as asked. If pods on this node stop answering, restart the VM." >&2
  netplan apply
  sleep 3
  ip route get "$IP" | grep -q " via " && ip route replace "$IP/32" dev "$DEV"
fi

echo "Result:"
ip route get "$IP" | head -1
ip route show | grep -F "$IP" || true
echo "Permanent drop-in: $DROPIN   (read it with: sudo cat $DROPIN)"
