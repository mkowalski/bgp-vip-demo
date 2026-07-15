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

### A2. EP second findings pass — TODO

PR 1982 predates the worker-ingress scope extension. Still to incorporate:
ingress pod runs on ALL nodes via templates/common (keepalived parity), the
FRRConfiguration is cluster-wide (no node selector), the second zebra bug
(FRRouting/frr#22654, addr/route netlink batch race) + kube-vip level-triggered
re-assertion as mitigation, and the kube-vip restart kubeconfig/TLS gap (D13).

## B. Upstream contributions

| Where | What | Artifact |
|-------|------|----------|
| kube-vip | **PR OPEN** — https://github.com/kube-vip/kube-vip/pull/1627 (manager + backend honor the configured kubeconfig). NOTE: the RT-mode HTTP health check (51e05fd) is ALREADY upstream as kube-vip/kube-vip#1604 (fcd3eec) — drop that patch from the downstream fork on the next rebase. The 2 route re-assertion commits (6d51cbd level-triggered, 7d27248 realm toggle) are **PR OPEN downstream: openshift/kube-vip#6** (cherry-picks 9afbbb6 + 7df5a53, branch mkowalski:route-reassert) — **NO LONGER REQUIRED: the FRR table-scoped-cleanup fix alone is enough (proven run18, pre-workaround kube-vip + patched zebra)**; #6 is now optional robustness hardening, keep-or-close decision open; upstream kube-vip submission moot unless kept. STILL TO OPEN downstream: second openshift/kube-vip PR with 51e05fd (HTTP health check, cherry-pick of upstream #1604 — missing from downstream main, based before its merge) + the kubeconfig commits 1731730/8cd17f7 |
| frr-k8s (metallb/frr-k8s) | Feature request: advertise redistributed/table-direct routes (CRD egress is bound to declared prefixes; our raw `-out` route-map permits couple to internal naming — fragile across bumps) | **FILED: https://github.com/metallb/frr-k8s/issues/469**; design doc **PR OPEN: https://github.com/metallb/frr-k8s/pull/470**, AI-review rounds done (f40ce42), awaiting maintainer review (ref copies: docs/frr-k8s-feature-request-draft.md, docs/frr-k8s-redistribute-design-draft.md); implementation offer stands; also design note in CNO bgp_vip.go comments |
| FRR | upstream: b2c17ad52 backport request to stable/10.4 (pending); NEW zebra bug (addr/route same-batch race) **FILED: https://github.com/FRRouting/frr/issues/22654** — **root cause FIXED**: branch `table-scoped-early-cleanup` on mkowalski/frr (8989c33); upstream PR against FRRouting/frr referencing #22654 STILL TO SUBMIT (fix forward-ports: master needs the same table check; master already has the vrf scoping + the debug-path UAF fix); downstream: frr10 RPM backport **filed as RHEL-193997** | `patches/frr/0001-zebra-Do-not-clear-selected-flag-on-route-about-to-b.patch`, `patches/frr/0002-zebra-scope-early-route-queue-cleanup-to-the-matchin.patch`, `lab/frr-lab-addr-route-race.sh` |
| dev-scripts | **PR OPEN** — https://github.com/openshift-metal3/dev-scripts/pull/1929 (`ENABLE_BGP_TOR`, live-validated) | dev-scripts repo |

## C. Downstream productization

1. **frr10 RPM backport** (el9) of the zebra fixes — **filed: RHEL-193997**
   ("frr10: (upstream backport request) routes pre-existing in kernel table
   are not redistributed", status New 2026-07-10) — the demo overlays the
   binary in the image; production needs the RPM (or ose-frr image carry).
   NOTE: production now needs BOTH zebra patches in the RPM (SELECTED flag
   b2c17ad52 + table-scoped early cleanup 8989c33); the second needs its own
   RHEL bug or an addition to RHEL-193997's scope.
   Owner: whoever owns the frr10 package + ART.
2. **ocp-build-data**: add `kube-vip` payload member (ose-kube-vip image from
   the fork) BEFORE MCO's image-references change merges — otherwise nightly
   payload assembly breaks (unresolvable tag).
3. **PR strategy per repo** (all branches carry demo shortcuts to unwind):
   - openshift/api: DONE — #2923 is 2 clean commits, rebased onto master
     2026-07-14 with regen folded per commit; awaiting api-approver review.
   - installer: rebase `-vendored` onto the clean branch; re-vendor from the
     merged api instead of local content.
   - **MCO: go.mod has a LOCAL-PATH replace for openshift/api** (dev-only) —
     must be swapped to the merged api version. `-dev` branch also carries the
     old "hardcode kube-vip image" commit history; rebase/squash the -dev/
     -vendored layering into a clean PR series. Must include the
     `templates/common/` move of 0020-kube-vip-ingress.yaml (47948106d) and
     should fold in hardening gaps D1/D2.
   - CNO: DONE for the gate-decoupled part — #3047 is a clean 3-commit series
     (render incl. cluster-wide CR, DaemonSet placement, RBAC). Remaining:
     re-vendor + switch to typed VIPManagement access after api merges.
   - kube-vip: route re-assertion split out as openshift/kube-vip#6 — NO
     LONGER REQUIRED (FRR fix alone is enough, run18); optional hardening,
     keep-or-close open. Remaining: second downstream PR (health check +
     kubeconfig, see B).
   - baremetal-runtimecfg: DONE — #395 carries 3 commits, label-node dropped.
4. **CNO status-manager fix** (desired==0 DaemonSets) — DONE: extracted as
   #3046, BGP-independent, mergeable on its own.

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
11. BFD/multi-rack (`hosts[].bgpPeers`) demo scenarios — plumbing exists,
    unexercised. (Failover WAS exercised in run17: withdraw ~50s on router
    loss, restore ≤20s; note a plain router-pod delete does not withdraw —
    the replacement outraces the health threshold.)
12. Flaky `TestOSBuildControllerLeavesSuccessfulBuildAlone` in MCO — pre-
    existing (verified at base), watch in CI.
13. kube-vip restart-on-live-cluster gap: `/etc/kubernetes/kubeconfig` on a
    settled cluster points at the node IP; the apiserver cert doesn't cover
    it → kube-vip-api blocks in "discover k8s version" forever and manages no
    routes after a restart. Needs the kubeconfig-honoring work (upstream PR
    #1627 area) or a TLS/server override.
14. The realm 1/2 values are visible in `ip route show table 198` output
    ("realm 2") — cosmetic; document or pick dedicated values before
    productization. NOW MOOT if openshift/kube-vip#6 is dropped (the realm
    toggle is no longer required — FRR fix alone is enough, run18); only
    relevant if #6 is kept as defense-in-depth.
15. MCO/CNO worker-ingress changes: reflected in PR #3047 (CNO), but the MCO
    PR (pending, OPNET-782) must include the `templates/common/` move of
    0020-kube-vip-ingress.yaml (47948106d).

### D2. import-table is unnecessary — RESOLVED (run20, 2026-07-15)

FRR docs (10.5, `redistribute table-direct`) and lab tests (stock 10.4.3 +
fixed zebra; pre-existing and live routes; table 6553) show `table-direct`
reads the kernel table directly — `ip import-table` is NOT needed and table
ids up to 65535 work. The run5-era "zebra needs import-table" conclusion was
an artifact of debugging before the deny-any and zebra bugs were isolated.
Resolution (run20):
- CNO: dropped from buildBGPVIPRawConfig — dev 55c0da0fb, folded into #3047
  (865d35827). Also removes the distance-15 main-RIB copy side effect.
- MCO: never carried it (frr.conf.tmpl and frr-k8s-conf.yaml only have
  redistribute table-direct) — the earlier note claiming otherwise was wrong.
- Cluster-revalidated: run20 all green, no import-table anywhere, no main-RIB
  pollution.
- FRRouting/frr#22654 repro is unaffected (the early-queue drop happens
  before any import), but the issue text mentions import-table — harmless.

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
| OPNET-773 | enhancements | openshift/enhancements#1982 (first findings pass in; second pass pending — see A2) |
| OPNET-780 | openshift/api | openshift/api#2923 (rebased+regen 2026-07-14, awaiting api-approver review) |
| OPNET-783 | cluster-network-operator | #3046 (statusmanager fix) + **#3047 (main BGP series — api-decoupled: local gate constant + unstructured vipManagement read, inert until the gate ships; typed-access follow-up after api merge)** |
| OPNET-785 | baremetal-runtimecfg | openshift/baremetal-runtimecfg#395 |
| OPNET-787 | dev-scripts | openshift-metal3/dev-scripts#1929 |
| OPNET-784 | kubevip | upstream kube-vip/kube-vip#1627; downstream **openshift/kube-vip#6** (route re-assertion); second downstream PR (health check + kubeconfig) still to open |
| OPNET-779 | kubevip onboarding | ocp-build-data / ART engagement pending |
| OPNET-781 | installer | pending api merge |
| OPNET-782 | mco | pending api merge + OPNET-779 |
| OPNET-786 | FRR | downstream RPM backport filed: **RHEL-193997** (frr10, el9); upstream stable/10.4 backport request still pending; new zebra bug filed: **FRRouting/frr#22654** — root cause fixed (mkowalski/frr 8989c33, `table-scoped-early-cleanup`), upstream PR still to submit |
| OPNET-778 | PoC | github.com/mkowalski/bgp-vip-demo (complete) |
| OPNET-621/622/623 | testing/CI | not started |
