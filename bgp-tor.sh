#!/bin/bash
# Manage the FRR ToR container for the BGP VIP demo.
# The container runs on the hypervisor host network and plays the ToR role:
# it accepts dynamic BGP sessions from the cluster nodes on the dev-scripts
# baremetal network (192.168.111.0/24) and installs learned VIP /32 routes
# into the host kernel via zebra.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=bgp-tor
IMAGE=quay.io/frrouting/frr:9.1.0

case "${1:-}" in
up)
  sudo firewall-cmd --zone=libvirt --add-port=179/tcp --permanent
  sudo firewall-cmd --reload
  sudo podman run -d --name "$NAME" --net host --privileged \
    -v "$DIR/tor/frr.conf:/etc/frr/frr.conf:z" \
    -v "$DIR/tor/daemons:/etc/frr/daemons:z" \
    "$IMAGE"
  echo "ToR up. BGP listening on 192.168.111.1:179 (host network)."
  ;;
down)
  sudo podman rm -f "$NAME" || true
  sudo firewall-cmd --zone=libvirt --remove-port=179/tcp --permanent
  sudo firewall-cmd --reload
  ;;
status)
  sudo podman exec "$NAME" vtysh -c "show bgp summary"
  sudo podman exec "$NAME" vtysh -c "show ip bgp"
  ip route show proto bgp || true
  ;;
*)
  echo "usage: $0 up|down|status" >&2
  exit 1
  ;;
esac
