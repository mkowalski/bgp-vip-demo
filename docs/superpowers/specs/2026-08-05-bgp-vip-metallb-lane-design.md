# Design: `e2e-metal-ipi-bgp-vip-metallb` — day-2 MetalLB-BGP coexistence lane

Date: 2026-08-05
Status: approved (brainstorm 2026-08-05)
Target PR: openshift/release#82912 (added as a third job on the same branch)
Jira: OPNET-803 (same CI epic as the OVN-K coexistence lane)

## Goal

Prove the third BGP consumer from the EP coexistence story (fedepaol's
review comments 1/3 on enhancements#1982): a customer-like **day-2 MetalLB
operator install in BGP mode via the shared frr-k8s** on a cluster running
BGP-based VIP management. MetalLB becomes a FRRConfiguration producer whose
CRs must merge into the frr-k8s **static pods** on masters and — the
hardest case — into the **same ToR neighbor** already declared by the
`bgp-vip` FRRConfiguration.

## Decisions (from brainstorm)

| Question | Decision |
|---|---|
| MetalLB mode | BGP via frr-k8s (`BGP_TYPE=frr-k8s-cno` pattern), not L2 |
| Job shape | Separate third job; keeps VIP+OVN-K and VIP+MetalLB signals clean |
| Install source | OLM marketplace first (`packagemanifest metallb-operator` probe), fallback to upstream metallb-operator manifests pinned to the matching release branch. Never `metallb-native.yaml` (bypasses the operator, no frr-k8s mode) |
| External peer | Reuse the existing bgp-tor (192.168.111.1, AS 64513, dynamic listen range) — zero ToR changes, exercises same-neighbor merge |
| OLM subscribe code | Inlined in the pre step (ssh-to-host pattern), not the `operatorhub-subscribe-metallb-operator` ref (`from: cli` architecture mismatch with baremetalds steps) |
| Conformance/MetalLB e2e suite | Not in this lane (needs source-repo checkout machinery; would drown the coexistence signal) |

## Workflow

`ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/`
(`baremetalds-e2e-bgp-vip-metallb-workflow.yaml`):

```
env:  DEVSCRIPTS_CONFIG: IP_STACK=v4, NUM_WORKERS=2,
      ENABLE_BGP_TOR=true, BGP_VIP_MANAGEMENT=true
      FEATURE_SET: DevPreviewNoUpgrade
pre:  baremetalds-devscripts-conf-featureset
      chain baremetalds-ofcir-pre
      ref   baremetalds-e2e-bgp-vip-metallb-pre       (NEW)
test: ref   baremetalds-e2e-bgp-vip-verify            (existing, unchanged)
      ref   baremetalds-e2e-bgp-vip-metallb-verify    (NEW)
post: chain baremetalds-ofcir-post
```

Job: `e2e-metal-ipi-bgp-vip-metallb`, optional/on-demand presubmit on
openshift/installer main (same gating and red-by-design caveat as the
other two bgp-vip lanes).

## Pre step (`baremetalds-e2e-bgp-vip-metallb-pre`)

Runs on the hypervisor via ssh (`from: dev-scripts`, house pattern).

1. **OLM path**: if `oc get packagemanifest metallb-operator` resolves:
   namespace `metallb-system` (idempotent apply; label
   `openshift.io/cluster-monitoring: "true"`), OperatorGroup, Subscription
   (`channel: stable`, `source: redhat-operators`,
   `installPlanApproval: Automatic`), poll CSV `Succeeded` with a bounded
   deadline.
2. **Fallback path** (no packagemanifest, or CSV never succeeds within the
   deadline): deploy upstream metallb-operator manifests pinned to the
   release branch matching the cluster minor
   (`oc apply -k github.com/metallb/metallb-operator/config/default?ref=<branch>`
   or equivalent pinned manifest apply). Log loudly which path was taken.
3. **MetalLB CR** in frr-k8s mode targeting the existing
   `openshift-frr-k8s` instance (the frr-k8s-cno integration MetalLB's own
   lanes use). Exact CR fields (`bgpBackend`/external-frr-k8s knob) differ
   between operator versions — pinned during the metal-u15 dry run before
   any code is pushed.
4. **BGP objects**: `IPAddressPool` `192.168.111.30-192.168.111.50`
   (established baremetalds range, off DHCP/VIP allocations); `BGPPeer`
   peerAddress 192.168.111.1, peerASN 64513, myASN 64512;
   `BGPAdvertisement` selecting the pool.
5. **Workload**: agnhost `netexec` Deployment (2 replicas) +
   `Service type=LoadBalancer`.

Style requirements (lessons already reviewed into the sibling lane):
bounded deadlines on every wait, no unbounded `until` loops, idempotent
applies, container-runtime detection where podman is used, no secrets in
`set -x` output.

## Verify step (`baremetalds-e2e-bgp-vip-metallb-verify`)

All state checks poll with bounded deadlines; diagnostics dumped only on
timeout; `${CLI}` runtime detection.

1. `metallb-system` deployments Available; MetalLB-owned FRRConfigurations
   exist in `openshift-frr-k8s`.
2. **Same-neighbor merge, no session disruption**: the ToR has exactly one
   Established session per node (count == node count; merged neighbor must
   not duplicate or flap the pre-existing VIP sessions).
3. The LoadBalancer Service holds an IP from the pool; the ToR shows that
   `/32` with path count == number of frr-k8s-bearing nodes (5).
4. **Datapath**: curl the LB IP from the hypervisor with
   `--fail --show-error` (the host-net ToR's zebra installs learned routes
   into the host kernel, so the request traverses the BGP path).
5. VIP regression: covered by the preceding existing
   `baremetalds-e2e-bgp-vip-verify` ref — not duplicated here.

## Risks / open items

- **Catalog risk**: the released `stable` operator on a 5.0 nightly may
  not install or may lack the external frr-k8s handshake → fallback path;
  the first run decides which path the lane lives on.
- **MetalLB CR shape drift** upstream vs downstream for external frr-k8s —
  resolved empirically in the dry run.
- **Pool collisions**: `.30-.50` is the range existing lanes use; keep it.
- **Speaker behavior on masters**: MetalLB speaker pods run cluster-wide
  while masters' frr-k8s is a static pod; the FRRConfiguration merge path
  is identical to the proven OVN-K case (coex-1) but the producer differs.

## Validation sequence

1. **Dry run on metal-u15** (same method as ledger coex-1): day-2 MetalLB
   on the current coexistence cluster — on top of the live RA setup, giving
   a bonus 3-producer data point (bgp-vip + ovnk-generated + metallb).
   Pins the operator install path and MetalLB CR fields.
2. Write the two refs + workflow + installer config wiring; `make jobs`,
   `make ci-operator-checkconfig`, `make registry-metadata`, `bash -n`.
3. Re-run verify script against the dry-run cluster before pushing to the
   PR branch (openshift/release#82912).
4. Ledger row (`coex-2`) + NEXT-STEPS §E1 update in bgp-vip-demo.
