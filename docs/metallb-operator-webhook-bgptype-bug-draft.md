# Bug draft: metallb-operator — webhook server's `METALLB_BGP_TYPE` is static and ignores the `MetalLB` CR's `bgpBackend`

Target: github.com/metallb/metallb-operator issue (not yet filed).
Status: DRAFT — do not post without review.
Source: BGP VIP management CI work, ledger row coex-3
(mkowalski/bgp-vip-demo), found 2026-08-06 on a dual-stack OpenShift
cluster. Companion draft (same install path, different bug):
docs/metallb-operator-servicemonitors-bug-draft.md.

---

**Title:** Validation webhook rejects IPv6 resources in frr-k8s mode:
`METALLB_BGP_TYPE` on the webhook server is a static manifest value, not
reconciled from the `MetalLB` CR's `bgpBackend`

## What happened

With the operator installed from the deploy manifest
(`bin/metallb-operator.yaml`) and a `MetalLB` CR using
`bgpBackend: frr-k8s-external`, creating a `BGPAdvertisement` for a pool
containing an IPv6 range is rejected:

```
Error from server (Forbidden): error when creating "STDIN": admission webhook
"bgpadvertisementvalidationwebhook.metallb.io" denied the request: pool
"bgp-vip-lane-pool" has ipv6 CIDR fd2e:6f44:5dd8:c956::70/124, native bgp
mode does not support ipv6
```

The deployed BGP implementation is frr-k8s, which fully supports IPv6 —
the webhook is validating against the wrong mode. The cause: the
`metallb-operator-webhook-server` Deployment carries a **static**
`METALLB_BGP_TYPE=native` environment value from the manifest, and the
operator never reconciles it when the `MetalLB` CR selects a different
`bgpBackend`. The webhook's view of the BGP mode and the actually deployed
mode can permanently disagree.

## Reproduction

1. OpenShift cluster (reproduced on 5.0 nightlies; dual-stack, but the
   mismatch itself is stack-independent).
2. `oc apply -f bin/metallb-operator.yaml` (reproduced at upstream `main`
   @ `194f9719` and at `openshift/metallb-operator` `release-5.0`).
3. `oc apply` a `MetalLB` CR with `bgpBackend: frr-k8s-external` (or
   `frr-k8s`).
4. Create an `IPAddressPool` with an IPv6 range and a `BGPAdvertisement`
   selecting it.
5. The `BGPAdvertisement` is denied with "native bgp mode does not support
   ipv6", although the deployed mode is frr-k8s.
6. `oc get deploy -n metallb-system metallb-operator-webhook-server -o
   jsonpath='{.spec.template.spec.containers[0].env}'` shows
   `METALLB_BGP_TYPE=native` regardless of the CR.

## Workaround

```
oc set env deploy/metallb-operator-webhook-server -n metallb-system METALLB_BGP_TYPE=frr-k8s
```

After the webhook server re-rolls, the same IPv6 resources are accepted
and work end to end (validated: IPv6 LoadBalancer IP assigned, advertised
over BGP via the external frr-k8s instance, and reachable).

## Expected behavior

The webhook's BGP-type knowledge should follow the `MetalLB` CR: when the
operator reconciles a CR whose `bgpBackend` differs from the webhook
server's current `METALLB_BGP_TYPE`, it should update the env (or an
equivalent dynamic mechanism) so validation matches the deployed
implementation. Alternatively, if the webhook server is deliberately
CR-independent (it exists before any CR), the validation should not
hard-fail on mode-specific rules until the mode is actually known.

Note the ordering constraint that probably motivated the static value: the
webhook Deployment is created by the manifest, before any `MetalLB` CR
exists, so *some* default is unavoidable — but the default becoming
permanent is the bug.

## Environment

- Operator: metallb/metallb-operator `main` @
  `194f9719d9c0631a3d1a105165692e0aafbbedcb` (also reproduced with the
  `openshift/metallb-operator` fork at `release-5.0`); manifest-based
  install (`bin/metallb-operator.yaml`)
- Cluster: OpenShift 5.0 nightly-based, dual-stack (v4v6) bare metal IPI
  (dev-scripts), 3 masters + 2 workers
- MetalLB mode: `frr-k8s-external` against a pre-existing frr-k8s
  instance; the plain `frr-k8s` backend should reproduce identically
- OLM installs may avoid this if the CSV wires the env differently — the
  manifest path is what dev/CI environments exercise

---
This report was drafted with AI assistance. Please verify before posting.
