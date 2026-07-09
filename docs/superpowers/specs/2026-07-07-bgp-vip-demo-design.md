# BGP VIP Management — Dev Demo Design

Date: 2026-07-07
Enhancement: [openshift/enhancements#1982](https://github.com/openshift/enhancements/pull/1982) (OPNET-595 / OPNET-773)
Author: mkowalski (implementation), design doc prepared with opencode

## Goal

Produce a **working end-to-end dev demo** of BGP-based VIP management on a
dev-scripts bare metal IPI cluster, using the existing (unmerged)
`OPNET-595-bgp-vip-management*` branches. Custom images and unmerged code are
acceptable; the point is to prove the architecture before polishing for
Tech Preview.

**Demo must demonstrate:**

1. **Install + API VIP via BGP** — cluster installs with
   `platform.baremetal.bgpVIPConfig` set; the API VIP is advertised via BGP
   from the bootstrap node onward; installation completes.
2. **Ingress VIP** — kube-vip-ingress manages the ingress VIP gated on the
   local router health check, advertised via BGP post-install.
3. **Bootstrap-to-CRD handover** — CNO creates the `FRRConfiguration` CR;
   the static-pod frr-k8s controller picks it up and BGP sessions
   re-establish/survive.

**Explicitly out of demo scope:** failover testing, BFD, dual-stack,
per-host peers (`hosts[].bgpPeers` — plumbing exists but is not exercised),
MetalLB/OVN-K coexistence, metrics/alerts, upgrade paths, keepalived
migration.

## Current State (verified 2026-07-07)

Branches `OPNET-595-bgp-vip-management` (+`-vendored`, `-dev` variants) exist
in: openshift-api, installer, machine-config-operator,
cluster-network-operator, kube-vip, baremetal-runtimecfg. Nothing deployed
yet. No branch in openshift/frr (none needed for the demo) or ovn-kubernetes
(out of demo scope).

### Verified demo-blocking defects

| # | Component | Defect |
|---|-----------|--------|
| 1 | MCO | Bootstrap manifests call `onPremPlatformAPIServerInternalIP .` instead of `.ControllerConfig` → render error (caught by `TestRenderAllManifests`) |
| 2 | MCO | `{{ .Images.FRRK8sBootstrap }}` / `KubeVIPBootstrap` fields don't exist in `RenderConfigImages`; no payload tag lookup for frr-k8s/kube-vip anywhere |
| 3 | MCO | `frr-peers.json.tmpl` references `.BGPPeersJSON` which exists in no Go type; day-2 variant writes literal `{{.BGPPeersJSON}}` to disk while runtimecfg parses the peer file as raw JSON → init container always fails. **No component sources the peer data for MCO at all** |
| 4 | MCO | `frr-metrics` container needs TLS certs nothing provisions; liveness probe on `:9141/livez` → static pod crashloops |
| 5 | MCO | `label-node` init container on the bootstrap node retries a Node patch that 404s forever (no Node object) → FRR never starts on bootstrap |
| 6 | MCO | frr-k8s `controller` container has no kubeconfig → cannot watch `FRRConfiguration` CRs → handover dead; `IS_BOOTSTRAP` env implies frr-k8s binary support that does not exist |
| 7 | installer | `additionalRoutingCapabilities.providers=[FRR]` never set → CNO never installs frr-k8s CRDs/namespace → CNO `FRRConfiguration` apply fails → Degraded forever |
| 8 | MCO | `0020-kube-vip-ingress.yaml` goes to `disabled-manifests/` unconditionally; nothing activates it |
| 9 | MCO | kube-vip image hardcoded `quay.io/mkowalski/kube-vip:latest` (3 places) |
| 10 | MCO | Common templates index `apiServerInternalIPs[0]` unguarded → breaks ALL BareMetal rendering without VIPs (even BGP off); branch unit tests fail |
| 11 | MCO | kube-vip/frr-k8s manifests in `templates/common/` → active on workers; should be master-only |
| 12 | MCO | `openshift-kube-vip` namespace never created (mirror-pod noise; Lease goes to kube-system so functionally OK — cosmetic) |

Schema mismatch: installer's `config.json` emits `peers`, runtimecfg's
`FRRPeerMapping` expects `defaultPeers`.

### Verified working (no action needed)

- kube-vip ↔ MCO manifest env contract (`control_plane_health_check_address`
  etc.) matches; HTTP health check in routing-table mode is functionally
  complete on the kube-vip branch (upstream `dcd3236` infra + `51e05fd`).
- kube-vip control-plane path adds the VIP address to the default-gateway
  interface AND writes the table-198 route; unhealthy → both removed.
- `frr.conf.tmpl` template variables exactly match runtimecfg's
  `FRRRenderConfig`/`FRRPeer` fields; `runtimecfg render --peer-file` works
  offline (no live API needed) — safe for bootstrap.
- CNO `renderBGPVIPFRRConfiguration` produces a coherent `bgp-vip-master`
  CR (master nodeSelector, neighbors, `table-direct 198` rawConfig).
- installer types/validation/feature gate, Infrastructure
  `VIPManagement=BGP`, `bgp-vip-config` ConfigMap generation all in place.
- dev-scripts has every hook needed: `OPENSHIFT_RELEASE_IMAGE`,
  `KNI_INSTALL_FROM_GIT`, `FEATURE_SET`, pre-created install-config flow,
  precedent for host-network FRR containers + firewalld port openings
  (metallb e2e).

## Design

### S1. Peer-data pipeline — one schema, one source

The installer-generated `bgp-vip-config` ConfigMap
(`openshift-network-operator/bgp-vip-config`, key `config.json`) is the
single source of truth for BGP peering data.

- **Schema alignment:** in the installer's `bgpVIPConfigJSON` struct and
  CNO's `bgpVIPConfigData` struct: rename `peers` → `defaultPeers`, and
  flatten `hostOverrides` from `{host: {"peers": [...]}}` to
  `{host: [...]}` — both to match runtimecfg's `FRRPeerMapping` exactly
  (unknown fields like `apiVIPs` are ignored by `json.Unmarshal`).
  `frr-peers.json` content == `config.json` content, verbatim.
- **Bootstrap path:** MCO `RenderBootstrap` gains a dependency on
  `/assets/manifests/bgp-vip-config.yaml` (same directory it already reads
  the Infrastructure manifest from). The `config.json` string is exposed to
  the bootstrap render as `BGPPeersJSON`; `manifests/on-prem/frr-peers.json.tmpl`
  renders it (stays unescaped — it is rendered by MCO, not at runtime).
- **Day-2 path:** MCO operator sync reads the same ConfigMap from
  `openshift-network-operator` (RBAC addition), stores the JSON string in a
  new `ControllerConfigSpec` field (added on the openshift-api branch,
  re-vendored into MCO). The template controller writes the real JSON into
  the `frr-k8s-peers` MachineConfig file content. File content is identical
  on all nodes; per-node peer resolution stays in runtimecfg by hostname
  lookup (per the EP's two-phase rendering design).

### S2. frr-k8s static pod surgery (MCO manifests)

- **Bootstrap variant (`manifests/on-prem/0000-frr-k8s.yaml`) → FRR-only:**
  keep `render-config-frr` init, `cp-frr-files` init, `frr` container.
  Remove `controller`, `reloader`, `frr-status`, `frr-metrics`, their `cp-*`
  init containers, and `label-node`. Fixes defects 4/5/6 for bootstrap with
  zero openshift/frr changes. Static `frr.conf` (rendered by runtimecfg from
  the peer file) is the sole config source during bootstrap.
- **Day-2 variant:** move `0000-frr-k8s.yaml`, `0010-kube-vip-api.yaml`,
  `0020-kube-vip-ingress.yaml` from `templates/common/on-prem/files/` to
  `templates/master/00-master/on-prem/files/` (fixes defect 11; arbiter
  zero-byte overrides move accordingly). Fix template context bugs
  (defect 1 pattern also present day-2 via unguarded indexing — see S6).
  Drop `frr-metrics` container and cert-dependent probes (defect 4).
  Add kubeconfig hostPath mount + `KUBECONFIG` env to `controller` and
  `frr-status` containers (defect 6). Keep `label-node` (day-2 only).
- **Daemons file:** verify `frr-startup-daemons` has no `-p 0` on
  `bgpd_options` (needs port 179 listening).
- **Known accepted race:** a master's controller connecting before CNO
  applies the `FRRConfiguration` CR renders an empty FRR config and drops
  the session until the CR appears. Low probability (CNO applies the CR
  during the bootstrap phase). Monitored in the demo, mitigation deferred
  to the real handover work.

### S3. Images & payload

- Build and push to personal quay: kube-vip (`Dockerfile.openshift`), MCO,
  CNO, baremetal-runtimecfg.
- Assemble custom payload from a recent 5.0 nightly:
  `oc adm release new --from-release <nightly>`
  swapping `machine-config-operator`, `cluster-network-operator`,
  `baremetal-runtimecfg` and **adding `kube-vip` as a new tag**. Fallback if
  new-tag injection is refused: extract image-references, add the entry,
  rebuild from files.
- MCO image plumbing (replaces defect 2/9 hacks):
  - `cmd/machine-config-operator/bootstrap.go`: payload tag lookups for
    `kube-vip` and the frr-k8s tag (confirm exact tag name from CNO's
    image-references; reuse it).
  - `RenderConfigImages`: add `KubeVIPBootstrap`, `FRRK8sBootstrap`.
  - Day-2: add `kubeVipImage`, `frrK8sImage` to
    `install/0000_80_machine-config_02_images.configmap.yaml` + MCO
    image-references; parse into the Images structs; populate the images
    map in `sync.go` and `bootstrap.go`.
  - Replace the 3 hardcoded `quay.io/mkowalski/kube-vip:latest` pullspecs
    with template references.
- Installer: built from git via dev-scripts `KNI_INSTALL_FROM_GIT`
  (`OPENSHIFT_INSTALL_PATH` → the installer repo, `-vendored` branch).

### S4. CNO + installer wiring

- **Installer:** generate/extend `cluster-network-03-config.yml`
  (operator.openshift.io/v1 Network) with
  `spec.additionalRoutingCapabilities.providers: [FRR]` when `bgpVIPConfig`
  is set (fixes defect 7; EP-faithful).
- **CNO cleanups:** read `VIPManagement` typed from
  `bootstrapResult.Infra.PlatformStatus.BareMetal` (drop the live
  unstructured GET), gate on the `BGPBasedVIPManagement` feature gate,
  apply the `defaultPeers` rename. Keep the single `bgp-vip-master` CR and
  hardcoded `/32` (IPv4-only demo).
- **RBAC:** CNO bindata ships a ClusterRole/ClusterRoleBinding allowing the
  static pod's node credentials (`/etc/kubernetes/kubeconfig` identity) to
  get/list/watch `frrconfigurations` and create/update `frrnodestates` +
  `bgpsessionstates`.
- **Ingress activation:** MCO gates `0020-kube-vip-ingress.yaml` on
  `isBGPVIPManagement` into `/etc/kubernetes/manifests/` exactly like the
  API instance (fixes defect 8). Health-gated → inert until a local router
  exists. CNO→MachineConfig orchestration from the EP is deferred.
- **Handover demo criterion:** CNO CR exists → static-pod controller merges
  & reloads → sessions re-establish → visible in `BGPSessionState` and on
  the ToR. Static `frr.conf` removal and `checkBGPSessionsEstablished`
  gating stay deferred.

### S5. Demo environment (dev-scripts)

- Topology: **3 masters, 0 workers** (compact) — routers land on masters,
  so the ingress health check passes there and the master-scoped
  `FRRConfiguration` covers both VIPs. IPv4 single-stack. Default in-subnet
  VIPs (api `192.168.111.5`, ingress `192.168.111.4`): the learned `/32`
  beats the connected `/24` on the hypervisor, so host→VIP traffic
  genuinely follows the BGP route.
- ToR: FRR container (`quay.io/frrouting/frr`), `--net host` on the
  hypervisor (metallb e2e precedent). Config: ASN 64513 (eBGP),
  `bgp listen range 192.168.111.0/24 peer-group CLUSTER` (dynamic
  neighbors — masters DHCP from .20–.60), accept `/32`s, install to kernel.
  BFD off. firewalld: open `179/tcp` in the libvirt zone.
- Helper: `bgp-tor.sh up|down|status` — starts/stops the ToR container,
  manages firewall ports, shows `show ip bgp`. Lives in this repo.
- install-config via dev-scripts pre-created flow (`make install_config`,
  edit `ocp/ostest/install-config.yaml` + `.save`):
  `featureSet: DevPreviewNoUpgrade` (where the gate currently lives;
  TechPreview graduation is post-demo) and
  `platform.baremetal.bgpVIPConfig: {localASN: 64512, peers:
  [{peerAddress: 192.168.111.1, peerASN: 64513}]}`.

### S6. Branch hygiene

Fix defect 10 so the MCO test suite passes on the branch: gate each
BGP manifest's entire template body (not just its target path) on
`isBGPVIPManagement`, and add a length guard to the singular
`onPremPlatformAPIServerInternalIP`/`onPremPlatformIngressIP` helpers so
VIP-less BareMetal configs render again (BGP off included).

## Risks

| Risk | Mitigation / fallback |
|------|----------------------|
| `label-node` label `network.openshift.io/*` may be denied by NodeRestriction for node-identity kubeconfig | Verify early on a live cluster; fallback: CNO applies role-based anti-affinity (masters) when `VIPManagement=BGP`, drop the label |
| `/etc/kubernetes/kubeconfig` identity may lack RBAC for frr-k8s CRs even with new ClusterRoleBinding (identity is not `system:nodes`?) | Verify identity first (`oc whoami`); bind to the actual group/user |
| `oc adm release new` may refuse a brand-new `kube-vip` tag | Fallback: extract image-references, edit, rebuild from files |
| Empty-config race: controller reloads before CNO CR exists → session drop on masters | Accept for demo; verify CR exists before masters pivot; real fix in handover work |
| frr-k8s controller behavior as a static pod is unproven (mirror pod, node association via `--node-name`) | First live test focuses on this; FRR-only fallback for day-2 too if controller misbehaves (handover demo then deferred) |
| kube-vip Lease self-election on bootstrap node needs the bootstrap kube-apiserver up first — VIP appears only after localhost API answers | Same ordering as keepalived+runtimecfg today; verify timing in bootstrap logs |

## Sequencing

1. S1 schema alignment (installer + CNO structs)
2. openshift-api: `ControllerConfigSpec` field → re-vendor into MCO
3. MCO stack: bootstrap ConfigMap dependency, render fixes, image plumbing,
   pod manifest surgery, template relocation + guards (S1/S2/S3/S6)
4. Installer: `additionalRoutingCapabilities`; CNO: typed reads + RBAC (S4)
5. Unit-test gate: MCO `TestRenderAllManifests` + template tests green;
   installer + CNO tests green
6. Images + payload assembly (S3)
7. dev-scripts env + ToR + install-config (S5)
8. Demo run; iterate on findings

## Verification checklist (demo acceptance)

1. Bootstrap: `ip route show table 198` shows API VIP; ToR `show ip bgp`
   has VIP `/32` with bootstrap next-hop.
2. Masters join via the VIP; at bootstrap teardown the next-hop pivots to a
   master.
3. Install completes (`openshift-install ... wait-for install-complete`).
4. Ingress VIP advertised from a master with a healthy router; route
   appears/disappears with router health.
5. `FRRConfiguration/bgp-vip-master` exists; `BGPSessionState` CRs show
   Established; sessions survived the CRD handover.
6. `ip route get 192.168.111.5` on the hypervisor resolves via the BGP
   route (not the connected subnet).

---

## Execution Addendum (2026-07-09)

The demo was implemented and completed (run14, all criteria). Reality diverged
from this spec in the following ways — the spec is preserved as-designed; see
docs/RUN-LEDGER.md for the full story:

- **S2/S4 label-based anti-affinity abandoned**: NodeRestriction denies
  node-credential labels and DaemonSet scheduling races the label anyway.
  Replaced with role-based anti-affinity (DaemonSet avoids masters when BGP
  mode is active). `runtimecfg label-node` is dead code.
- **S4 RBAC subject**: the node kubeconfig identity is the MCO
  `node-bootstrapper` ServiceAccount, not `system:nodes` (the spec's flagged
  risk fired). Grants also needed `frrk8sconfigurations` + namespace-scoped
  secrets/pods reads.
- **S4 handover advertisement mechanism redesigned twice**: CRD
  prefixes/toAdvertise are unconditionally-advertised network statements
  (destroyed health gating, run8); frr-k8s `mode: all` egress only covers
  declared prefixes. Final design: CR carries sessions; advertisement stays on
  `redistribute table-direct 198` + filters + `ip import-table 198` in
  rawConfig, with high-seq raw permits appended to frr-k8s's generated
  `<peer>-out` route-maps.
- **New dependency discovered**: FRR < 10.7 never redistributes routes that
  pre-exist in the table at config time (zebra import clears SELECTED).
  Backported FRRouting/frr b2c17ad52; shipped as a zebra overlay on the
  metallb-frr image; payload gained a sixth override.
- **Payload also needed `cluster-config-api`** from the api branch — the stock
  CRD prunes `vipManagement` and the feature gate is unknown otherwise. Spec's
  S3 listed only four custom images.
- **Ingress health endpoint corrected**: router `:1936/healthz`, not the EP's
  `:29445` (API haproxy monitor).
- **kube-vip upstream gaps**: manager AND backend health checks ignore the
  configured kubeconfig (two downstream patches); the RT-mode loop is not
  leadership-gated → the demo runs health-gated ECMP rather than
  active/passive (works well; EP-level decision pending).
- The "known accepted race" (S2, controller empty-config) manifested as the
  larger FRR/frr-k8s advertisement issues above and is resolved by the same
  design change.
