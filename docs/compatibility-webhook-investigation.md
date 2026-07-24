# Investigation: compatibility-requirements webhook blocking all CRD writes (run15)

Date: 2026-07-21
Cluster: dev-scripts baremetal IPI (`ostest`, metal-u15), 3 masters + 2 workers
Payload: `5.0.0-0.bgpdemo` = nightly `5.0.0-0.nightly-2026-07-19-060131` base + 6 bgp-demo images
Kubernetes: v1.36.2, `FEATURE_SET=DevPreviewNoUpgrade`
Status: **root-caused (networking, not webhook code); workaround documented; bug filing guidance below**

## TL;DR

During run15 install, every CRD create/update cluster-wide failed for ~2 hours with:

```
Internal error occurred: failed calling webhook "compatibilityrequirement.operator.openshift.io":
failed to call webhook: Post "https://compatibility-requirements-controllers-webhook-service
.openshift-compatibility-requirements-operator.svc:443/validate-apiextensions-k8s-io-v1-
customresourcedefinition?timeout=10s": context deadline exceeded
```

This kept CNO Degraded (it re-applies its CRDs on every sync) and cascaded into a
stuck install. Initial hypothesis — a Content-Type/CBOR encoding mismatch between
the 1.36 apiserver and the webhook's old controller-runtime — was **disproven by
live-cluster experiments**. The real failure was **pod-network black-holing of the
webhook pods created early during install convergence**; recreating the pods fixed
it instantly and permanently. A one-off `contentType=` log line was a red herring
from an unidentified client. Secondary, still-valid issue: a DevPreview component
guarding *all* CRD writes with `failurePolicy: Fail` has cluster-wide blast radius
and no self-healing.

## Component identification

- The webhooks are served by the **compatibility-requirements-operator**, which
  ships from **`openshift/cluster-capi-operator`** (payload tag
  `cluster-capi-operator`), commit `f01957c81a9d3c47af65f699295990a1ca2a889f`.
- Binary: `cmd/crd-compatibility-checker`; deployment
  `compatibility-requirements-controllers` (2 replicas) in namespace
  `openshift-compatibility-requirements-operator`.
- Vendored stack at that commit: controller-runtime **v0.23.3**, k8s.io libs
  **v0.35.3** (also uses `openshift/controller-runtime-common`).
- Two `ValidatingWebhookConfiguration`s, both `failurePolicy: Fail`:
  - `...apiextensions-k8s-io-v1-customresourcedefinition-validation` — intercepts
    **all CRD create/update** cluster-wide
  - `...apiextensions-openshift-io-v1alpha1-compatibilityrequirement-validation`
- **Featureset-gated**: the component is only deployed with
  `DevPreviewNoUpgrade` (possibly also TechPreview — unverified). Default
  featureset clusters (e.g. the CNO BGP CI job
  `pull-ci-...-e2e-metal-ipi-ovn-dualstack-bgp` on PR #3017, payload
  `5.0.0-0.ci-2026-07-21-143618`) do not run it at all: no namespace, no webhook,
  all COs healthy there.

## Timeline of the incident (2026-07-21, UTC)

| Time | Event |
|---|---|
| ~10:30 | run15 masters up; cluster converging |
| 10:33 | `bgpsessionstates.frrk8s.metallb.io` CRD created successfully (webhook not yet blocking or not yet registered) |
| 10:34 | original `compatibility-requirements-controllers` pods start (masters 0/2 nets still settling) |
| 10:42 | network CO Degraded: CNO cannot re-apply `bgpsessionstates` CRD — webhook `context deadline exceeded` |
| 10:53 | controller pod itself logs `dial tcp 172.30.0.1:443: connect: connection refused` (pod → apiserver service VIP broken) |
| 12:10:30 | one and only `unable to process a request with unknown content type ... contentType=, expected application/json` log line (see "Red herring" below); manual `oc annotate crd` at the same moment still times out |
| ~12:30 | workaround applied: CVO override + scale operator/controllers to 0 + delete both VWCs |
| 12:32 | operator recovers, **recreates controller pods** |
| ≥12:32 | new pods: zero content-type errors; after webhook configs were later restored, CRD writes **succeed** — webhook fully functional without any code change |

Key observation: the failure was persistent for ~2h across *both* replicas (on
different masters), survived the cluster otherwise stabilizing, and was cured
solely by **pod recreation**.

## Experiments (run live on the cluster, 2026-07-21 ~17:40)

### Experiment 1 — direct POSTs to the real webhook pod (`https://<pod-ip>:9443/validate-...`)

Minimal `AdmissionReview` body, three header variants, from a master node:

| Request | Response |
|---|---|
| `Content-Type: application/json` | Instant `AdmissionReview` response (`"there is no content to decode"` for a null object — handler reached and parsing attempted; normal) |
| **no Content-Type header** | `{"message":"contentType=, expected application/json","code":400}` — **byte-identical to the incident log message** |
| `Content-Type: application/cbor` | `{"message":"contentType=application/cbor, expected application/json","code":400}` — *different* message |

Conclusions:
1. The incident's `contentType=` line was caused by a request with **no
   Content-Type header at all** — *not* CBOR.
2. All three variants get an **instant HTTP 200** (with an embedded 400 status).
   A content-type rejection therefore **cannot** produce the apiserver's
   10-second `context deadline exceeded`. The timed-out admission requests never
   reached the handler.

### Experiment 2 — capture of a genuine apiserver admission request

A throwaway TLS header-logging server (python, service-ca-issued cert, Service
`capture-webhook.default.svc`) registered via a tightly-scoped VWC
(`failurePolicy: Ignore`, `objectSelector: webhook-debug=true`, CRD UPDATE only).
Triggered with `oc annotate crd bgpsessionstates...`:

```
POST /capture?timeout=5s HTTP/1.1
Host: capture-webhook.default.svc:443
User-Agent: kube-apiserver-admission
Content-Length: 9708
Accept: application/json, */*
Content-Type: application/json
Accept-Encoding: gzip
body: {"kind":"AdmissionReview","apiVersion":"admission.k8s.io/v1"...
```

The k8s **1.36.2 apiserver sends plain JSON with a correct Content-Type**. No
CBOR, no missing header. (All capture artifacts were removed afterwards.)

### Corroborating source check

- controller-runtime v0.23.3 `pkg/webhook/admission/http.go:93` hard-requires
  `Content-Type: application/json`.
- controller-runtime **v0.24.1 has the identical check** — upstream has never
  added CBOR/alternate content types to the admission handler.
- Therefore [openshift/cluster-capi-operator#628] (OCPCLOUD-3607: bump to k8s
  1.36 / controller-runtime v0.24.1, open at time of writing) **does not change
  webhook request handling** — waiting for it would not have fixed anything
  (and, per the experiments, nothing needed fixing in that layer).

## Root cause (revised)

1. **Primary: pod-network black-holing.** The webhook pods created at 10:34
   (while OVN on the masters was still converging during install) ended up with
   permanently broken connectivity in *both* directions:
   - apiserver (host network) → pod 9443: connect/timeouts for every admission call
   - pod → `172.30.0.1:443` (apiserver service VIP): `connection refused`
   The pods stayed `Ready` because kubelet probes are node-local and do not
   exercise the failing paths. The state never self-healed; **recreating the
   pods (~12:32) fixed it immediately and permanently.** This points at
   OVN-Kubernetes (stale/unprogrammed flows for early-created pod sandboxes)
   rather than at the webhook component.

2. **Secondary (design): unbounded blast radius.** A DevPreview-gated component
   intercepts **every CRD create/update in the cluster** with
   `failurePolicy: Fail` and a 10s timeout. Any unavailability of its two pods
   (bugs, scheduling, networking, upgrades) instantly breaks every operator
   that applies CRDs — in our case CNO, wedging a fresh install. There is no
   circuit breaker, no self-healing, and the operator actively fights
   mitigation (it re-scales the controllers and recreates the VWCs; the
   controllers deployment itself reconciles `failurePolicy` back to `Fail`).

### Red herring: the `contentType=` log line

Logged exactly once (12:10:30) by the old pod:

```
E0721 12:10:30.881507 http.go:95] "unable to process a request with unknown content type"
err="contentType=, expected application/json" webhookGroup="apiextensions.k8s.io"
webhookKind="CustomResourceDefinition"
```

Experiment 1 shows this requires a POST with a body and **no Content-Type
header**, which the apiserver never sends (Experiment 2). Source unidentified
(some other client reached the pod while apiserver traffic was black-holed —
note the asymmetry itself is interesting: *something* got through). Do not
build a bug report on this line.

## Workaround (used in run15, needed on any DevPreviewNoUpgrade nightly until fixed)

Order matters — the operator recreates whatever you remove first:

```bash
# 1. stop CVO from repairing the operator
oc patch clusterversion version --type merge -p '{"spec":{"overrides":[{
  "kind":"Deployment","group":"apps",
  "name":"compatibility-requirements-operator",
  "namespace":"openshift-compatibility-requirements-operator",
  "unmanaged":true}]}}'
# 2. stop the operator (else it re-scales the controllers)
oc scale deploy -n openshift-compatibility-requirements-operator \
  compatibility-requirements-operator --replicas=0
# 3. stop the controllers (else they reconcile failurePolicy back to Fail)
oc scale deploy -n openshift-compatibility-requirements-operator \
  compatibility-requirements-controllers --replicas=0
# 4. remove the webhook configs
oc delete validatingwebhookconfiguration \
  openshift-compatibility-requirements-apiextensions-k8s-io-v1-customresourcedefinition-validation \
  openshift-compatibility-requirements-apiextensions-openshift-io-v1alpha1-compatibilityrequirement-validation
```

Given the revised root cause, a **lighter alternative** likely suffices:
`oc delete pod -n openshift-compatibility-requirements-operator -l <controllers>`
(pod recreation cured the connectivity). Keep the full workaround as fallback.

Verification either way: `oc annotate crd bgpsessionstates.frrk8s.metallb.io test=1 --overwrite && oc annotate crd bgpsessionstates.frrk8s.metallb.io test-`

## Filing guidance

Two separate reports:

1. **OVN-Kubernetes / networking (OCPBUGS, component Networking/ovn-kubernetes)**
   - Title: pods created during baremetal IPI install convergence can be left
     with permanently broken pod↔service connectivity; only pod recreation heals
   - Evidence: timeline above; both replicas on different masters affected for
     ~2h; node-local probes green throughout; `connection refused` to
     `172.30.0.1` from inside the pod; apiserver→pod:9443 timeouts; instant
     recovery after recreation at 12:32.
   - Repro conditions: dev-scripts baremetal IPI, `DevPreviewNoUpgrade`,
     5.0 nightly 2026-07-19; not seen on default-featureset CI (component absent).
   - Caveat to state: single occurrence; no packet capture of the broken era
     (pods were recreated by the mitigation); OVN flow dumps were not collected.

2. **cluster-capi-operator (OCPCLOUD) — hardening request**
   - Title: compatibility-requirements CRD webhook (`failurePolicy: Fail`, all
     CRD writes, DevPreview) turns any controller unavailability into
     cluster-wide CRD-write outage
   - Ask: `failurePolicy: Ignore` and/or `matchConditions`/scope reduction, plus
     reconsider the operator/controllers fighting manual mitigation. Reference
     the run15 incident as the motivating case.
   - Explicitly note: **not** an encoding bug; controller-runtime bump #628 is
     unrelated to this failure mode (verified against v0.24.1 source).

## Reference data

- Failing payload/env: `5.0.0-0.bgpdemo` (base `5.0.0-0.nightly-2026-07-19-060131`), k8s v1.36.2, DevPreviewNoUpgrade, dev-scripts on metal-u15
- Component image: `quay.io/openshift-release-dev/ocp-v5.0-art-dev@sha256:fd6dd5982859bdb5c06bb9b8bcc70b905ea8dd456020f61c143072ec795f2312`
  → `openshift/cluster-capi-operator@f01957c81a9d3c47af65f699295990a1ca2a889f`
- Nightly status at time of writing: latest Accepted `5.0.0-0.nightly-2026-07-20-081439`
  (capi-operator unchanged vs our base); `07-21-151215` (Ready) updates
  capi-operator but with nothing webhook-relevant.
- Related but distinct run15 issues (all resolved separately, see RUN-LEDGER):
  - frr-k8s CRD `asn` `format: int32` + `maximum: 4294967295` rejected by 1.36
    apiserver → fixed upstream by [openshift/cluster-network-operator#3070]
    (OCPBUGS-99074); our duplicate #3080 closed; DEMO-CARRY kept on the dev branch.
  - Unsigned nightly art-dev images vs sigstore-enforcing `policy.json` on
    workers (firstboot rebase + crio pause image, both `ocp-v4.0-art-dev` and
    `ocp-v5.0-art-dev` scopes) → live policy.json patch; MCD may revert.
  - Worker BMHs never registering after the degraded era → BMO restart.

[openshift/cluster-capi-operator#628]: https://github.com/openshift/cluster-capi-operator/pull/628
[openshift/cluster-network-operator#3070]: https://github.com/openshift/cluster-network-operator/pull/3070

---
*This document was written with AI assistance (Claude Fable 5). Please verify before acting on it.*
