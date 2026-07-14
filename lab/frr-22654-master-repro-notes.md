# FRRouting/frr#22654 — master reproduction (2026-07-14)

Master builds at `570dff3` / zebra binary `FRRouting 10.8.0-dev (f6016b68d844)`,
CentOS Stream 9 container, kernel 5.14.0-697.el9.

## Matrix (VIP=192.0.2.99, dummy0, `ip import-table 198` active at boot)

| Test | Sequence | Result |
|---|---|---|
| M1 x3 | `ip route add ... table 198` then `ip addr add` (sequential commands) | **broken 3/3** (kernel=1 zebra=0 bgp=0) |
| M2 x5 | addr then route, one `ip -batch` | OK 5/5 |
| M3 x5 | route then addr, one `ip -batch` | **broken 5/5** |

Master hits the route→addr ordering even with plain sequential commands (no
batch needed) — the address processing detours through the dplane
(`INTF_ADDR_ADD ... result QUEUED`), so the same-prefix cleanup fires while the
route still sits in the early queue. Compare 10.4.3: route→addr sequential also
100%, addr→route needed a batch (2/5).

## Smoking gun (master log format, tag KT7ER-TZD46)

```
Route 192.0.2.99/32(default:unicast) (add) queued for processing into sub-queue Early Route Processing mq size 1
netlink_interface_addr_dplane: RTM_NEWADDR ... IFA_LOCAL 192.0.2.99/32
zebra_if_addr_update_ctx: INTF_ADDR_ADD: ifindex dummy0(3), addr 192.0.2.99/32
Route 192.0.2.99/32(default:unicast) type kernel(1) removed from early route queue
```

Then only the connected/local table-254 entries are inserted; the table-198
route never reappears. End state: kernel has the route, `show ip route table
198` empty, BGP empty.

## Code pointer (master)

`connected_remove_kernel_for_connected()` (zebra/connected.c:198) →
`rib_meta_queue_early_route_cleanup()` (zebra/zebra_rib.c:4343): matches queued
entries on prefix + type + afi + safi + vrf_id — **no table comparison** — so a
same-vrf kernel route in an unrelated table (import-table-tracked 198) is
discarded when the connected route for the prefix arrives. Same root cause as
10.4.3; master only added the afi/safi/vrf scoping (and moved the entry free
below the debug log, fixing the UAF 10.4.3 still has).

Fix validated on 10.4.3 (branch `table-scoped-early-cleanup` on mkowalski/frr,
commit 8989c33): add a table_id parameter, compare `ere->re->table`, caller
passes `zvrf->table_id`. Forward-port to master is the same one-line predicate
addition.

Full logs: `frr-22654-debug-zebra-rib-detailed.log` (stock 10.4.3),
`frr-22654-master-debug-zebra-rib-detailed.log` (master).
