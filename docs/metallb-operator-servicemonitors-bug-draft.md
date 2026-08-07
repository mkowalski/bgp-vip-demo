# Bug draft: metallb-operator — controller/speaker deadlock on missing cert secrets when `DEPLOY_SERVICEMONITORS` is unset (OpenShift)

Target: github.com/metallb/metallb-operator issue (not yet filed).
Status: DRAFT — do not post without review.
Source: BGP VIP management CI work, ledger rows coex-2/coex-3
(mkowalski/bgp-vip-demo), reproduced 2026-08-05 and again on a second
cluster 2026-08-06.

---

**Title:** OpenShift: controller/speaker pods deadlock on missing
`controller-certs-secret`/`speaker-certs-secret` unless
`DEPLOY_SERVICEMONITORS=true`

## What happened

On an OpenShift cluster with the operator installed from the deploy
manifest (`bin/metallb-operator.yaml`), creating a `MetalLB` CR renders a
`controller` Deployment and `speaker` DaemonSet whose pod specs mount
`controller-certs-secret` / `speaker-certs-secret`. Those secrets are
created by OpenShift's service-CA from the
`service.beta.openshift.io/serving-cert-secret-name` annotation on the
`controller-monitor-service` / `speaker-monitor-service` Services — but the
operator only renders those Services when the `DEPLOY_SERVICEMONITORS`
environment variable is set to `true` on
`metallb-operator-controller-manager`.

With the env unset (the manifest default), the workloads reference secrets
that nothing ever creates: every controller and speaker pod is stuck in
`ContainerCreating` with `FailedMount` on the certs secrets, forever. The
MetalLB CR never becomes Available.

## Reproduction

1. OpenShift cluster (reproduced on 5.0 nightlies; the rendering logic is
   version-independent).
2. `oc apply -f bin/metallb-operator.yaml` (reproduced at upstream `main`
   @ `194f9719` and at `openshift/metallb-operator` `release-5.0`).
3. `oc apply` a minimal `MetalLB` CR (any `bgpBackend`).
4. `oc get pods -n metallb-system`: controller/speaker pods stuck in
   `ContainerCreating`; events show `FailedMount` for
   `controller-certs-secret` / `speaker-certs-secret`;
   `oc get svc -n metallb-system` shows no monitor Services.

## Workaround

```
oc set env deploy/metallb-operator-controller-manager -n metallb-system DEPLOY_SERVICEMONITORS=true
```

After the operator re-reconciles: the serving-cert-annotated monitor
Services render, service-CA populates the secrets (~15 s), controller and
speaker start normally.

## Expected behavior

One of:

- the certs-secret volumes/mounts on controller/speaker are rendered under
  the same condition as the monitor Services that feed them (i.e. also
  gated on `DEPLOY_SERVICEMONITORS`), or
- the monitor Services (and thus the secrets) are always rendered on
  OpenShift, or
- the mismatch is validated and surfaced as a degraded condition on the
  `MetalLB` CR instead of a silent `FailedMount` deadlock.

The asymmetry — consumers of the secrets unconditional, producers of the
secrets conditional — looks unintentional. Confirmed in the operator
source at the reproduced SHAs: the deployment/daemonset templates mount
the secrets unconditionally while the Service rendering is guarded by
`DEPLOY_SERVICEMONITORS`.

## Environment

- Operator: metallb/metallb-operator `main` @ `194f9719d9c0631a3d1a105165692e0aafbbedcb`
  (also reproduced with the `openshift/metallb-operator` fork at
  `release-5.0`); manifest-based install (`bin/metallb-operator.yaml`)
- Cluster: OpenShift 5.0 nightly-based, bare metal IPI (dev-scripts),
  3 masters + 2 workers; also a second identically-shaped cluster
- Not applicable to OLM installs whose CSV sets the env (which may be why
  this survives: the manifest path is presumably only exercised in dev/CI)

## Related issue (filed separately)

The same manifest install path has a second, independent bug: the webhook
server's `METALLB_BGP_TYPE` is a static manifest value never reconciled
from the `MetalLB` CR's `bgpBackend`, so validation rejects IPv6 resources
in frr-k8s mode. See
docs/metallb-operator-webhook-bgptype-bug-draft.md (cross-reference the
issue numbers when filing).

---
This report was drafted with AI assistance. Please verify before posting.
