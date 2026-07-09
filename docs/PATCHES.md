# BGP VIP Management — Complete Patch Inventory

Every change needed to make enhancement 1982 (BGP-based VIP management) work
end to end, as proven by the dev demo. Grouped by repository, in dependency
order. Status: all on local branches; PR splitting/vendor-commit cleanup
pending.

## 1. openshift/api — branch `OPNET-595-bgp-vip-management`

| Commit | What | Why |
|--------|------|-----|
| a7e2b9c7b (pre-session) | `BGPBasedVIPManagement` feature gate (DevPreviewNoUpgrade); `BareMetalPlatformStatus.VIPManagement` field | Gate + install-time signal on the Infrastructure CR |
| ad8da98b9 | `ControllerConfigSpec.BGPVIPPeersJSON` (+regen) | Carries the peer-config JSON through MCO to the node peer file |
| 2d1992b69 | MinLength/MaxLength on the field + openapi refresh | kube-api-linter compliance |

Ship note: the `cluster-config-api` payload image is built from this repo —
the CRD schema + featuregate manifests MUST land here first or
`vipManagement` gets pruned from the live Infrastructure CR and the gate is
unknown cluster-wide (proven in run6).

## 2. openshift/installer — branch `OPNET-595-bgp-vip-management(-vendored)`

| Commit | What | Why |
|--------|------|-----|
| (pre-session x4) | `BGPVIPConfig`/`BGPPeerConfig` types, validation, feature gate wiring, Infrastructure `VIPManagement=BGP`, `bgp-vip-config` ConfigMap asset | install-config API + config handoff |
| bc43c457ed | ConfigMap schema aligned to runtimecfg `FRRPeerMapping` (`defaultPeers`, flat `hostOverrides`) | One schema end to end; frr-peers.json == config.json |
| 91ad587234 | `additionalRoutingCapabilities.providers=[FRR]` on the operator Network CR when bgpVIPConfig set | CNO deploys frr-k8s CRDs/namespace; without it CNO degrades forever |
| 9dea799e48 | Negative test (no bgpVIPConfig → no CR) | Regression guard for every existing baremetal install |

## 3. openshift/machine-config-operator — branch `OPNET-595-bgp-vip-management-dev`

| Commit | What | Why |
|--------|------|-----|
| (pre-session x10) | BGP mode detection (`isBGPVIPManagement`), keepalived disable, static pod manifests + templates, startup ordering, image constants | Core MCO scaffolding |
| 7f9470e83 | vendor api (BGPVIPPeersJSON) | — |
| 2e5240b15 | Guard singular VIP helpers (all on-prem platforms) | VIP-less configs crashed all MC rendering |
| c0e4d5562 | Peer-data pipeline: bootstrap file dep (`--bgp-vip-config-file`), day-2 operator ConfigMap sync, template fixes (`.ControllerConfig` contexts, real `BGPVIPPeersJSON` rendering), operator-side helper guards, RBAC | THE data path; previously `frr-peers.json` had no data source at all |
| e7f3eb426 | Degrade on ConfigMap loss, `json.Compact` validation both paths, `inline: \|-`, RBAC narrowed | ConfigMap deletion would have blanked peers fleet-wide + rebooted all nodes |
| ec43198cf | Reject empty config.json payload on BGP clusters | Same failure class |
| 56cb9e404 | Image resolution: `metallb-frr` + new `kube-vip` payload tags end to end (flags, image-references, images ConfigMap, structs, maps) | Un-hardcodes the dev pullspec; bootstrap + day-2 |
| 919929855 | Bootstrap frr-k8s pod → FRR-only (no controller/status/metrics/label-node) | No Node object / no CRDs / no certs during bootstrap; label-node deadlocked init |
| c7ff25af2 | Day-2 pods master-only; controller+frr-status kubeconfig; drop metrics exporter; ingress kube-vip gated active | Workers must not run API VIP election; CRD handover needs API access |
| fd072b1a0 | kube-vip `manager` arg; runtimecfg `--cluster-config` for bootstrap render | First live-install findings: usage-text crashloop; kubeconfig parse panic |
| c1bf266e1 | `k8s_config_file` env on kube-vip pods | Static pods have no in-cluster config |
| 5b311c8ee | `kubernetes_addr=https://localhost:6443` | Leader election must not depend on the VIP it manages (teardown deadlock) |
| bd240b8c6 | Drop label-node init container | NodeRestriction denies node-credential labels; superseded by role-based anti-affinity |
| d6b2df182 | `--pod-name=frr-k8s-$(NODE_NAME)` for frr-status | Static pods must name their mirror pod; exporter fatals otherwise |
| 29e4f8042 | Ingress gate endpoint :29445 → :1936/healthz | 29445 is the API haproxy monitor; 1936 is the router health keepalived's chk_ingress uses. EP doc needs the same correction |

## 4. openshift/cluster-network-operator — branch `OPNET-595-bgp-vip-management-vendored`

| Commit | What | Why |
|--------|------|-----|
| (pre-session x2) | FRRConfiguration rendering from ConfigMap; DaemonSet anti-affinity | Core CNO scaffolding |
| c5e363607 | Typed VIPManagement (bootstrapResult), feature-gate check, `defaultPeers` schema | Drop unstructured live GET; gate discipline |
| bcb76bbaf | `ebgpMultiHop` string contract fix; int64 in unstructured (deep-copy panic); full-fields test fixture | Producer/consumer contract breaks found by review |
| 39e5182f7 | Static pod RBAC bindata (initial) | Controller/frr-status need CR access |
| a62d892c0 | Router-level `prefixes` (webhook); role-based DaemonSet anti-affinity under BGP mode | Webhook denial; label race + NodeRestriction made label approach unworkable |
| 07a24912c | RBAC subject → `openshift-machine-config-operator/node-bootstrapper` SA; +`frrk8sconfigurations` | Live identity verified via `oc auth whoami` — NOT system:nodes |
| 0a4579155 | Namespace-scoped secrets/pods reads (mirror DaemonSet SA) | Informer cache sync (BGP passwords) |
| c04ab0abb | Status manager: desired==0 DaemonSet (observed generation) is rolled out, not hung | Compact clusters: frr-k8s DS legitimately schedules zero pods; blocked co/network |
| 9222d8407 | **Advertise via gated redistribution, not CRD prefixes** (rawConfig route-maps/prefix-lists) | CRD prefixes render as unconditional network statements → health gating destroyed → ECMP to dead apiservers |
| ecb5282fe | `toAdvertise.allowed.mode: all` per neighbor | frr-k8s renders deny-all egress maps without it; redistribute is the ingress filter |
| 93e48830e | `ip import-table 198` first line of rawConfig | zebra only tracks non-main tables when instructed |
| be5b5ae9a | Drop toAdvertise; raw high-seq permits into frr-k8s's generated `<peer>-out` route-maps | frr-k8s mode:all egress is bound to DECLARED router prefixes (deny-any otherwise); CRD cannot express advertising redistributed routes. Fall-through permits open exactly the VIP prefix-lists. Upstream frr-k8s feature request candidate |

## 5. kube-vip (downstream fork) — branch `OPNET-595-bgp-vip-management`

| Commit | What | Why |
|--------|------|-----|
| 51e05fd (pre-session) | HTTP health check in routing-table mode | Ingress VIP gating on haproxy |
| 3518dd2 / 7a6c161 / 9531dd0 | Dockerfile.openshift + go directive + Makefile CI fixes (cherry-picked from side branch) | Downstream build |
| 173173011 | manager honors `k8sConfigPath`/`k8s_config_file` (+`kubernetes_addr` endpoint override) | Upstream hardcodes admin.conf/~/.kube/in-cluster — none exist for OpenShift static pods |
| 8cd17f786 | backend health checks honor the configured kubeconfig | Same gap in `Entry.Check()` — RT-mode gate could never pass |

Upstreamable: both kubeconfig commits are generic fixes.

## 6. openshift/baremetal-runtimecfg — branch `OPNET-595-bgp-vip-management`

| Commit | What | Why |
|--------|------|-----|
| (pre-session x4) | `render --peer-file` (FRRPeerMapping resolution by hostname), isIPv4/isIPv6 template funcs, label-node cmd | Per-node frr.conf rendering. NOTE: `label-node` is now unused (NodeRestriction) — candidate for removal |

## 7. FRR (upstream backport) — `bgp-vip-demo/frr-zebra-import-table-selected.patch`

| Patch | What | Why |
|-------|------|-----|
| FRRouting/frr `b2c17ad52` backported to 10.4.3 | zebra: do not clear SELECTED on routes being imported (`zebra_add_import_table_entry` mutated source route flags) | **Any route present in table 198 before `ip import-table`/`redistribute table-direct` config lands is never redistributed** (and the import scan de-selects previously selected routes). Bootstrap always worked (kube-vip writes after FRR starts); masters broke at CRD handover (route predates config). Reproduced + verified fixed in an isolated container lab (4-case matrix), exact payload image. Fixed upstream in 10.7.0-rc1; needs downstream frr10 RPM backport (el9) or ose-frr image-level carry |

Demo delivery: overlay image `quay.io/mkowalski/metallb-frr:bgp-demo`
(payload-image + patched zebra binary). Production path: backport into the
`frr10` RPM (RHEL 9) or the ART ose-frr build.

## Payload assembly (demo)

```
oc adm release new --from-release <5.0 nightly> \
  machine-config-operator=quay.io/mkowalski/machine-config-operator:bgp-demo \
  cluster-network-operator=quay.io/mkowalski/cluster-network-operator:bgp-demo \
  baremetal-runtimecfg=quay.io/mkowalski/baremetal-runtimecfg:bgp-demo \
  kube-vip=quay.io/mkowalski/kube-vip:bgp-demo \
  cluster-config-api=quay.io/mkowalski/cluster-config-api:bgp-demo \
  metallb-frr=quay.io/mkowalski/metallb-frr:bgp-demo \
  --to-image quay.io/mkowalski/ocp-release:bgp-vip-demo
```

Production sequencing: openshift/api first (gate+CRD), then ocp-build-data
adds the `kube-vip` payload member BEFORE the MCO image-references change
merges, FRR RPM backport in parallel, everything else in any order behind
the gate.
