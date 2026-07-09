#!/bin/sh
set -x
VIP=192.0.2.99
ip link add dummy0 type dummy && ip link set dummy0 up && ip addr add 192.0.2.10/32 dev dummy0
ip route add ${VIP}/32 dev dummy0 table 198 proto 248
cat > /etc/frr/daemons <<D
zebra=yes
bgpd=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
D
touch /etc/frr/vtysh.conf
cat > /etc/frr/frr.conf <<CFG
frr defaults traditional
hostname frr-lab
router bgp 64512
 bgp router-id 192.0.2.10
 no bgp ebgp-requires-policy
CFG
/usr/lib/frr/docker-start &
sleep 6
echo "===== C0 minimal ====="
vtysh -c "show ip bgp" | grep -E "${VIP}|No BGP"
cat > /etc/frr/frr.conf <<CFG
frr defaults traditional
hostname frr-lab
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
python3 /usr/lib/frr/frr-reload.py --reload --overwrite /etc/frr/frr.conf 2>&1 | tail -2
for t in 5 10 20 30; do sleep $((t==5?5:10)); echo "===== C1 at +${t}s ====="; vtysh -c "show ip bgp" | grep -E "${VIP}|No BGP"; done
