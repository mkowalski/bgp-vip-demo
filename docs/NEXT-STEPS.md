# Next Steps — productization handoff

What remains between "working dev demo" and Tech Preview per the enhancement's
graduation criteria. Ordered by dependency. Anyone picking this up: read
README.md → demo-results.md → RUN-LEDGER.md first; RUNBOOK.md to reproduce.

## Implementation plan (POC green as of run22)

State: the PoC is fully validated (22 clean installs; API+ingress VIPs over
BGP, worker routers, failover, metrics from every node). The trigger for the
next implementation wave is **openshift/api#2923 merging in its current
DevPreview form** (JSON blob on ControllerConfig — structured API agreed for
TechPreview, EP 066d3556).

### Phase 0 — now, nothing blocked (parallel)

1. Review-chase (updated 2026-07-29): CNO #3046 + #3047 (jcaamano),
   runtimecfg#395 (needs lgtm + `/verified`), openshift/release#81957
   (needs RE-lgtm after the conflict-fix force-push + rehearsal
   triage/ack), MCO #6326 + installer #10718 (human reviewers).
   DONE: api#2923 merged.
2. Post the drafted replies on the 8 open EP threads (see session notes;
   BGPVIPStatus one is answered by 6d527fe4) and fold the remaining A2
   items into the EP.
3. Open the second downstream openshift/kube-vip PR: 51e05fd (health check,
   upstream #1604 cherry-pick) + kubeconfig commits (until a rebase past
   upstream #1627).
4. Jira hygiene: target version 5.0.0 on OPNET-784 and OPNET-779/783.
5. DONE: MCO PR **OPENED: openshift/machine-config-operator#6326**
   (OPNET-782, 2026-07-22) from branch OPNET-595-mco-pr, 4 commits
   (vendor api via mkowalski fork pseudo-version pin — one-commit swap on
   api merge / template: render BGP static pods / operator: bootstrap +
   day-2 ingestion / install: image-references, held for ART-21663).
   First review round (CodeRabbit) fully addressed, notable outcomes
   folded into the series and live-validated on the run26 cluster:
   - securityContext hardening everywhere EXCEPT the frr container:
     `drop: ALL` + re-adds was tested live and breaks FRR's
     privilege-separated startup (watchfrr needs root-implicit
     SETUID/SETGID/DAC_OVERRIDE/CHOWN beyond the 4 network caps);
     reloader/frr-status kept `drop: ALL` but need `add: [DAC_OVERRIDE]`
     (vtysh as root against frr-user-owned vty sockets)
   - resource limits on every container, sized from live usage
     (frr-status idles at ~390m CPU — looks like a busy-poll, possible
     upstream frr-k8s issue worth filing separately)
   - `terminationGracePeriodSeconds` 0→10 (diverges from the upstream
     DaemonSet's 0 deliberately): SIGTERM'd bgpd sends Cease
     NOTIFICATION; after SIGKILL a graceful-restart *helper* peer
     retains stale VIP routes on bare TCP loss until the restart timer
   - real bug found by review: `VIP-COMMUNITY` route-map was defined but
     never attached to any neighbor — now attached per-AF in both FRR
     templates
   - `IsBGPVIPManagement` now also requires non-empty IngressIPs;
     bootstrap rejects a present-but-empty config.json (day-2 parity)
   - declined with rationale (recorded by the bot for future reviews):
     probes on frr/kube-vip, runAsNonRoot (caps not effective without
     file capabilities), bootstrap hostPath (emptyDir is 0777 by
     kubelet; the day-2 boot unit replicates exactly that)

### Phase 1 — once api#2923 merges (api MERGED 2026-07-24; mostly done)

Strategy shift executed 2026-07-24: standalone vendor-only PRs per repo so
the feature PRs carry zero vendoring —
MCO #6334 **MERGED**, CNO #3089 open (lgtm+approved), installer went via
the installer team's own 1.36 rebase #10713 **MERGED** (our stopgap #10710
closed as superseded).

1. DONE — installer PR **OPEN: #10718** (OPNET-781): 7 feature commits on
   post-rebase main, no vendoring; two bot review rounds addressed.
2. DONE — MCO PR #6326 slimmed to 2 commits (vendor commit collapsed after
   #6334; image-references commit withheld for the ART ordering as planned).
3. DONE 2026-07-30 — CNO typed-access swap on #3047: rebased onto
   post-#3089 master; isBGPVIPManagement now uses the generated
   FeatureGateBGPBasedVIPManagement and the typed
   PlatformStatus.BareMetal.VIPManagement from the bootstrap result (the
   dynamic Infrastructure GET is gone — one fewer live API call on the
   render path). Local gate constant removed; tests swapped to typed
   fixtures; full pkg suite green.
   DEFERRED to the next demo rebuild: the CNO dev branch
   (OPNET-595-bgp-vip-management-vendored) still carries the now-redundant
   DEMO-CARRY (#3070 merged) AND its local api vendor commit (master now
   vendors the api) — rebasing it conflicts in vendor/; refresh the whole
   branch in one pass when the demo stack is next rebuilt.

### Phase 2 — DevPreview complete in-payload

1. Nightly with the gate: install a DevPreviewNoUpgrade cluster from a real
   nightly (no custom payload) — the first end-to-end proof outside the PoC
   harness.
2. e2e enablement (OPNET-621/622/623): ToR-container pattern from
   dev-scripts#1929 into an openshift/release lane; 5+ gate-tagged tests
   (install, failover, dual-stack) per graduation criteria.
3. Known-gap burndown that doesn't need the TP API: dual-stack validation
   (D4), strict L3 / off-subnet VIPs (D10), BFD/multi-rack exercises (D11),
   CEL VAP for per-node state writes (D3).

### Phase 3 — TechPreview

1. Structured BGP API per EP: preferred Infra.spec.platformSpec.baremetal.bgp
   (fallback dedicated CRD) + passwordSecretRef (D15) + NodeDisruptionPolicy
   for peer-file changes (D6).
2. PrometheusRule alerts on the run22 metrics; optionally move frr-status to
   the companion (shrinks node-bootstrapper RBAC).
3. Gate DevPreviewNoUpgrade → TechPreviewNoUpgrade; CI 7x/week.

External tracks that land on their own clocks: FRR #22654 (fix branch
table-scoped-early-cleanup ready; upstream PR + RHEL-193997 scope extension),
kube-vip #1636 (removes the need for the FRR fix to be urgent), frr-k8s
#469/#470 (eventually deletes CNO's rawConfig).

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

PR 1982 predates the worker-ingress scope extension. DONE: BGPVIPStatus
dropped (6d527fe4, rationale kept inline). Still to incorporate:
ingress pod runs on ALL nodes via templates/common (keepalived parity), the
FRRConfiguration is cluster-wide (no node selector), the second zebra bug
(FRRouting/frr#22654, addr/route netlink batch race) + kube-vip level-triggered
re-assertion as mitigation, and the kube-vip restart kubeconfig/TLS gap (D13).

## B. Upstream contributions

| Where | What | Artifact |
|-------|------|----------|
| kube-vip | **MERGED upstream**: kube-vip/kube-vip#1627 (manager + backend honor the configured kubeconfig). NOTE: the RT-mode HTTP health check (51e05fd) is ALREADY upstream as kube-vip/kube-vip#1604 (fcd3eec) — drop that patch from the downstream fork on the next rebase. The 2 route re-assertion commits (6d51cbd level-triggered, 7d27248 realm toggle) are **PR OPEN downstream: openshift/kube-vip#6** (cherry-picks 9afbbb6 + 7df5a53, branch mkowalski:route-reassert) — **NO LONGER REQUIRED: the FRR table-scoped-cleanup fix alone is enough (proven run18, pre-workaround kube-vip + patched zebra)**; #6 is now optional robustness hardening, keep-or-close decision open; upstream re-assert **PR OPEN: kube-vip/kube-vip#1636** (branch upstream-route-reassert-2, single squashed commit on upstream main; maintainers pre-agreed to the mechanism). STILL TO OPEN downstream: second openshift/kube-vip PR with 51e05fd (HTTP health check, cherry-pick of upstream #1604 — missing from downstream main, based before its merge) + the kubeconfig commits 1731730/8cd17f7 |
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
   payload assembly breaks (unresolvable tag). Config DRAFTED:
   images/ose-kube-vip.yml on mkowalski/ocp-build-data branch ose-kube-vip
   (bfffc96a, openshift-5.0 base, modeled on baremetal-runtimecfg rhel9);
   ART Jira draft + onboarding checklist: docs/kube-vip-art-onboarding.md.
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
8. frr-status/metrics — RESOLVED (run21): masters-only companion DaemonSet
   validated on a clean install, full 5-node metric coverage in Prometheus.
   CNO folded into #3047 (45184c046, 4th commit) + MCO f1784cd7e (dev branch,
   goes into the MCO PR). Remaining optional: move frr-status to the companion (RBAC shrink),
   PrometheusRule alerts. Original notes:
   masters-only companion DaemonSet reads the static FRR via hostPath
   sockets, serves TLS with the serving cert, scraped by Prometheus —
   validated live. To productize: MCO template hostPath volumes (+tmpfiles.d
   perms), CNO companion manifest with dedicated Service/ServiceMonitor +
   PrometheusRule, then optionally move frr-status there too (shrinks the
   node-bootstrapper RBAC). Cheap alternative for the bare TP criterion:
   kube-state-metrics custom-resource-state config over BGPSessionState.
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
15. BGP peer password handling: the installer writes it into the
    bgp-vip-config ConfigMap and CNO copies it plaintext into the
    FRRConfiguration neighbor `password` field. frr-k8s supports
    `passwordSecret` (basic-auth Secret ref) — switch installer to emit a
    Secret + CNO to reference it (flagged by review on #3047; needs
    OPNET-781).
16. MCO/CNO worker-ingress changes: reflected in PR #3047 (CNO), but the MCO
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

### D8-followup. Metrics companion hardening — VALIDATED (run22)

Review round on #3047 hardened the companion (07be6312d): hostNetwork
removed (pod-network scrape), allowPrivilegeEscalation false,
readOnlyRootFilesystem, caps drop ALL (+DAC_OVERRIDE on frr-metrics only:
vtysh needs root but root does not own the frr-user sockets), seccomp
RuntimeDefault, tcpSocket probes. Run22 clean-install validated after two hot-caught fixes: the MCO boot
unit regained `chcon container_file_t` (losing hostNetwork loses spc_t ->
MCS confinement) and the companion gained a NetworkPolicy (namespace
default-deny never applied to hostNetwork pods; ingress 9141 from
monitoring + egress 443/6443 for TokenReview). All 7 frr targets up. Declined from the
review: CPU/memory limits (deliberate, matches the frr-k8s DS
requests-only convention), runAsNonRoot (vtysh requires root - run21),
SA token unmount (exporter TokenReviews its scrapers).

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
| OPNET-773 | enhancements | openshift/enhancements#1982 (first findings pass + TP BGPVIPConfig CRD design 59b32c7f; remaining second-pass items — see A2) |
| OPNET-780 | openshift/api | **MERGED: openshift/api#2923** (2026-07-24, merge commit 356624ff). JoelSpeed approved after the CEL-immutability test rewrite; the Keepalived→BGP transition question resolved on Slack: day-2 migration out of scope for now, field stays immutable-once-set. Agreed with MCO reviewer: JSON blob OK for DevPreview, structured BGP API for TechPreview (EP presents both placements, preference Infra.spec.platformSpec.baremetal.bgp, CRD as fallback if Infra should not grow — 066d3556) |
| OPNET-783 | cluster-network-operator | #3046 (statusmanager fix — prerequisite for compact/SNO, still needs jcaamano) + **#3047 (main BGP series; CodeRabbit round of 2026-07-23 fully addressed — communities now rendered with validation, exporter limits + IPv6 [::] bind, cp-metrics runAsNonRoot; hostOverrides/passwordSecret documented as DevPreview limitations; reviewDecision APPROVED by bot, awaiting jcaamano; typed-access swap pending #3089 merge)**. Vendor bump **#3089 MERGED** (2026-07-30; needed maintainer /override of four required jobs — e2e-aws-ovn-fdp-qe + the three ipsec jobs — which the cross-PR history showed 16/16 failing on every CNO PR for 3+ days, repo-wide breakage unrelated to the bump). **NEXT: rebase #3047 + typed-access swap now unblocked.** Upstream fix consumed: **#3070 MERGED** (OCPBUGS-99074, frr-k8s CRD asn int32/int64 on 1.36 apiservers; found in run23, our duplicate #3080 closed) — **drop the DEMO-CARRY from the dev branch on next rebase** |
| OPNET-785 | baremetal-runtimecfg | openshift/baremetal-runtimecfg#395 — has `approved`; tide still needs **lgtm + verified** labels (reviewer ping outstanding) |
| OPNET-787 | dev-scripts | **MERGED: openshift-metal3/dev-scripts#1929** (2026-07-27; cybertron lgtm, flaky metal-ipi jobs cleared on retest). Follow-up knob **PR OPEN: #1939** (BGP_VIP_MANAGEMENT — see OPNET-621 row) |
| OPNET-784 | kubevip | upstream: #1627 MERGED, re-assert **kube-vip/kube-vip#1636 OPEN**; downstream **openshift/kube-vip#6** (route re-assertion); second downstream PR (health check + kubeconfig) still to open |
| OPNET-779 | kubevip onboarding | ART Jira FILED: **ART-21663**; CI promotion **#81957 MERGED** (2026-07-30, re-lgtm + rehearsals-ack after the conflict fix) — kube-vip CI image build + ocp/5.0 promotion live; unblocks the private-org sync/branching and, downstream, the ART payload tag; ocp-build-data **PR OPEN: openshift-eng/ocp-build-data#11838** (retested 2026-07-30 after #81957 merged; previously ART checks failed — konflux delivery repo / ART-21663 ordering; also needs lgtm/approved/acknowledge-critical-fixes-only labels from ART); see docs/kube-vip-art-onboarding.md |
| OPNET-781 | installer | **PR OPEN: openshift/installer#10718** (opened 2026-07-28 after the 1.36 rebase #10713 merged; 7 feature commits, zero vendoring. Two CodeRabbit+Copilot rounds addressed: OVN-only validation, host nil-guard + override rejection, port/duration/community validation, 16-peer ceiling on overrides, typed VIPManagement constant, gosec nolint for the RFC 2385 password field; declines verified by the bots — Load() sibling pattern, password-in-ConfigMap DevPreview limitation. Presubmit CI green after gofmt/codegen fixes; awaiting human review). History: our stopgap vendor PR #10710 (api + k8s-0.35 pins) was superseded and closed in favor of the installer team's full 1.36 rebase **#10713 (MERGED)** which vendored api@18550f1a + bumped the lagging upi/libvirt/openstack CI Dockerfiles to go 1.26 |
| OPNET-782 | mco | **PR OPEN: openshift/machine-config-operator#6326** — now a clean 2-commit series (template + operator): the api vendor commit collapsed after the standalone vendor bump **#6334 MERGED** (2026-07-27; bot-held on a flaky upgrade job, triaged + unheld), and the obsolete ConfigMap Role/RoleBinding was dropped when the day-2 read moved to the cluster-wide lister. Commit messages + PR description rewritten to match (incl. the review-round hardening: frr drop-ALL exception, DAC_OVERRIDE, limits, grace 0→10, VIP-COMMUNITY attach, 0600 peers file, ingress-VIPs gate, bootstrap empty-config rejection). image-references commit still withheld pending OPNET-779/ART-21663. Awaiting human review (pablintino/eslutsky suggested) |
| OPNET-786 | FRR | downstream RPM backport filed: **RHEL-193997** (frr10, el9); upstream stable/10.4 backport request still pending; new zebra bug filed: **FRRouting/frr#22654 — CLOSED, fixed upstream** via FRRouting/frr#22676 (merged to master 2026-07; maintainer implemented from our root-cause pointer — our fork fix 8989c33 no longer needs submitting). NOT in any shipped release yet (10.7.0 predates it) — first release with #22676 (10.8 or a 10.7.x backport) removes the need for the kube-vip realm-toggle workaround; keep the workaround deployed until then. With 10.7 (SELECTED-flag fix) + a #22676-containing release, ALL our FRR needs are met by stock releases — if FDP ships recent FRR frequently, no downstream patches/backports needed (RHEL-193997 obsolete once FDP ≥10.7) |
| OPNET-778 | PoC | github.com/mkowalski/bgp-vip-demo (complete) |
| OPNET-621/622/623 | testing/CI | **STARTED 2026-07-30**: (a) dev-scripts one-click knob **PR OPEN: openshift-metal3/dev-scripts#1939** (`BGP_VIP_MANAGEMENT=true` renders bgpVIPConfig into the install-config; hard-fail validation without ENABLE_BGP_TOR or a DevPreview FEATURE_SET; render+guardrails validated on metal-u15; **full install validated 2026-07-31** — knob-deployed cluster passes the CI verify script verbatim, see RUN-LEDGER row 27); (b) CI lane **PR OPEN: openshift/release#82698** (`baremetalds-e2e-bgp-vip` workflow: install + `baremetalds-e2e-bgp-vip-verify` acceptance step — vipManagement=BGP, static pods/no keepalived, ToR path counts per VIP via vtysh, console 200; verify script validated verbatim against the live run26 cluster; optional on-demand presubmit `e2e-metal-ipi-bgp-vip` on openshift/installer, red-by-design until the feature PRs merge, `/pj-rehearse ack` posted). **First combined run executed 2026-08-04** via multi-PR testing (`/testwith openshift/installer/main/e2e-metal-ipi-bgp-vip` + MCO#6326 + CNO#3047 + runtimecfg#395, commented on installer#10718): all four PRs merged into one payload, the dev-scripts knob + guardrails executed in CI, the installer rendered bgpVIPConfig, and MCO selected the BGP path — failing exactly at the designed D1 fail-fast: `kube-vip ("") image is missing from the release payload` (frr-k8s resolved fine from the metallb-frr tag). Sole blocker for a green lane: the ocp/5.0 integration stream never received the kube-vip istag despite the successful 2026-07-29 promotion (quay push confirmed in the postsubmit log) — **DPTP question posted on release#81957**; once the tag materializes, restore MCO's image-references commit (kept ready as cherry-pick 6894c3065-equivalent) and rerun the /testwith. Note: CNO#3047 needed a rebase for the multi-PR merge (upstream added bootstrapResult/TLS plumbing to renderAdditionalRoutingCapabilities; merged signatures). Follow-ups once green: extend presubmit to MCO/CNO, conformance variant, dualstack variant, nightly periodic |
