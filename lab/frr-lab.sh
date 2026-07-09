#!/bin/sh
# FRR table-direct/import-table behavior lab.
# Runs INSIDE the metallb-frr image (FRR 10.x, mgmtd).
# Mimics the BGP VIP setup: kube-vip route in kernel table 198,
# advertisement via redistribute table-direct 198 + route-map filter.
set -x

VIP=192.0.2.99

full_config() {
cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname frr-lab
log stdout informational
ip import-table 198
!
router bgp 64512
 bgp router-id 192.0.2.10
 no bgp ebgp-requires-policy
 address-family ipv4 unicast
  redistribute table-direct 198 route-map BGP-VIP-ROUTES-V4
 exit-address-family
!
route-map BGP-VIP-ROUTES-V4 permit 10
 match ip address prefix-list BGP-VIP-PREFIXES-V4
route-map BGP-VIP-ROUTES-V4 deny 20
ip prefix-list BGP-VIP-PREFIXES-V4 seq 10 permit ${VIP}/32
EOF
}

minimal_config() {
cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname frr-lab
log stdout informational
!
router bgp 64512
 bgp router-id 192.0.2.10
 no bgp ebgp-requires-policy
EOF
}

start_frr() {
  # daemons file: match the static pod (zebra/bgpd/bfdd) + mgmtd implicit
  cat > /etc/frr/daemons <<EOF
zebra=yes
bgpd=yes
bfdd=no
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
EOF
  touch /etc/frr/vtysh.conf
  /usr/lib/frr/docker-start &
  sleep 6
}

check() {
  echo "===== $1 ====="
  vtysh -c "show ip route table 198" 2>&1 | grep -E "198|${VIP}" || echo "(zebra: table 198 empty)"
  vtysh -c "show ip bgp" 2>&1 | grep -E "${VIP}|No BGP" || echo "(bgp table empty)"
}

# --- interface + baseline
ip link add dummy0 type dummy
ip link set dummy0 up
ip addr add 192.0.2.10/32 dev dummy0

echo "@@@@@@ TEST A: full config at startup, route PRE-EXISTING @@@@@@"
ip route add ${VIP}/32 dev dummy0 table 198 proto 248
full_config
start_frr
check "A: after startup (route pre-existing)"

echo "@@@@@@ TEST B: route removed and re-added AFTER startup @@@@@@"
ip route del ${VIP}/32 table 198
sleep 3
check "B0: after route delete"
ip route add ${VIP}/32 dev dummy0 table 198 proto 248
sleep 3
check "B: after route re-add (daemon running)"

echo "@@@@@@ TEST C: reload-delta path (frr-reload.py minimal->full) @@@@@@"
# restart with minimal config
pkill -f watchfrr; pkill zebra; pkill bgpd; pkill mgmtd; pkill staticd; sleep 3
minimal_config
start_frr
check "C0: minimal config running"
# now write the FULL config and apply via frr-reload (the frr-k8s reloader path)
full_config
python3 /usr/lib/frr/frr-reload.py --reload --overwrite /etc/frr/frr.conf 2>&1 | tail -5
sleep 4
check "C1: after frr-reload to full config"
vtysh -c "show running-config" | grep -E "import-table|redistribute" 
# route churn after reload
ip route del ${VIP}/32 table 198; sleep 2
ip route add ${VIP}/32 dev dummy0 table 198 proto 248; sleep 3
check "C2: after route churn post-reload"

echo "@@@@@@ TEST D: vtysh live config on top of minimal @@@@@@"
pkill -f watchfrr; pkill zebra; pkill bgpd; pkill mgmtd; pkill staticd; sleep 3
minimal_config
start_frr
vtysh -c "configure terminal" \
      -c "ip import-table 198" \
      -c "ip prefix-list BGP-VIP-PREFIXES-V4 seq 10 permit ${VIP}/32" \
      -c "route-map BGP-VIP-ROUTES-V4 permit 10" -c "match ip address prefix-list BGP-VIP-PREFIXES-V4" -c "exit" \
      -c "route-map BGP-VIP-ROUTES-V4 deny 20" -c "exit" \
      -c "router bgp 64512" -c "address-family ipv4 unicast" \
      -c "redistribute table-direct 198 route-map BGP-VIP-ROUTES-V4" \
      -c "end" 2>&1 | tail -3
sleep 4
check "D1: after vtysh live config"
ip route del ${VIP}/32 table 198; sleep 2
ip route add ${VIP}/32 dev dummy0 table 198 proto 248; sleep 3
check "D2: after route churn post-vtysh"

echo "@@@@@@ LAB DONE @@@@@@"
