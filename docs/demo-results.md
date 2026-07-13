# BGP VIP Demo — Results Log

Last updated: 2026-07-13 (scope extension complete, runs 1–17) — ALL DEMO CRITERIA MET ON A FULL CLUSTER (routers on workers)

## Demo acceptance status

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Bootstrap advertises API VIP via BGP | **PROVEN** | run5-10: `192.168.111.5/32` in ToR BGP table, next-hop = bootstrap; `ip route show table 198` on bootstrap; kube-vip route add logged |
| 2 | Masters join via the VIP; install proceeds | **PROVEN** | run6-10: all 3 masters Ready, joined through BGP-routed VIP; hypervisor `ip route get 192.168.111.5` → `via <node> proto bgp` (L3 path, not connected /24) |
| 3 | API `healthz: ok` over the BGP-routed VIP | **PROVEN** | run6+: curl via VIP with kernel ECMP over BGP next-hops |
| 4 | Ingress VIP advertised, health-gated | **PROVEN (run14, full cluster run17)** | `192.168.111.4/32` advertised ONLY from the two router-bearing masters (run14) / router-bearing WORKERS .23/.24 (run17); gate = router healthz :1936 (EP's :29445 was the API haproxy monitor — wrong) |
| 5 | CNO renders FRRConfiguration; controller applies it (handover) | **PROVEN (run14)** | `bgp-vip-master` CR created and accepted (run8+; renamed cluster-wide `bgp-vip` in run15+); controller applies (reloader "FRR reloaded successfully"); sessions re-established through CRD path; advertisement survives via gated redistribution + raw egress permits; FRRNodeState + BGPSessionState (Established x3) reported |
| 6 | Install completes end-to-end | **PROVEN (run14)** | 35/36 cluster operators Available; console HTTP 200 over the BGP-routed ingress VIP. Sole failure: karpenter — "unsupported platform" on baremetal, base-nightly bug, fails identically without BGP |
| 7 | Full cluster: routers on workers, health-gated ECMP + failover | **PROVEN (run17)** | 3 masters + 2 workers, zero manual intervention: ingress .4 ECMP from exactly the two router workers, API .5 ECMP from 3 masters, single cluster-wide `bgp-vip` CR, console 200, `ip route get` = L3 path. Failover: cordon + router pod delete → path withdrawn ~50s (health threshold), console 200 throughout via the surviving worker; uncordon → restored ≤20s. Plain pod delete does NOT withdraw (replacement Ready before the failure threshold) |

## Resolved: the CRD-handover advertisement issue

Root cause was upstream FRR bug (zebra import-table clears SELECTED on source
routes; table-direct walk skips unselected — FRRouting/frr b2c17ad52, fixed
in 10.7, backported here onto 10.4.3; see patches/frr/
and the 4-case container lab in the session log). Plus two frr-k8s semantic
layers: mode:all egress is bound to declared router prefixes (deny-any
otherwise) — solved with high-seq raw route-map permits; and ip import-table
must be present for zebra to track table 198.

## Resolved: the worker-ingress advertisement race (runs 15-17)

Second, distinct zebra bug found while extending scope to workers: when the
same-prefix interface address (kube-vip AddIP, deprecated /32) and the
table-198 route arrive in the same netlink batch, zebra keeps the kernel
route but never imports/redistributes it (lab TEST E,
`lab/frr-lab-addr-route-race.sh`: 2/5 with `ip -batch`; route→addr order =
100% broken). NOT covered by the patched 10.4.3 zebra (the SELECTED-flag
fix, RHEL-193997). Worked around in kube-vip: level-triggered route
re-assertion (6d51cbd) + realm 1↔2 toggle so each replace is a real kernel
change emitting a netlink event (7d27248) — a no-op replace emits NONE,
which also broke plain re-assertion in run16. Upstream zebra bug to file
(NEXT-STEPS §B).

## Verified working (accumulated across runs)

- Whole peer-data pipeline: install-config `bgpVIPConfig` → installer ConfigMap → MCO bootstrap render + day-2 sync → `frr-peers.json` on nodes → runtimecfg render → FRR sessions. Byte-verified on nodes.
- kube-vip routing-table mode with downstream patches: explicit kubeconfig + local apiserver, health-gated route in table 198, VIP address management. Route appears/disappears with apiserver health (observed live).
- kube-vip-ingress health gate against haproxy-monitor :29445 (503 → no route; healthy → route).
- MCO: BGP mode detection, keepalived disable, static pod manifests (bootstrap FRR-only + day-2 full), image resolution from payload (incl. new `kube-vip` payload tag), no label-node.
- CNO: FRR bindata deploy via installer's additionalRoutingCapabilities; role-based DaemonSet anti-affinity under BGP mode; empty-DaemonSet status fix (compact clusters); RBAC for the node-bootstrapper SA identity (verified live via `oc auth whoami`); FRRConfiguration render behind known+enabled feature gate.
- cluster-config-api payload swap carries the `vipManagement` CRD field + `BGPBasedVIPManagement` gate → persists on live Infrastructure, FeatureGate status lists it.
- ToR (FRR container, dynamic neighbors, RFC-8212 relaxed): 4 concurrent sessions, ECMP multipath install on the hypervisor.

## EP-relevant design findings (feed back into enhancement 1982)

1. **kube-vip RT-mode advertises from every instance** (health-gated), not just the lease leader — upstream behavior; EP's iteration-1 active/passive claim needs a downstream leadership gate or an EP update embracing ECMP with health gating (it worked well: per-node apiserver health controlled per-node advertisement).
2. **CRD `prefixes`/`toAdvertise` are static advertisements** — they defeat kube-vip's health gating. VIP advertisement must stay on the `redistribute table-direct 198` path (or frr-k8s needs a "conditional advertisement" concept upstream).
3. `/etc/kubernetes/kubeconfig` identity is the MCO `node-bootstrapper` SA — EP's RBAC section should specify it.
4. NodeRestriction blocks node-credential labeling → the EP's label-based DaemonSet avoidance doesn't work; role-based anti-affinity is the design.
5. frr-k8s validation webhook requires router-level `prefixes` for any `toAdvertise` prefixes.
6. CNO status manager treated desired=0 DaemonSets as stuck (fixed; needed for compact clusters under BGP mode).
7. upstream kube-vip ignores `k8sConfigPath` in both manager init and backend health checks (two downstream patches).
8. FRR < 10.7: routes pre-existing in a table at config time are never
   redistributed via table-direct (zebra import clears SELECTED on source
   routes; even de-selects). Upstream fix FRRouting/frr b2c17ad52 backported
   (see patches/frr/ + lab/).
9. Ingress VIP health source is the router `:1936/healthz` (keepalived's
   chk_ingress) — the EP's `:29445` is the API haproxy monitor.
10. frr-k8s `toAdvertise.allowed.mode: all` egress covers only DECLARED router
   prefixes (deny-any lists otherwise) — the CRD cannot express advertising
   redistributed routes. Demo uses high-seq raw permits into the generated
   `<peer>-out` route-maps (couples to internal naming; upstream feature
   request needed).
11. frr-status requires `--pod-name` (mirror pod name `frr-k8s-<node>`) for
   static pod deployments.

## Related documents

- docs/RUN-LEDGER.md — per-run debugging narrative (runs 1-17)
- docs/RUNBOOK.md — operational procedures
- docs/NEXT-STEPS.md — productization handoff
- docs/PATCHES.md — authoritative commit inventory (supersedes the list below,
  which is session-1 only)

## Commits produced this session

- installer: bc43c457ed, 91ad587234, 9dea799e48
- openshift-api: ad8da98b9c, 2d1992b696
- MCO: 7f9470e839, 2e5240b156, c0e4d55624, e7f3eb4266, ec43198cf6, 56cb9e404a, 9199298554, c7ff25af21, fd072b1a02, c1bf266e1e, 5b311c8eef, bd240b8c60
- CNO: c5e3636079, bcb76bbafb, 39e5182f79, a62d892c0c, 07a24912c0, 0a45791557, c04ab0abbc, 9222d84075, ecb5282fe8, 93e48830e
- kube-vip: 3518dd2 (cherry-pick), 7a6c161, 9531dd0, 173173011a, 8cd17f786c
- bgp-vip-demo: spec, plan, ToR helper, this results log

## Environment

- Hypervisor: root@metal-u15 (dev-scripts /root/dev-scripts, config_root.sh — demo config; previous config preserved at config_root.sh.pre-bgp-demo)
- ToR: `/root/bgp-vip-demo/bgp-tor.sh` (FRR 9.1 container, host network, AS 64513, dynamic neighbors 192.168.111.0/24, RFC8212 relaxed)
- Payload: quay.io/mkowalski/ocp-release:bgp-vip-demo (5.0 nightly 2026-07-07-232341 + 5 image overrides)
- Redeploy sequence (make redeploy UNUSABLE — wipes install-config patch):
  `make ocp_cleanup && make build_installer install_config && <re-patch bgpVIPConfig> && make ocp_run`
