# frr-k8s feature request: advertise redistributed / table-direct routes

Status: **FILED as https://github.com/metallb/frr-k8s/issues/469** (2026-07-14).
This file is kept as the source-verified reference material behind the issue.
Tracked in NEXT-STEPS.md §B.

---

Title: **CRD cannot express "advertise redistributed routes" — egress is bound to statically declared prefixes**

## Use case

We advertise virtual IPs (API/ingress VIPs of an OpenShift baremetal cluster) with
per-node health gating: a local agent (kube-vip) installs a /32 (or /128) route
into a dedicated kernel table (198) only while the VIP's backend on that node is
healthy. FRR advertises whatever is in that table via:

```
ip import-table 198
router bgp 64512
 address-family ipv4 unicast
  redistribute table-direct 198 route-map BGP-VIP-ROUTES-V4
```

Withdrawal is then automatic and per-node: backend unhealthy → route removed from
the table → prefix withdrawn from that node's sessions, while other healthy nodes
keep advertising (ECMP). The pattern generalizes to anything that conditions
advertisement on local state via kernel routes (health checkers, custom
controllers) rather than statically declared prefixes.

## What the CRD cannot express today

1. `router.prefixes` renders as unconditional `network` statements — advertising a
   VIP this way bypasses the health gating entirely (the prefix stays advertised
   while the backend is dead). Not usable for this pattern.
2. `toAdvertise.allowed.mode: all` does not mean "everything this router
   redistributes": `prefixesToAdvertiseForFamily`
   (internal/controller/api_to_config.go) only permits prefixes from
   `router.prefixes`, and with none declared the generated `<peer>-allowed-*`
   prefix-lists are `deny any`. There is no way to allow egress for routes that
   arrive via redistribution.

## Our workaround (and why it's fragile)

The `import-table` + `redistribute table-direct` block goes into `rawConfig`, and
egress is opened by appending high-sequence permits to the route-maps frr-k8s
itself generates per neighbor:

```
route-map 192.168.111.1-out permit 4000
 match ip address prefix-list BGP-VIP-PREFIXES-V4
```

This works because a route-map entry whose match fails falls through to the next
sequence, so the generated deny-any semantics stay intact for everything else.
But it couples user config to frr-k8s internals:

- the `<neighborID>-out` naming convention (`NeighborConfig.ID()`,
  internal/frr/config.go; referenced from
  internal/frr/templates/neighboripfamily.tmpl and prefixlists.tmpl);
- the sequence-number layout of the generated entries (the `counter`-driven
  seqs in prefixlists.tmpl — our permits sit at 4000/4001 to stay clear of
  them, an offset nothing guarantees).

Any refactor of the template naming or numbering silently breaks egress for us
across version bumps.

## Feature request

First-class CRD support for advertising redistributed routes, e.g. either:

- a `router.redistribute` stanza:

  ```yaml
  routers:
  - asn: 64512
    redistribute:
    - protocol: table-direct   # or connected/static/kernel
      table: 198
      allowedPrefixes:         # egress filter, rendered into <peer>-out
      - 192.168.111.4/32
      - 192.168.111.5/32
  ```

- or an extension of `toAdvertise` that can reference a redistribution source
  instead of only statically declared prefixes, rendered as prefix-list permits
  in the generated `-out` route-maps (not as `network` statements).

The essential semantics: reachability is decided by the (dynamically populated)
kernel table; the CRD only bounds *which* prefixes may leave; egress filtering
composes with the generated route-maps without users touching their internal
names.

Happy to contribute the implementation if the direction is acceptable.

---

## Filing notes (not part of the issue body)

- Verified against frr-k8s source at the ose-frr 5.0 sync (5d3b12b6):
  `prefixesToAdvertiseForFamily` api_to_config.go:397 (mode=all iterates only
  `prefixesInRouter`); `NeighborConfig.ID()` config.go:90; `{{.ID}}-out` in
  neighboripfamily.tmpl:12,19 and prefixlists.tmpl:9,33,36.
- Live context if asked for reproduction: CNO `buildBGPVIPRawConfig`
  (pkg/network/bgp_vip.go) renders the workaround; run12 in the demo RUN-LEDGER
  documents the `mode: all` = deny-any discovery.
- Consider linking the zebra addr/route batch race as related-but-separate
  (lab/frr-lab-addr-route-race.sh) only if reviewers ask why table-direct.
