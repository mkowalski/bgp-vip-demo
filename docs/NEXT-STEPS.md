# Next Steps — productization handoff

What remains between "working dev demo" and Tech Preview per the enhancement's
graduation criteria. Ordered by dependency. Anyone picking this up: read
README.md → demo-results.md → RUN-LEDGER.md first; RUNBOOK.md to reproduce.

## A. Enhancement text corrections (PR 1982)

Findings the demo proved against the current EP text — update the doc:

1. **Ingress health check endpoint**: EP says `http://localhost:29445/healthz`.
   Wrong — that's baremetal-runtimecfg's API-haproxy monitor (503 on masters,
   ::1). The router health is `http://localhost:1936/healthz` (same as
   keepalived's `chk_ingress`).
2. **Active/passive claim**: kube-vip RT-mode's health loop runs on every
   instance regardless of leader election — the real model is
   **health-gated ECMP** (all healthy nodes advertise; per-node health
   withdraws per-node paths). It behaves well; the EP should either embrace it
   (recommended — it matched the "split-brain is benign ECMP" analysis) or a
   downstream leadership gate must be added to kube-vip.
3. **Advertisement mechanism**: EP's day-2 `FRRConfiguration` sketch implies
   the CRD carries the VIP prefixes. CRD prefixes render as unconditional
   `network` statements and destroy health gating (run8 outage). Advertisement
   must stay on `redistribute table-direct 198` (+ filters), delivered via
   rawConfig; the CR carries sessions. Document the `ip import-table 198`
   requirement and the raw `<peer>-out` route-map permits.
4. **RBAC identity**: `/etc/kubernetes/kubeconfig` = SA
   `openshift-machine-config-operator/node-bootstrapper`, not a node identity.
   EP's day-2 section should specify it (and the per-node CR write-scoping
   admission gap — see D3).
5. **DaemonSet avoidance**: the label-based anti-affinity design cannot work
   (NodeRestriction denies node-credential labels + scheduling races).
   Role-based anti-affinity under BGP mode is the design; drop the label +
   `runtimecfg label-node` from the EP.
6. **FRR bug prerequisite**: note the dependency on FRRouting/frr b2c17ad52
   (zebra import-table SELECTED flag) — required for any FRR < 10.7.
7. Minor: frr-k8s webhook requires router-level prefixes for toAdvertise;
   `bfdEnabled`/`ebgpMultiHop` string typing rationale; bootstrap pod is
   FRR-only (no controller/status/metrics — the EP's static pod sketch
   includes them).

## B. Upstream contributions

| Where | What | Artifact |
|-------|------|----------|
| kube-vip | manager + backend honor `k8sConfigPath`/`k8s_config_file` (+`kubernetes_addr`) | commits 173173011, 8cd17f786 — generic fixes, PR-ready |
| frr-k8s (metallb/frr-k8s) | Feature request: advertise redistributed/table-direct routes (CRD egress is bound to declared prefixes; our raw `-out` route-map permits couple to internal naming — fragile across bumps) | design note in CNO bgp_vip.go comments |
| FRR | b2c17ad52 backport request to stable/10.4 (or confirm 10.7 uptake downstream) | `frr-zebra-import-table-selected.patch` |
| dev-scripts | **DONE** — `ENABLE_BGP_TOR` on fork branch `bgp-tor-speaker` (f6b686c), live-validated; ready to PR to openshift-metal3/dev-scripts | dev-scripts repo |

## C. Downstream productization

1. **frr10 RPM backport** (el9) of the zebra fix — the demo overlays the
   binary in the image; production needs the RPM (or ose-frr image carry).
   Owner: whoever owns the frr10 package + ART.
2. **ocp-build-data**: add `kube-vip` payload member (ose-kube-vip image from
   the fork) BEFORE MCO's image-references change merges — otherwise nightly
   payload assembly breaks (unresolvable tag).
3. **PR strategy per repo** (all branches carry demo shortcuts to unwind):
   - openshift/api: 2 commits, PR-ready; squash the stale-regen fallout into
     the parent commit per reviewer note.
   - installer: rebase `-vendored` onto the clean branch; re-vendor from the
     merged api instead of local content.
   - **MCO: go.mod has a LOCAL-PATH replace for openshift/api** (dev-only) —
     must be swapped to the merged api version. `-dev` branch also carries the
     old "hardcode kube-vip image" commit history; rebase/squash the -dev/
     -vendored layering into a clean PR series.
   - CNO: re-vendor; the 13-commit sequence tells the debugging story — squash
     into logical units (render, RBAC, status-manager fix, advertisement
     mechanism).
   - kube-vip: split upstream-able fixes (2) from downstream build bits (3).
   - baremetal-runtimecfg: drop the now-unused `label-node` command before PR.
4. **CNO status-manager fix** (c04ab0abb, desired==0 DaemonSets) is
   BGP-independent and mergeable on its own — extract it first, it's a real
   bug for anyone shipping optional DaemonSets.

## D. Known gaps / deferred hardening (from reviews + demo)

1. MCO: hard-fail bootstrap render when BGP enabled but frr-k8s/kube-vip
   images missing (currently warn → empty image → opaque install death).
2. MCO: `isBGPVIPManagement` should require non-empty VIPs (UserManaged-LB +
   BGP combo currently renders `<no value>` into active manifests).
3. RBAC: node-bootstrapper can write any node's FRRNodeState/BGPSessionState —
   per-node scoping needs a CEL ValidatingAdmissionPolicy.
4. Dual-stack: singular VIP helpers drop the second family; CNO rawConfig is
   dual-stack-ready but untested; ToR config is v4-only.
5. installer: `BGPPeerConfig.port` is emitted but runtimecfg's FRRPeer drops
   it silently; communities/holdTime/keepaliveTime parsed by CNO but not
   rendered into sessions.
6. Day-2 peer changes: no ConfigMap informer (20-40min latency) and the
   MachineConfig file change reboots nodes — needs a NodeDisruptionPolicy or
   design statement.
7. kube-vip: EP-fidelity decision on leadership-gating the RT loop (see A2).
8. frr-status/metrics: metrics exporter dropped from static pods (no cert
   provisioning); needed for the TP observability criteria.
9. `openshift-kube-vip` namespace never created (mirror-pod noise only).
10. Strict L3 validation: demo used in-subnet VIPs (L2 ARP fallback masks BGP
    failures); run an off-subnet-VIP variant (needs DNS overrides in
    dev-scripts).
11. Failover/BFD/multi-rack (`hosts[].bgpPeers`) demo scenarios — plumbing
    exists, unexercised.
12. Flaky `TestOSBuildControllerLeavesSuccessfulBuildAlone` in MCO — pre-
    existing (verified at base), watch in CI.

## E. Tech Preview criteria (EP graduation) not started

- 5+ e2e tests `[OCPFeatureGate:BGPBasedVIPManagement]`, CI 7x/week (BGP peer
  simulation in CI — the ToR container pattern from this repo is the seed).
- Metrics + symptoms-based alerts for BGP session state.
- install-config documentation.
- Gate promotion DevPreviewNoUpgrade → TechPreviewNoUpgrade (implementation
  currently sits in DevPreview; EP says TechPreview).
