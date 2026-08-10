# Bug draft: frr-k8s — validation webhook rejects merged neighbors that mix `passwordSecret` and inline `password`, even when the actual passwords match

Status: **FILED as https://github.com/metallb/frr-k8s/issues/484** (2026-08-10). Kept for reference.
Source: BGP VIP management structured-API work, ledger row api-2
(mkowalski/bgp-vip-demo), found 2026-08-10 on a live OpenShift dual-stack
cluster; root cause confirmed against frr-k8s source.

---

**Title:** Validation webhook blanks `passwordSecret` before merge
validation, making "secret-ref + inline password" for a shared neighbor
permanently rejected — even when both resolve to the same password

## What happened

Two `FRRConfiguration` producers on one cluster declare the **same BGP
neighbor** (a merge case frr-k8s explicitly supports):

- producer A (an operator following the `passwordSecret` API) sets
  `neighbor.passwordSecret: {name: ..., namespace: <frr-k8s ns>}`
- producer B (MetalLB) sets the **inline** `neighbor.password` — which is
  the only form MetalLB's operator ever emits: it resolves its own
  `BGPPeer` secrets to inline passwords in the generated
  `FRRConfiguration`

Both reference the **same actual password**. Every subsequent
`FRRConfiguration` write in the cluster is then denied:

```
admission webhook "frrconfigurationsvalidationwebhook.metallb.io" denied
the request: multiple passwords specified for 192.168.111.1
```

Because the webhook validates the merged set of *all* configurations,
this wedges every producer on the cluster (MetalLB speakers log the same
denial in a loop), not just the offending pair. There is **no
configuration escape**: switching MetalLB's `BGPPeer` to `passwordSecret`
does not help, since MetalLB still inlines the resolved value into its
generated `FRRConfiguration`.

## Root cause (confirmed in source)

`internal/controller/validate.go` — the webhook cannot resolve secrets, so
it blanks every reference before running the merge check:

```go
resetSecrets(clusterResources.FRRConfigs)   // validate.go:32
...
func resetSecrets(cfgs []v1beta1.FRRConfiguration) {
    ...
    r.Neighbors[i].PasswordSecret = v1beta1.SecretReference{}
```

`internal/controller/merge.go:283` then requires strict equality of the
(post-reset) password strings for a shared neighbor:

```go
if n1.Password != n2.Password {
    return fmt.Errorf("multiple passwords specified for %s", neighborKey)
}
```

So a secret-ref neighbor validates as password `""` against the other
producer's inline `"<password>"` → guaranteed mismatch, regardless of the
actual secret contents. The two supported forms of expressing the same
password are mutually incompatible **at the webhook layer only**; the
controller-side merge (which resolves secrets) compares real values and
behaves correctly.

## Reproduction

1. Cluster with frr-k8s and two `FRRConfiguration` producers sharing a
   neighbor (e.g. MetalLB in frr-k8s mode plus any other
   `FRRConfiguration` for the same peer — reproduced with frr-k8s as
   deployed by OpenShift 5.0 nightlies, but the code path is upstream and
   version-independent).
2. Configuration 1: neighbor X with
   `passwordSecret: {name: my-secret, namespace: <frr-k8s ns>}` (secret
   exists, `kubernetes.io/basic-auth`, password key).
3. Configuration 2 (or MetalLB `BGPPeer` with a password — inlined by the
   MetalLB operator): same neighbor X with `password: <same value>`.
4. Whichever is applied second is denied with
   `multiple passwords specified for X`; from then on **every**
   `FRRConfiguration` create/update in the cluster is denied while both
   objects exist.

## Expected behavior

Mixing representations for a shared neighbor should be validatable. Two
possible fixes, not mutually exclusive:

- **Webhook**: instead of blanking secret refs, record that a neighbor's
  password came from a secret and skip (or soften) the password-equality
  check when either side used a reference — deferring the real value
  comparison to the controller, which resolves secrets and already
  performs the authoritative merge. A conservative variant: only skip the
  check when exactly one side is a reference; two references can still be
  compared by (namespace, name).
- **Controller**: already correct — it compares resolved values, so a
  genuine mismatch still fails at reconcile with a clear per-node status.

## Impact

Any operator that adopts the `passwordSecret` API (its documented,
preferred form — inline passwords in CRs are the thing `passwordSecret`
exists to avoid) becomes incompatible with MetalLB on the same neighbor
the moment the peer requires authentication. That forces integrators back
to inline passwords in generated configurations, defeating the field's
purpose.

## Environment

- frr-k8s as shipped in OpenShift 5.0 nightlies (CNO-deployed DaemonSet +
  static pod variant); root cause verified against current upstream
  `internal/controller/validate.go` / `merge.go`
- Producers: cluster-network-operator (BGP VIP management, secret-ref
  form) + MetalLB operator in frr-k8s mode (inline form)

Happy to submit a PR for the webhook fix.

---
This report was drafted with AI assistance. Please verify before posting.
