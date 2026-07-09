# BGP VIP Demo — Results Log

Last updated: 2026-07-09 (session 1, runs 1–10)

## Demo acceptance status

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Bootstrap advertises API VIP via BGP | **PROVEN** | run5-10: `192.168.111.5/32` in ToR BGP table, next-hop = bootstrap; `ip route show table 198` on bootstrap; kube-vip route add logged |
| 2 | Masters join via the VIP; install proceeds | **PROVEN** | run6-10: all 3 masters Ready, joined through BGP-routed VIP; hypervisor `ip route get 192.168.111.5` → `via <node> proto bgp` (L3 path, not connected /24) |
| 3 | API `healthz: ok` over the BGP-routed VIP | **PROVEN** | run6+: curl via VIP with kernel ECMP over BGP next-hops |
| 4 | Ingress VIP advertised, health-gated | **PROVEN (run8)** | `192.168.111.4/32` in ToR table from masters; kube-vip-ingress correctly gates on haproxy 503/200 (visible in logs) |
| 5 | CNO renders FRRConfiguration; controller applies it (handover) | **PARTIAL** | `bgp-vip-master` CR created and accepted (run8+); controller applies (reloader "FRR reloaded successfully"); sessions re-established through CRD path; **advertisement via CR config broken — see Open Issue** |
| 6 | Install completes end-to-end | **NOT YET** | Blocked by Open Issue (VIP advertisement lost after handover → in-subnet L2 masks it partially; installer flaps) |

## Open Issue (single remaining blocker)

**CR-based FRR config does not export table-direct routes on masters.**

Timeline of understanding:
- run8: CR advertised VIPs as CRD `prefixes` → unconditional `network` statements (origin `i`) → health gating LOST → ECMP to dead apiservers → redesigned to gated redistribution (CNO commit 9222d840).
- run9: sessions-only CR + rawConfig redistribute → frr-k8s renders deny-all outbound maps without `toAdvertise` → fixed with `mode: all` (ecb5282f). At this point on master-0 the VIP was IN bgpd's table (weight 32768, origin `?`) — gating worked — but egress was blocked.
- run10: with mode:all, bgpd's local table is EMPTY on masters: zebra does not track table 198 (`show ip route table 198` empty; kernel table populated). Bootstrap config carries `ip import-table 198` → added to rawConfig (93e48830) — **not yet validated by a full run**.
- Live probes on run10 master-0: manual `ip import-table 198` via vtysh did NOT populate bgpd's table; route bounce did not either; frr container restart inconclusive (container startup loads the runtimecfg static config, then the controller re-applies the CR delta — mixed signal).

Hypotheses for next session (ordered):
1. `ip import-table` + `redistribute table-direct` interaction requires both at bgpd/zebra STARTUP (registration not retrofittable via vtysh/reload) → validate with run11 (93e48830 puts import-table in the CR config from the start — but it still arrives via reloader delta post-startup; may need frr-k8s to restart daemons, or advertisement must stay in the static startup config).
2. frr-k8s's generated config sections and rawConfig merge ordering interfere with table-direct registration.
3. Consider EP-design pivot for iteration 1: the CR carries sessions only; VIP advertisement REMAINS in the runtimecfg static config which frr-k8s must not override (requires frr-k8s base-config support — upstream conversation), or defer CRD handover of advertisement entirely.

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
8. frr-reload/table-direct/import-table lifecycle is fragile post-startup (open issue above).

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
