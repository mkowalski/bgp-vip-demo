# FRRouting bug report — DRAFT, paste into https://github.com/FRRouting/frr/issues/new (Bug report template)

Suggested title:
**zebra: imported kernel-table route (`ip import-table`) lost when a same-prefix interface address is added in the same netlink batch**

---

## Description

zebra permanently loses a kernel route in a non-main routing table (tracked via
`ip import-table` and redistributed via `redistribute table-direct`) when an
interface **address for the same prefix** is added immediately before the route,
such that both netlink messages arrive in the same processing batch.

The route remains present in the kernel table, but zebra's view of that table
stays empty (`show ip route table 198` shows nothing), so the table-direct
redistribution never announces the prefix. The state is permanent: zebra never
recovers on its own. Any later netlink event for the route (delete + re-add, or
a `replace` that actually changes an attribute) heals it. A no-op
`ip route replace` does not, since the kernel emits no notification for it.

Real-world impact: VIP/anycast health-gating setups where an agent (kube-vip in
our case) plumbs the VIP address on an interface and installs a same-prefix /32
into a dedicated table back-to-back — the VIP silently never gets advertised.
On a busy host (heavy netlink churn at boot) we hit this on 5 out of 5 nodes of
a cluster; in the minimal reproducer below it hits ~2/5 iterations.

Ordering matters: adding the route *before* the address fails deterministically
(100%) in the reproducer; address-then-route fails only when the two messages
land in the same batch (`ip -batch`, or separate commands on a busy system).

## Version

```
FRRouting 10.4.3 (0111b3833f21) on Linux(5.14.0-697.el9.x86_64).
```

(el9 build, `--enable-fpm`, multipath 64 — full `configured with` available on
request. Also reproduces with the stable/10.4 backport of b2c17ad52 ("zebra:
Do not clear selected flag on route about to be imported") applied, so it is
distinct from issue fixed there. Not yet tested on current master — the code
paths involved, `rib_add_multipath`/connected route processing vs.
`zebra_import_table`, look unchanged at a glance.)

## How to reproduce

Single router, one dummy interface. `/etc/frr/frr.conf`:

```
frr defaults traditional
hostname frr-lab
log stdout informational
ip import-table 198
!
router bgp 64512
 bgp router-id 192.0.2.10
 no bgp ebgp-requires-policy
 address-family ipv4 unicast
  redistribute table-direct 198 route-map GATED-V4
 exit-address-family
!
route-map GATED-V4 permit 10
 match ip address prefix-list GATED-PFX-V4
route-map GATED-V4 deny 20
ip prefix-list GATED-PFX-V4 seq 10 permit 192.0.2.99/32
```

Daemons: zebra + bgpd (mgmtd implicit). Then:

```sh
ip link add dummy0 type dummy
ip link set dummy0 up
ip addr add 192.0.2.10/32 dev dummy0
# start FRR, wait for config to load, then:

cat > /tmp/batch <<'EOF'
address add 192.0.2.99/32 dev dummy0
route add 192.0.2.99/32 dev dummy0 table 198 proto 248
EOF
ip -batch /tmp/batch          # same-prefix address + route in one batch

sleep 4
vtysh -c "show ip route table 198"
vtysh -c "show ip bgp"
ip route show table 198       # kernel still has the route
```

Repeat a few times (cleanup between iterations:
`ip route del 192.0.2.99/32 table 198; ip addr del 192.0.2.99/32 dev dummy0`).
~2/5 iterations reproduce with the batch; swapping the two batch lines
(route first, then address) reproduces 5/5.

## Expected behavior

zebra tracks the kernel route in table 198 regardless of the same-prefix
interface address (they coexist: the connected /32 lives in the main table, the
kernel route in table 198), shows it in `show ip route table 198` as `K>*`, and
the table-direct redistribution announces `192.0.2.99/32` via BGP.

This is exactly what happens when the route event arrives on its own (e.g.
address settled first, or route deleted and re-added later).

## Actual behavior

Kernel and zebra disagree, permanently:

```
# ip route show table 198
192.0.2.99 dev dummy0 proto 248 scope link

# vtysh -c "show ip route table 198"
(empty)

# vtysh -c "show ip bgp"
No BGP prefixes displayed, 0 exist
```

The route-map counters confirm redistribution never evaluated anything
(`show route-map GATED-V4`: Invoked: 0). No errors or drops are logged by zebra
(informational logging; no "buffer overrun" or netlink errors).

Healing triggers (each verified): `ip route del` + `ip route add`;
`ip route replace` **with a changed attribute** (e.g. different scope or realm).
Not healing: no-op `ip route replace` (kernel emits no rtnetlink notification).

## Additional context

- Found while implementing health-gated VIP advertisement: kube-vip plumbs the
  VIP address on the interface and installs a same-prefix /32 into table 198
  back-to-back; FRR (via frr-k8s) imports and redistributes table 198. On real
  hosts under boot-time netlink churn the loss rate was 5/5 nodes.
- Distinct from the import-table issue fixed by b2c17ad52 (SELECTED flag
  cleared on pre-existing routes): that one shows the route in
  `show ip route table 198` but fails to redistribute; here zebra's table view
  is entirely empty, and the bug reproduces with that fix applied.
- Suspected area: processing of the connected/local route for the new address
  and the kernel route for the same prefix within one netlink read cycle —
  the same-prefix connected route processing appears to clobber/short-circuit
  the rib entry for the other table. Happy to run instrumented builds or
  provide `debug zebra kernel`/`debug zebra rib detailed` captures.
- Full reproducer script (containerized, iterates all orderings):
  https://github.com/mkowalski/bgp-vip-demo/blob/main/lab/frr-lab-addr-route-race.sh

## Checklist

- [x] I have searched the open issues for this bug.
- [x] I have not included sensitive information in this report.
