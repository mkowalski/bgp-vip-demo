#!/bin/sh
# TEST E: does an RTM_NEWADDR immediately before the table-198 RTM_NEWROUTE
# (kube-vip's AddIP + routeMgr.Add sequence) make zebra miss the route event?
# Run INSIDE metallb-frr image. Full config (import-table + table-direct) at boot.
set -x
VIP=192.0.2.99

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
cat > /etc/frr/daemons <<EOF
zebra=yes
bgpd=yes
bfdd=no
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
EOF
touch /etc/frr/vtysh.conf

ip link add dummy0 type dummy
ip link set dummy0 up
ip addr add 192.0.2.10/32 dev dummy0

/usr/lib/frr/docker-start &
sleep 6

check() {
  Z=$(vtysh -c "show ip route table 198" 2>/dev/null | grep -c "${VIP}")
  B=$(vtysh -c "show ip bgp" 2>/dev/null | grep -c "${VIP}")
  echo "RESULT $1 zebra=${Z} bgp=${B}"
}
cleanup() {
  ip route del ${VIP}/32 table 198 2>/dev/null
  ip addr del ${VIP}/32 dev dummy0 2>/dev/null
  sleep 2
}

for i in 1 2 3; do
  echo "@@@ E1.$i addr+route back-to-back (kube-vip order)"
  ip addr add ${VIP}/32 dev dummy0
  ip route add ${VIP}/32 dev dummy0 table 198 proto 248
  sleep 4; check "E1.$i"; cleanup
done

for i in 1 2 3; do
  echo "@@@ E2.$i route THEN addr"
  ip route add ${VIP}/32 dev dummy0 table 198 proto 248
  ip addr add ${VIP}/32 dev dummy0
  sleep 4; check "E2.$i"; cleanup
done

for i in 1 2 3; do
  echo "@@@ E3.$i addr, settle 2s, route"
  ip addr add ${VIP}/32 dev dummy0
  sleep 2
  ip route add ${VIP}/32 dev dummy0 table 198 proto 248
  sleep 4; check "E3.$i"; cleanup
done

echo "@@@ E4: route only, no addr ever"
ip route add ${VIP}/32 dev dummy0 table 198 proto 248
sleep 4; check "E4"

echo "@@@ LAB E DONE"
