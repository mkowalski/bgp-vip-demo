#!/bin/sh
# Does `ip route replace` (identical route) heal an unselected table-direct route?
set -x
VIP=192.0.2.99
ip link add dummy0 type dummy && ip link set dummy0 up && ip addr add 192.0.2.10/32 dev dummy0
ip route add ${VIP}/32 dev dummy0 table 198 proto 248
cat > /etc/frr/frr.conf <<CFG
frr defaults traditional
hostname frr-lab
log stdout informational
ip import-table 198
router bgp 64512
 bgp router-id 192.0.2.10
 no bgp ebgp-requires-policy
 address-family ipv4 unicast
  redistribute table-direct 198 route-map RM
 exit-address-family
route-map RM permit 10
 match ip address prefix-list PL
route-map RM deny 20
ip prefix-list PL seq 10 permit ${VIP}/32
CFG
cat > /etc/frr/daemons <<D
zebra=yes
bgpd=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
D
touch /etc/frr/vtysh.conf
/usr/lib/frr/docker-start &
sleep 6
echo "===== broken baseline (pre-existing route) ====="
vtysh -c "show ip bgp" | grep -E "${VIP}|No BGP"
echo "===== ip route replace (identical) ====="
ip route replace ${VIP}/32 dev dummy0 table 198 proto 248
sleep 3
vtysh -c "show ip route table 198" | grep 192.0.2.99
vtysh -c "show ip bgp" | grep -E "${VIP}|No BGP"
echo "===== LAB2 DONE ====="
