# Next Steps — productization handoff

What remains between "working dev demo" and Tech Preview per the enhancement's
graduation criteria. Ordered by dependency. Anyone picking this up: read
README.md → demo-results.md → RUN-LEDGER.md first; RUNBOOK.md to reproduce.

## A. Enhancement text corrections (PR 1982) — DONE

Incorporated into PR 1982 (commit a52da909, pushed 2026-07-09): all seven
corrections below plus an Implementation Experience section. Kept for
reference:

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
| kube-vip | **PR OPEN** — https://github.com/kube-vip/kube-vip/pull/1627 (manager + backend honor the configured kubeconfig). NOTE: the RT-mode HTTP health check (51e05fd) is ALREADY upstream as kube-vip/kube-vip#1604 (fcd3eec) — drop that patch from the downstream fork on the next rebase. The 2 route re-assertion commits (6d51cbd level-triggered, 7d27248 realm toggle) are **PR OPEN downstream: openshift/kube-vip#6** (cherry-picks 9afbbb6 + 7df5a53, branch mkowalski:route-reassert); upstream kube-vip/kube-vip submission still to follow (needs rebase — upstream main has since reworked pkg/vip/address.go) |
| FRR (NEW bug) | File upstream: zebra loses an imported kernel-table route when the same-prefix connected address is processed in the same netlink batch (`lab/frr-lab-addr-route-race.sh` is the repro). Distinct from RHEL-193997; the kube-vip realm-toggle is a workaround, not a fix | lab/frr-lab-addr-route-race.sh |
| frr-k8s (metallb/frr-k8s) | Feature request: advertise redistributed/table-direct routes (CRD egress is bound to declared prefixes; our raw `-out` route-map permits couple to internal naming — fragile across bumps) | design note in CNO bgp_vip.go comments |
| FRR | upstream: b2c17ad52 backport request to stable/10.4 (pending); downstream: frr10 RPM backport **filed as RHEL-193997** | `patches/frr/0001-zebra-Do-not-clear-selected-flag-on-route-about-to-b.patch` |
| dev-scripts | **PR OPEN** — https://github.com/openshift-metal3/dev-scripts/pull/1929 (`ENABLE_BGP_TOR`, live-validated) | dev-scripts repo |

## C. Downstream productization

1. **frr10 RPM backport** (el9) of the zebra fix — **filed: RHEL-193997**
   ("frr10: (upstream backport request) routes pre-existing in kernel table
   are not redistributed", status New 2026-07-10) — the demo overlays the
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
13. kube-vip restart-on-live-cluster gap: `/etc/kubernetes/kubeconfig` on a
    settled cluster points at the node IP; the apiserver cert doesn't cover
    it → kube-vip-api blocks in "discover k8s version" forever and manages no
    routes after a restart. Needs the kubeconfig-honoring work (upstream PR
    #1627 area) or a TLS/server override.
14. The realm 1/2 values are visible in `ip route show table 198` output
    ("realm 2") — cosmetic; document or pick dedicated values before
    productization.
15. MCO/CNO worker-ingress changes: reflected in PR #3047 (CNO), but the MCO
    PR (pending, OPNET-782) must include the `templates/common/` move of
    0020-kube-vip-ingress.yaml (47948106d).

## E. Tech Preview criteria (EP graduation) not started

- 5+ e2e tests `[OCPFeatureGate:BGPBasedVIPManagement]`, CI 7x/week (BGP peer
  simulation in CI — the ToR container pattern from this repo is the seed).
- Metrics + symptoms-based alerts for BGP session state.
- install-config documentation.
- Gate promotion DevPreviewNoUpgrade → TechPreviewNoUpgrade (implementation
  currently sits in DevPreview; EP says TechPreview).

## Jira subtask mapping + PR tracker (OPNET-595 children)

| Subtask | Repo | PR |
|---|---|---|
| OPNET-773 | enhancements | openshift/enhancements#1982 (findings incorporated) |
| OPNET-780 | openshift/api | openshift/api#2923 (CI green) |
| OPNET-783 | cluster-network-operator | #3046 (statusmanager fix) + **#3047 (main BGP series — api-decoupled: local gate constant + unstructured vipManagement read, inert until the gate ships; typed-access follow-up after api merge)** |
| OPNET-785 | baremetal-runtimecfg | openshift/baremetal-runtimecfg#395 |
| OPNET-787 | dev-scripts | openshift-metal3/dev-scripts#1929 |
| OPNET-784 | kubevip | upstream kube-vip/kube-vip#1627; downstream **openshift/kube-vip#6** (route re-assertion, 6d51cbd + 7d27248) |
| OPNET-779 | kubevip onboarding | ocp-build-data / ART engagement pending |
| OPNET-781 | installer | pending api merge |
| OPNET-782 | mco | pending api merge + OPNET-779 |
| OPNET-786 | FRR | downstream RPM backport filed: **RHEL-193997** (frr10, el9); upstream stable/10.4 backport request still pending |
| OPNET-778 | PoC | github.com/mkowalski/bgp-vip-demo (complete) |
| OPNET-621/622/623 | testing/CI | not started |
