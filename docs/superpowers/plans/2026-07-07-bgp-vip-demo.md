# BGP VIP Dev Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dev-scripts bare metal cluster installs end-to-end with API + Ingress VIPs advertised via BGP (kube-vip routing-table mode + frr-k8s static pods), including the bootstrap-to-CRD handover.

**Architecture:** Fix the verified defects on the existing `OPNET-595-bgp-vip-management*` branches: align the peer-data schema (installer ConfigMap == runtimecfg peer file), plumb peer data into MCO (bootstrap file dep + new `ControllerConfigSpec` field), repair MCO bootstrap/day-2 rendering and static pod manifests, wire real image resolution, enable FRR CRDs via the installer, then build a custom release payload and run the demo against an FRR ToR container on the hypervisor.

**Tech Stack:** Go (installer/MCO/CNO/openshift-api), Go templates (MCO manifests), podman + `oc adm release new`, dev-scripts, FRR.

**Spec:** `docs/superpowers/specs/2026-07-07-bgp-vip-demo-design.md`

**Branch convention:** each repo works on its existing branch: installer `OPNET-595-bgp-vip-management-vendored`, openshift-api `OPNET-595-bgp-vip-management`, MCO `OPNET-595-bgp-vip-management-dev`, CNO `OPNET-595-bgp-vip-management-vendored`, kube-vip `OPNET-595-bgp-vip-management`, baremetal-runtimecfg `OPNET-595-bgp-vip-management`. Repos live under `/home/kmateusz/git/github.com/`. PR-facing branch cleanup (splitting vendor commits) is out of scope.

**Deviation from spec S6 (decided during planning):** the manifests keep the existing path-flip gating (`/etc/kubernetes/manifests/` vs `disabled-manifests/`); we only add length guards to the singular VIP helpers. Gating whole template bodies would produce empty rendered files whose handling in the MCO pipeline is unverified; guards alone make the failing tests pass.

---

## Phase 1 — installer (schema + FRR enablement)

### Task 1: Align `bgp-vip-config` JSON schema with runtimecfg

**Files:**
- Modify: `installer/pkg/asset/manifests/bgpvipconfig.go`
- Create: `installer/pkg/asset/manifests/bgpvipconfig_test.go`

Workdir: `/home/kmateusz/git/github.com/installer`, branch `OPNET-595-bgp-vip-management-vendored`.

- [ ] **Step 1: Write the failing test**

Create `pkg/asset/manifests/bgpvipconfig_test.go`:

```go
package manifests

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/openshift/installer/pkg/asset"
	"github.com/openshift/installer/pkg/asset/installconfig"
	"github.com/openshift/installer/pkg/types"
	"github.com/openshift/installer/pkg/types/baremetal"
)

func bgpInstallConfig() *installconfig.InstallConfig {
	ic := &installconfig.InstallConfig{}
	ic.Config = &types.InstallConfig{
		Platform: types.Platform{
			BareMetal: &baremetal.Platform{
				APIVIPs:     []string{"192.168.111.5"},
				IngressVIPs: []string{"192.168.111.4"},
				BGPVIPConfig: &baremetal.BGPVIPConfig{
					LocalASN: 64512,
					Peers: []baremetal.BGPPeerConfig{
						{PeerAddress: "192.168.111.1", PeerASN: 64513},
					},
				},
				Hosts: []*baremetal.Host{
					{
						Name: "master-0",
						BGPPeers: []baremetal.BGPPeerConfig{
							{PeerAddress: "192.168.1.1", PeerASN: 64513},
						},
					},
				},
			},
		},
	}
	return ic
}

// The config.json schema must match baremetal-runtimecfg's FRRPeerMapping:
// top-level "defaultPeers" (not "peers") and hostOverrides as a flat
// map[hostname][]peer (not map[hostname]{"peers":[...]}).
func TestBGPVIPConfigMapSchemaMatchesRuntimecfg(t *testing.T) {
	parents := asset.Parents{}
	parents.Add(bgpInstallConfig())

	cmAsset := &BGPVIPConfigMap{}
	require.NoError(t, cmAsset.Generate(context.Background(), parents))
	require.NotNil(t, cmAsset.ConfigMap)

	var got map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(cmAsset.ConfigMap.Data["config.json"]), &got))

	assert.Contains(t, got, "defaultPeers")
	assert.NotContains(t, got, "peers")

	var overrides map[string][]baremetal.BGPPeerConfig
	require.NoError(t, json.Unmarshal(got["hostOverrides"], &overrides))
	require.Len(t, overrides["master-0"], 1)
	assert.Equal(t, "192.168.1.1", overrides["master-0"][0].PeerAddress)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./pkg/asset/manifests/ -run TestBGPVIPConfigMapSchemaMatchesRuntimecfg -v`
Expected: FAIL — `got` contains `peers`, not `defaultPeers`, and `hostOverrides` unmarshal into `[]BGPPeerConfig` fails (wrapped object form).

- [ ] **Step 3: Change the schema in `bgpvipconfig.go`**

Replace the two struct definitions and the Generate body sections:

```go
// bgpVIPConfigJSON is the JSON structure stored in the ConfigMap. Its field
// names match baremetal-runtimecfg's FRRPeerMapping so the same JSON can be
// written verbatim to /etc/kubernetes/static-pod-resources/frr-k8s/frr-peers.json.
type bgpVIPConfigJSON struct {
	LocalASN      int64                                `json:"localASN"`
	DefaultPeers  []baremetal.BGPPeerConfig            `json:"defaultPeers"`
	Communities   []string                             `json:"communities,omitempty"`
	APIVIPs       []string                             `json:"apiVIPs"`
	IngressVIPs   []string                             `json:"ingressVIPs"`
	HostOverrides map[string][]baremetal.BGPPeerConfig `json:"hostOverrides,omitempty"`
}
```

Delete the `bgpHostOverride` type entirely. In `Generate`, replace:

```go
	configData := bgpVIPConfigJSON{
		LocalASN:     bgpConfig.LocalASN,
		DefaultPeers: bgpConfig.Peers,
		Communities:  bgpConfig.Communities,
		APIVIPs:      bm.APIVIPs,
		IngressVIPs:  bm.IngressVIPs,
	}

	// Collect per-host BGP peer overrides.
	hostOverrides := make(map[string][]baremetal.BGPPeerConfig)
	for _, host := range bm.Hosts {
		if host != nil && len(host.BGPPeers) > 0 {
			hostOverrides[host.Name] = host.BGPPeers
		}
	}
	if len(hostOverrides) > 0 {
		configData.HostOverrides = hostOverrides
	}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./pkg/asset/manifests/ -run TestBGPVIPConfigMapSchemaMatchesRuntimecfg -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pkg/asset/manifests/bgpvipconfig.go pkg/asset/manifests/bgpvipconfig_test.go
git commit -m "installer: align bgp-vip-config schema with runtimecfg FRRPeerMapping"
```

### Task 2: Installer enables FRR via additionalRoutingCapabilities

**Files:**
- Modify: `installer/pkg/asset/manifests/network.go` (function `clusterNetworkOperatorConfig`, ~line 133)
- Test: `installer/pkg/asset/manifests/network_test.go` (create if absent)

- [ ] **Step 1: Write the failing test**

Append to (or create) `pkg/asset/manifests/network_test.go`:

```go
package manifests

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	operatorv1 "github.com/openshift/api/operator/v1"
	"github.com/openshift/installer/pkg/asset/installconfig"
	"github.com/openshift/installer/pkg/types"
	"github.com/openshift/installer/pkg/types/baremetal"
)

func TestCNOConfigEnablesFRRForBGPVIP(t *testing.T) {
	ic := &installconfig.InstallConfig{}
	ic.Config = &types.InstallConfig{
		Networking: &types.Networking{NetworkType: "OVNKubernetes"},
		Platform: types.Platform{
			BareMetal: &baremetal.Platform{
				BGPVIPConfig: &baremetal.BGPVIPConfig{LocalASN: 64512},
			},
		},
	}
	cfg, err := clusterNetworkOperatorConfig(ic, nil, nil)
	require.NoError(t, err)
	require.NotNil(t, cfg)
	require.NotNil(t, cfg.Spec.AdditionalRoutingCapabilities)
	assert.Contains(t, cfg.Spec.AdditionalRoutingCapabilities.Providers,
		operatorv1.RoutingCapabilitiesProviderFRR)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./pkg/asset/manifests/ -run TestCNOConfigEnablesFRRForBGPVIP -v`
Expected: FAIL — `cfg` is nil (no baremetal branch in `clusterNetworkOperatorConfig`).

- [ ] **Step 3: Implement**

In `clusterNetworkOperatorConfig` in `pkg/asset/manifests/network.go`, add a `baremetal.Name` case to the existing platform switch (the file already imports the `baremetal` types package alias used elsewhere in `pkg/asset/manifests`; add `baremetal "github.com/openshift/installer/pkg/types/baremetal"` to imports if not present):

```go
	case baremetal.Name:
		// BGP-based VIP management needs frr-k8s CRDs/namespace deployed by
		// CNO; enable the FRR routing capability provider.
		if ic.Config.Platform.BareMetal.BGPVIPConfig != nil {
			cnoCfg = ovnNetworkOperatorConfig(cns, sn)
			cnoCfg.Spec.AdditionalRoutingCapabilities = &operatorv1.AdditionalRoutingCapabilities{
				Providers: []operatorv1.RoutingCapabilitiesProvider{operatorv1.RoutingCapabilitiesProviderFRR},
			}
		}
```

Note: place the case before the trailing `OVNKubernetesConfig` customization block so the later `if ovnCfg := ...` block can still extend `cnoCfg`.

- [ ] **Step 4: Run test + package tests**

Run: `go test ./pkg/asset/manifests/ -run 'TestCNOConfigEnablesFRRForBGPVIP|TestBGPVIPConfigMapSchemaMatchesRuntimecfg' -v && go build ./...`
Expected: PASS, build OK

- [ ] **Step 5: Commit**

```bash
git add pkg/asset/manifests/network.go pkg/asset/manifests/network_test.go
git commit -m "installer: enable FRR routing capability when bgpVIPConfig is set"
```

---

## Phase 2 — openshift-api (ControllerConfig field)

### Task 3: Add `BGPVIPPeersJSON` to ControllerConfigSpec

**Files:**
- Modify: `openshift-api/machineconfiguration/v1/types.go` (ControllerConfigSpec, after the `Images` field ~line 114)

Workdir: `/home/kmateusz/git/github.com/openshift-api`, branch `OPNET-595-bgp-vip-management`.

- [ ] **Step 1: Add the field**

In `type ControllerConfigSpec struct`, after the `Images map[string]string` field:

```go
	// bgpVIPPeersJSON carries the BGP VIP peer configuration (the config.json
	// payload of the bgp-vip-config ConfigMap) for rendering the frr-k8s
	// static pod peer file on control plane nodes. Only set when BGP-based
	// VIP management is enabled.
	// +openshift:enable:FeatureGate=BGPBasedVIPManagement
	// +optional
	BGPVIPPeersJSON string `json:"bgpVIPPeersJSON,omitempty"`
```

- [ ] **Step 2: Regenerate**

Run: `make update`
Expected: regenerates zz_generated files/CRD manifests without errors. If `make update` requires unavailable container tooling, fall back to `go build ./...` (string field needs no deepcopy change) and note it in the commit message.

- [ ] **Step 3: Build check + commit**

```bash
go build ./... && git add -A && git commit -m "machineconfiguration/v1: add BGPVIPPeersJSON to ControllerConfigSpec"
```

---

## Phase 3 — MCO (rendering, images, static pods)

Workdir: `/home/kmateusz/git/github.com/machine-config-operator`, branch `OPNET-595-bgp-vip-management-dev`.

### Task 4: Vendor updated openshift/api

- [ ] **Step 1: Vendor via local replace**

```bash
go mod edit -replace github.com/openshift/api=/home/kmateusz/git/github.com/openshift-api
go mod tidy && go mod vendor
go build ./... 
```
Expected: build OK; `vendor/github.com/openshift/api/machineconfiguration/v1/types.go` contains `BGPVIPPeersJSON`.

- [ ] **Step 2: Commit**

```bash
git add -A && git commit -m "MCO: vendor openshift/api with ControllerConfigSpec.BGPVIPPeersJSON (local replace, dev only)"
```

### Task 5: Guard singular VIP template helpers (defect 10)

**Files:**
- Modify: `machine-config-operator/pkg/controller/template/render.go` (`onPremPlatformIngressIP` ~line 497, `onPremPlatformAPIServerInternalIP` ~line 557)

- [ ] **Step 1: Run the currently-failing tests to capture the failure**

Run: `go test ./pkg/controller/template/ -run 'TestGenerateMachineConfigs|TestKubeletConfigDirParameter' 2>&1 | tail -20`
Expected: FAIL with `index out of range [0] with length 0` (BareMetal fixtures without VIPs).

- [ ] **Step 2: Add guards**

In both functions, replace the BareMetal case:

```go
		case configv1.BareMetalPlatformType:
			if len(cfg.Infra.Status.PlatformStatus.BareMetal.APIServerInternalIPs) == 0 {
				return nil, nil
			}
			return cfg.Infra.Status.PlatformStatus.BareMetal.APIServerInternalIPs[0], nil
```

and for ingress:

```go
		case configv1.BareMetalPlatformType:
			if len(cfg.Infra.Status.PlatformStatus.BareMetal.IngressIPs) == 0 {
				return nil, nil
			}
			return cfg.Infra.Status.PlatformStatus.BareMetal.IngressIPs[0], nil
```

- [ ] **Step 3: Verify tests pass**

Run: `go test ./pkg/controller/template/ 2>&1 | tail -5`
Expected: `ok` (all template controller tests pass, including `TestIsBGPVIPManagement`).

- [ ] **Step 4: Commit**

```bash
git add pkg/controller/template/render.go
git commit -m "MCO: guard singular on-prem VIP helpers against empty VIP lists"
```

### Task 6: Peer-data pipeline — bootstrap dependency, day-2 sync, template fixes

**Files:**
- Modify: `machine-config-operator/pkg/operator/bootstrap_dependencies.go`
- Modify: `machine-config-operator/pkg/operator/bootstrap.go` (`buildSpec`)
- Modify: `machine-config-operator/pkg/operator/sync.go` (day-2 ControllerConfig population)
- Modify: `machine-config-operator/cmd/machine-config-operator/bootstrap.go` (new flag)
- Modify: `machine-config-operator/install/0000_80_machine-config_00_rbac.yaml` (read ConfigMaps in openshift-network-operator)
- Modify: `machine-config-operator/manifests/on-prem/frr-peers.json.tmpl`
- Modify: `machine-config-operator/templates/master/00-master/on-prem/files/frr-k8s-peers.yaml` (day-2 peer file)
- Modify: `machine-config-operator/manifests/on-prem/0000-frr-k8s.yaml` (template context)
- Modify: `machine-config-operator/manifests/on-prem/0010-kube-vip-api.yaml` (template context)
- Test: `machine-config-operator/pkg/operator/bootstrap_test.go`

- [ ] **Step 1: Write the failing render test**

`TestRenderAllManifests` in `pkg/operator/render_test.go` already fails for the three on-prem BGP files. Additionally append to `pkg/operator/bootstrap_test.go`:

```go
func TestBuildSpecBGPVIPPeersJSON(t *testing.T) {
	// A ConfigMap manifest shaped like the installer's bgp-vip-config.yaml.
	dir := t.TempDir()
	cmYAML := `apiVersion: v1
kind: ConfigMap
metadata:
  name: bgp-vip-config
  namespace: openshift-network-operator
data:
  config.json: '{"localASN":64512,"defaultPeers":[{"peerAddress":"192.168.111.1","peerASN":64513}],"apiVIPs":["192.168.111.5"],"ingressVIPs":["192.168.111.4"]}'
`
	path := filepath.Join(dir, "bgp-vip-config.yaml")
	require.NoError(t, os.WriteFile(path, []byte(cmYAML), 0o644))

	deps := &BootstrapDependencies{}
	require.NoError(t, deps.fillBGPVIPConfig(path))
	require.Contains(t, deps.BGPVIPPeersJSON, `"defaultPeers"`)
}
```

(Adjust imports: `os`, `path/filepath`, `github.com/stretchr/testify/require`.)

Run: `go test ./pkg/operator/ -run TestBuildSpecBGPVIPPeersJSON -v`
Expected: FAIL — `fillBGPVIPConfig` undefined.

- [ ] **Step 2: Implement the dependency**

In `pkg/operator/bootstrap_dependencies.go`:

1. Add to `BootstrapDependenciesFiles`: `BGPVIPConfig string` and to the `Validate()` files table: `{"BGPVIPConfig", b.BGPVIPConfig, false},`
2. Add to `BootstrapDependencies`: `BGPVIPPeersJSON string`
3. Add method + call it from `fillDependencies()` (after `fillClusterConfig()`):

```go
// fillBGPVIPConfig loads the optional bgp-vip-config ConfigMap manifest and
// extracts its config.json payload for frr-peers.json rendering.
func (b *BootstrapDependencies) fillBGPVIPConfig(path string) error {
	if path == "" {
		return nil
	}
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil // optional: only present when BGP VIP management is enabled
	}
	cm, err := readCoreCR[*corev1.ConfigMap](path)
	if err != nil {
		return fmt.Errorf("failed to read bgp-vip-config ConfigMap: %w", err)
	}
	b.BGPVIPPeersJSON = cm.Data["config.json"]
	return nil
}
```

In `fillDependencies()` add: `if err := b.fillBGPVIPConfig(b.Files.BGPVIPConfig); err != nil { return err }`

4. In `pkg/operator/bootstrap.go` `buildSpec`, after `spec.RootCAData = ...` block add:

```go
	spec.BGPVIPPeersJSON = dependencies.BGPVIPPeersJSON
```

5. In `cmd/machine-config-operator/bootstrap.go` flags section add:

```go
	bootstrapCmd.PersistentFlags().StringVar(&bootstrapOpts.dependencyFiles.BGPVIPConfig, "bgp-vip-config-file", "/assets/manifests/bgp-vip-config.yaml", "File containing the bgp-vip-config ConfigMap manifest (optional).")
```

- [ ] **Step 3: Fix the templates**

`manifests/on-prem/frr-peers.json.tmpl` — replace entire content with:

```
{{- .ControllerConfig.BGPVIPPeersJSON -}}
```

`manifests/on-prem/0000-frr-k8s.yaml` — replace both occurrences:
`{{ onPremPlatformAPIServerInternalIP . }}` → `{{ onPremPlatformAPIServerInternalIP .ControllerConfig }}` and
`{{ onPremPlatformIngressIP . }}` → `{{ onPremPlatformIngressIP .ControllerConfig }}`.

`manifests/on-prem/0010-kube-vip-api.yaml` — same replacement for its `onPremPlatformAPIServerInternalIP` occurrence.

`templates/master/00-master/on-prem/files/frr-k8s-peers.yaml` — the day-2 peer file is rendered by the template controller (whose `RenderConfig` embeds `*ControllerConfigSpec`, so the field is promoted). Replace the escaped literal:

```yaml
mode: 0644
path: "/etc/kubernetes/static-pod-resources/frr-k8s/frr-peers.json"
contents:
  inline: |
    {{.BGPVIPPeersJSON}}
```

(Do the same for `templates/worker/00-worker/on-prem/files/frr-k8s-peers.yaml` only if Task 9 has not yet deleted it; final state is master-only.)

- [ ] **Step 4: Day-2 operator sync populates the field**

In `pkg/operator/sync.go`, add after the `optr.syncCloudConfig(spec, infra)` call (~line 594):

```go
	if err := optr.syncBGPVIPPeersJSON(spec, infra); err != nil {
		return err
	}
```

and add the method (imports: `apierrors "k8s.io/apimachinery/pkg/api/errors"` if not present):

```go
// syncBGPVIPPeersJSON populates spec.BGPVIPPeersJSON from the
// openshift-network-operator/bgp-vip-config ConfigMap when BGP-based VIP
// management is enabled on a BareMetal platform.
func (optr *Operator) syncBGPVIPPeersJSON(spec *mcfgv1.ControllerConfigSpec, infra *configv1.Infrastructure) error {
	if infra.Status.PlatformStatus == nil ||
		infra.Status.PlatformStatus.BareMetal == nil ||
		infra.Status.PlatformStatus.BareMetal.VIPManagement != "BGP" {
		return nil
	}
	cm, err := optr.kubeClient.CoreV1().ConfigMaps("openshift-network-operator").Get(
		context.TODO(), "bgp-vip-config", metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil // tolerate absence; bootstrap-rendered peers file remains in place
		}
		return fmt.Errorf("failed to read bgp-vip-config ConfigMap: %w", err)
	}
	spec.BGPVIPPeersJSON = cm.Data["config.json"]
	return nil
}
```

- [ ] **Step 5: MCO RBAC for the ConfigMap read**

Append to `install/0000_80_machine-config_00_rbac.yaml` (copy the `include.release.openshift.io/*` annotations and the RoleBinding subject from the adjacent Role/RoleBinding pairs in the same file — the subject must match what the existing bindings use for the MCO service account):

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: machine-config-operator-bgp-vip
  namespace: openshift-network-operator
  annotations:
    include.release.openshift.io/ibm-cloud-managed: "true"
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: machine-config-operator-bgp-vip
  namespace: openshift-network-operator
  annotations:
    include.release.openshift.io/ibm-cloud-managed: "true"
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: machine-config-operator-bgp-vip
subjects:
  - kind: ServiceAccount
    name: machine-config-operator
    namespace: openshift-machine-config-operator
```

- [ ] **Step 6: Run tests**

Run: `go test ./pkg/operator/ -run 'TestBuildSpecBGPVIPPeersJSON|TestRenderAllManifests|TestGetPlatformManifests' -v 2>&1 | tail -15`
Expected: `TestBuildSpecBGPVIPPeersJSON` PASS; `TestRenderAllManifests` still fails ONLY on `.Images.FRRK8sBootstrap`/kube-vip image references (fixed in Task 7); if it fails on anything else, fix before proceeding.

- [ ] **Step 7: Commit**

```bash
git add pkg/operator/ cmd/machine-config-operator/bootstrap.go manifests/on-prem/ templates/ install/
git commit -m "MCO: source frr-peers.json from installer bgp-vip-config ConfigMap (bootstrap and day-2)"
```

### Task 7: Real image resolution for frr-k8s and kube-vip

**Files:**
- Modify: `machine-config-operator/pkg/controller/common/images.go`
- Modify: `machine-config-operator/cmd/machine-config-operator/bootstrap.go`
- Modify: `machine-config-operator/pkg/operator/bootstrap.go` (`buildSpec` images map)
- Modify: `machine-config-operator/pkg/operator/sync.go` (images map ~line 613)
- Modify: `machine-config-operator/install/0000_80_machine-config_02_images.configmap.yaml`
- Modify: `machine-config-operator/install/image-references`
- Modify: `machine-config-operator/manifests/on-prem/0000-frr-k8s.yaml`, `0010-kube-vip-api.yaml`
- Modify: `machine-config-operator/templates/common/on-prem/files/0000-frr-k8s.yaml`, `0010-kube-vip-api.yaml`, `0020-kube-vip-ingress.yaml`

The frr-k8s payload tag is **`metallb-frr`** (verified: CNO deployment `FRR_K8S_IMAGE` ← `manifests/image-references` tag `metallb-frr`). kube-vip uses new payload tag **`kube-vip`**.

- [ ] **Step 1: Struct fields**

`pkg/controller/common/images.go` — add to `RenderConfigImages`:

```go
	FRRK8sBootstrap              string `json:"frrK8s"`
	KubeVIPBootstrap             string `json:"kubeVip"`
```

and to `ControllerConfigImages`:

```go
	FRRK8s              string `json:"frrK8sImage"`
	KubeVip             string `json:"kubeVipImage"`
```

- [ ] **Step 2: Bootstrap CLI lookups**

`cmd/machine-config-operator/bootstrap.go`:
- add two fields to the `bootstrapOpts` struct (next to `keepalivedImage`/`corednsImage`):

```go
		frrK8sImage  string
		kubeVipImage string
```

- add flags:

```go
	bootstrapCmd.PersistentFlags().StringVar(&bootstrapOpts.frrK8sImage, "frr-k8s-image", "", "Image for frr-k8s.")
	bootstrapCmd.PersistentFlags().StringVar(&bootstrapOpts.kubeVipImage, "kube-vip-image", "", "Image for kube-vip.")
```

- in the `imageReferences` block add non-fatal lookups (these tags may be absent in payloads without BGP support):

```go
		if img, err := findImage(imgstream, "metallb-frr"); err == nil {
			bootstrapOpts.frrK8sImage = img
		} else {
			klog.Warningf("metallb-frr image not found in image references: %v", err)
		}
		if img, err := findImage(imgstream, "kube-vip"); err == nil {
			bootstrapOpts.kubeVipImage = img
		} else {
			klog.Warningf("kube-vip image not found in image references: %v", err)
		}
```

- wire into the `imgs` literal: `FRRK8sBootstrap: bootstrapOpts.frrK8sImage,` + `KubeVIPBootstrap: bootstrapOpts.kubeVipImage,` (RenderConfigImages) and `FRRK8s: bootstrapOpts.frrK8sImage,` + `KubeVip: bootstrapOpts.kubeVipImage,` (ControllerConfigImages).

- [ ] **Step 3: Images maps**

`pkg/operator/bootstrap.go` `buildSpec` — add to `spec.Images`:

```go
		templatectrl.FRRK8sKey:  imgs.FRRK8s,
		templatectrl.KubeVIPKey: imgs.KubeVip,
```

`pkg/operator/sync.go` (~line 613) — add the same two entries to the `spec.Images` map.

- [ ] **Step 4: Payload wiring**

`install/0000_80_machine-config_02_images.configmap.yaml` — add to `images.json`:

```json
      "frrK8sImage": "placeholder.url.oc.will.replace.this.org/placeholdernamespace:metallb-frr",
      "kubeVipImage": "placeholder.url.oc.will.replace.this.org/placeholdernamespace:kube-vip"
```

`install/image-references` — append two tags following the existing entry format:

```yaml
  - name: metallb-frr
    from:
      kind: DockerImage
      name: placeholder.url.oc.will.replace.this.org/placeholdernamespace:metallb-frr
  - name: kube-vip
    from:
      kind: DockerImage
      name: placeholder.url.oc.will.replace.this.org/placeholdernamespace:kube-vip
```

- [ ] **Step 5: Un-hardcode manifests**

- `manifests/on-prem/0010-kube-vip-api.yaml`: `quay.io/mkowalski/kube-vip:latest` → `{{ .Images.KubeVIPBootstrap }}`
- `templates/common/on-prem/files/0010-kube-vip-api.yaml` and `0020-kube-vip-ingress.yaml`: `quay.io/mkowalski/kube-vip:latest` → `{{.Images.kubeVipImage}}`

(`{{ .Images.FRRK8sBootstrap }}` in the bootstrap frr-k8s manifest and `{{.Images.frrK8sImage}}` day-2 now resolve via the struct/map additions above.)

- [ ] **Step 6: Verify**

Run: `go test ./pkg/operator/ ./pkg/controller/template/ ./pkg/controller/common/ 2>&1 | tail -8`
Expected: all PASS, including `TestRenderAllManifests` (bootstrap manifests now render with fixture images).

- [ ] **Step 7: Commit**

```bash
git add pkg/ cmd/ install/ manifests/ templates/
git commit -m "MCO: resolve frr-k8s and kube-vip images from the release payload"
```

### Task 8: Bootstrap frr-k8s pod → FRR-only

**Files:**
- Modify: `machine-config-operator/manifests/on-prem/0000-frr-k8s.yaml`

- [ ] **Step 1: Trim the pod**

Edit `manifests/on-prem/0000-frr-k8s.yaml`:
- **Keep** initContainers: `render-config-frr`, `cp-frr-files`. **Delete** initContainers: `label-node`, `cp-reloader`, `cp-metrics`, `cp-frr-status`.
- **Keep** container: `frr`. **Delete** containers: `controller`, `reloader`, `frr-metrics`, `frr-status`.
- In the `frr` container, delete any `livenessProbe`/`startupProbe` blocks that point at port 9141 (`/livez`).
- Delete now-unused volumes: `reloader`, `metrics`, `frr-status`, `metrics-certs` (keep `resource-dir`, `frr-conf`, `frr-sockets`, `frr-startup`, `kubeconfig`, `frr-lib`, `frr-tmp` if referenced by remaining containers — check each remaining volumeMount and keep exactly what is mounted).
- Delete the `FRR_CONFIG_FILE`/`FRR_RELOADER_PID_FILE` env vars if they were on deleted containers only.

- [ ] **Step 2: Verify render**

Run: `go test ./pkg/operator/ -run TestRenderAllManifests -v 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add manifests/on-prem/0000-frr-k8s.yaml
git commit -m "MCO: make bootstrap frr-k8s static pod FRR-only"
```

### Task 9: Day-2 static pod surgery (master-only, kubeconfig, no metrics, ingress gating)

**Files:**
- Move: `machine-config-operator/templates/common/on-prem/files/{0000-frr-k8s.yaml,0010-kube-vip-api.yaml,0020-kube-vip-ingress.yaml}` → `machine-config-operator/templates/master/00-master/on-prem/files/`
- Delete: `machine-config-operator/templates/arbiter/00-arbiter/on-prem/files/{0000-frr-k8s.yaml,0010-kube-vip-api.yaml,0020-kube-vip-ingress.yaml}` (0-byte overrides now unnecessary — arbiter does not inherit master templates)
- Delete: `machine-config-operator/templates/worker/00-worker/on-prem/files/{frr-k8s-conf.yaml,frr-k8s-peers.yaml}` (workers get the CNO DaemonSet, not the static pod)
- Modify: the three moved files

- [ ] **Step 1: Move/delete files**

```bash
git mv templates/common/on-prem/files/0000-frr-k8s.yaml templates/master/00-master/on-prem/files/
git mv templates/common/on-prem/files/0010-kube-vip-api.yaml templates/master/00-master/on-prem/files/
git mv templates/common/on-prem/files/0020-kube-vip-ingress.yaml templates/master/00-master/on-prem/files/
git rm templates/arbiter/00-arbiter/on-prem/files/0000-frr-k8s.yaml \
      templates/arbiter/00-arbiter/on-prem/files/0010-kube-vip-api.yaml \
      templates/arbiter/00-arbiter/on-prem/files/0020-kube-vip-ingress.yaml
git rm templates/worker/00-worker/on-prem/files/frr-k8s-conf.yaml \
      templates/worker/00-worker/on-prem/files/frr-k8s-peers.yaml
```

Also move the startup files (the static pod is master-only now):

```bash
git mv templates/common/on-prem/files/frr-k8s-startup-daemons.yaml templates/master/00-master/on-prem/files/
git mv templates/common/on-prem/files/frr-k8s-startup-vtysh.yaml templates/master/00-master/on-prem/files/
```

- [ ] **Step 2: Edit `templates/master/00-master/on-prem/files/0000-frr-k8s.yaml`**

- Delete the `frr-metrics` container and the `cp-metrics` init container; delete probes on the `frr` container pointing at port 9141; delete the `metrics-certs` volume and any `metrics` emptyDir mounts left dangling.
- Add to BOTH the `controller` and `frr-status` containers:

```yaml
        env:
        - name: KUBECONFIG
          value: /etc/kubernetes/kubeconfig
```

(merge into existing `env:` lists if present) and add to their `volumeMounts`:

```yaml
        - name: kubeconfig
          mountPath: /etc/kubernetes
          readOnly: true
```

(the `kubeconfig` hostPath volume `/etc/kubernetes` already exists in the pod.)

- [ ] **Step 3: Gate the ingress manifest**

`templates/master/00-master/on-prem/files/0020-kube-vip-ingress.yaml` line 2, replace:

```yaml
path: "/etc/kubernetes/disabled-manifests/0020-kube-vip-ingress.yaml"
```

with:

```yaml
path: {{ if isBGPVIPManagement . }}"/etc/kubernetes/manifests/0020-kube-vip-ingress.yaml"{{ else }}"/etc/kubernetes/disabled-manifests/0020-kube-vip-ingress.yaml"{{ end }}
```

- [ ] **Step 4: Verify all template tests**

Run: `go test ./pkg/controller/template/ ./pkg/operator/ 2>&1 | tail -6`
Expected: PASS. If a test asserts the files exist under common, update the test expectations to master.

- [ ] **Step 5: Commit**

```bash
git add -A templates/
git commit -m "MCO: master-only BGP static pods, controller kubeconfig, drop metrics, activate ingress kube-vip"
```

### Task 10: MCO full verification + image build

- [ ] **Step 1: Full unit tests**

Run: `make test-unit 2>&1 | tail -15` (or `go test ./pkg/... ./cmd/... 2>&1 | tail -15` if make target unavailable)
Expected: PASS.

- [ ] **Step 2: Build and push image**

```bash
podman build -t quay.io/mkowalski/machine-config-operator:bgp-demo -f Dockerfile .
podman push quay.io/mkowalski/machine-config-operator:bgp-demo
```
Expected: image pushed. (If the Dockerfile needs builder-image access, `podman login registry.ci.openshift.org` first.)

---

## Phase 4 — CNO (typed access, schema, RBAC)

Workdir: `/home/kmateusz/git/github.com/cluster-network-operator`, branch `OPNET-595-bgp-vip-management-vendored`.

### Task 11: Typed VIPManagement + schema rename + unit test

**Files:**
- Modify: `cluster-network-operator/pkg/network/bgp_vip.go`
- Create: `cluster-network-operator/pkg/network/bgp_vip_test.go`

- [ ] **Step 1: Write the failing test**

```go
package network

import (
	"encoding/json"
	"testing"

	. "github.com/onsi/gomega"
	uns "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestBuildFRRConfigurationObjects(t *testing.T) {
	g := NewGomegaWithT(t)
	raw := `{"localASN":64512,"defaultPeers":[{"peerAddress":"192.168.111.1","peerASN":64513}],"apiVIPs":["192.168.111.5"],"ingressVIPs":["192.168.111.4"]}`
	var cfg bgpVIPConfigData
	g.Expect(json.Unmarshal([]byte(raw), &cfg)).To(Succeed())
	g.Expect(cfg.DefaultPeers).To(HaveLen(1))

	objs, err := buildFRRConfigurationObjects(cfg)
	g.Expect(err).NotTo(HaveOccurred())
	g.Expect(objs).To(HaveLen(1))
	g.Expect(objs[0].GetName()).To(Equal("bgp-vip-master"))
	routers, found, err := uns.NestedSlice(objs[0].Object, "spec", "bgp", "routers")
	g.Expect(err).NotTo(HaveOccurred())
	g.Expect(found).To(BeTrue())
	g.Expect(routers).To(HaveLen(1))
	neighbors, found, err := uns.NestedSlice(routers[0].(map[string]interface{}), "neighbors")
	g.Expect(err).NotTo(HaveOccurred())
	g.Expect(found).To(BeTrue())
	g.Expect(neighbors).To(HaveLen(1))
}
```

Run: `go test ./pkg/network/ -run TestBuildFRRConfigurationObjects -v`
Expected: FAIL — `cfg.DefaultPeers` undefined (struct still says `Peers` with json tag `peers`).

- [ ] **Step 2: Implement**

In `pkg/network/bgp_vip.go`:

1. Struct changes:

```go
type bgpVIPConfigData struct {
	LocalASN      int64                   `json:"localASN"`
	DefaultPeers  []bgpVIPPeer            `json:"defaultPeers"`
	Communities   []string                `json:"communities,omitempty"`
	APIVIPs       []string                `json:"apiVIPs"`
	IngressVIPs   []string                `json:"ingressVIPs"`
	HostOverrides map[string][]bgpVIPPeer `json:"hostOverrides,omitempty"`
}
```

2. Update `buildFRRConfigurationObjects` to iterate `cfg.DefaultPeers` instead of `cfg.Peers` (all references).
3. Replace the unstructured `isBGPVIPManagement(client)` call in `renderBGPVIPFRRConfiguration` with typed access plus a feature-gate check (delete the `isBGPVIPManagement` function and its imports if now unused). Change the function signature to accept the gates and update the call site in `pkg/network/render.go` (~line 139) to pass `featureGates` (already available in `Render`):

```go
func renderBGPVIPFRRConfiguration(client cnoclient.Client, bootstrapResult *bootstrap.BootstrapResult, featureGates featuregates.FeatureGate) ([]*uns.Unstructured, error) {
```

with imports `apifeatures "github.com/openshift/api/features"` and `"github.com/openshift/library-go/pkg/operator/configobserver/featuregates"`, and at the top of the function (after the existing nil checks):

```go
	if !featureGates.Enabled(apifeatures.FeatureGateBGPBasedVIPManagement) {
		return nil, nil
	}
	bm := bootstrapResult.Infra.PlatformStatus.BareMetal
	if bm.VIPManagement != "BGP" {
		return nil, nil
	}
```

(`VIPManagement` exists in the vendored `configv1.BareMetalPlatformStatus`; remove the stale comment about it not being vendored. Keep `client` — still used for the ConfigMap read.)

- [ ] **Step 3: Run tests**

Run: `go test ./pkg/network/ -run 'TestBuildFRRConfigurationObjects' -v && go build ./...`
Expected: PASS, build OK.

- [ ] **Step 4: Commit**

```bash
git add pkg/network/bgp_vip.go pkg/network/bgp_vip_test.go
git commit -m "CNO: typed VIPManagement access and runtimecfg-aligned peer schema"
```

### Task 12: RBAC for static pod controller/frr-status

**Files:**
- Create: `cluster-network-operator/bindata/network/frr-k8s/003-static-pod-rbac.yaml`

- [ ] **Step 1: Create the RBAC manifest**

```yaml
# RBAC for the frr-k8s static pod on control plane nodes (BGP VIP management).
# The static pod authenticates with the node kubeconfig; grant the nodes group
# read access to FRRConfigurations and write access to node state CRs.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: frr-k8s-static-pod
rules:
- apiGroups: ["frrk8s.metallb.io"]
  resources: ["frrconfigurations"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["frrk8s.metallb.io"]
  resources: ["frrnodestates", "bgpsessionstates"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["frrk8s.metallb.io"]
  resources: ["frrnodestates/status", "bgpsessionstates/status"]
  verbs: ["get", "update", "patch"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: frr-k8s-static-pod
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: frr-k8s-static-pod
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:nodes
```

**Note:** the exact subject must be verified on the live cluster in Task 18 (`oc --kubeconfig=/etc/kubernetes/kubeconfig auth whoami` on a master). If the identity is not in `system:nodes`, update the subject accordingly and re-commit.

- [ ] **Step 2: Verify render + commit**

```bash
go test ./pkg/network/ 2>&1 | tail -3   # render tests load bindata; must pass
git add bindata/network/frr-k8s/003-static-pod-rbac.yaml
git commit -m "CNO: RBAC for frr-k8s static pod node credentials"
```

### Task 13: CNO image build

- [ ] **Step 1: Build and push**

```bash
podman build -t quay.io/mkowalski/cluster-network-operator:bgp-demo -f Dockerfile .
podman push quay.io/mkowalski/cluster-network-operator:bgp-demo
```

---

## Phase 5 — remaining images + payload

### Task 14: kube-vip and runtimecfg images

- [ ] **Step 1: kube-vip** (workdir `/home/kmateusz/git/github.com/kube-vip`, branch `OPNET-595-bgp-vip-management`)

```bash
podman build -t quay.io/mkowalski/kube-vip:bgp-demo -f Dockerfile.openshift .
podman push quay.io/mkowalski/kube-vip:bgp-demo
```

- [ ] **Step 2: baremetal-runtimecfg** (workdir `/home/kmateusz/git/github.com/baremetal-runtimecfg`, branch `OPNET-595-bgp-vip-management`)

```bash
go test ./... 2>&1 | tail -3   # unit tests for peer resolution must pass first
podman build -t quay.io/mkowalski/baremetal-runtimecfg:bgp-demo -f Dockerfile .
podman push quay.io/mkowalski/baremetal-runtimecfg:bgp-demo
```

### Task 15: Assemble the custom release payload

- [ ] **Step 1: Pick a base nightly**

```bash
BASE_RELEASE=$(curl -s "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/5.0.0-0.nightly/latest" | jq -r .pullSpec)
echo "$BASE_RELEASE"
```

- [ ] **Step 2: Build the payload**

```bash
oc adm release new \
  --from-release "$BASE_RELEASE" \
  --name 5.0.0-0.bgpdemo \
  --to-image quay.io/mkowalski/ocp-release:bgp-vip-demo \
  machine-config-operator=quay.io/mkowalski/machine-config-operator:bgp-demo \
  cluster-network-operator=quay.io/mkowalski/cluster-network-operator:bgp-demo \
  baremetal-runtimecfg=quay.io/mkowalski/baremetal-runtimecfg:bgp-demo \
  kube-vip=quay.io/mkowalski/kube-vip:bgp-demo
```

Expected: payload pushed. **Fallback if `kube-vip` (unknown tag) is rejected:** `oc adm release extract --file=image-references "$BASE_RELEASE" > /tmp/image-refs.json`, add a `kube-vip` tag entry, then `oc adm release new --from-image-stream-file=/tmp/image-refs.json ...` with the same overrides.

- [ ] **Step 3: Verify the payload**

```bash
oc adm release info quay.io/mkowalski/ocp-release:bgp-vip-demo | grep -E 'kube-vip|metallb-frr|machine-config-operator|cluster-network-operator|baremetal-runtimecfg'
```
Expected: all five present; the three swapped ones point at quay.io/mkowalski.

---

## Phase 6 — demo environment

### Task 16: ToR helper script

**Files:**
- Create: `bgp-vip-demo/tor/frr.conf`, `bgp-vip-demo/tor/daemons`, `bgp-vip-demo/bgp-tor.sh`

Workdir: `/home/kmateusz/git/github.com/bgp-vip-demo`.

- [ ] **Step 1: FRR config** — `tor/frr.conf`:

```
frr defaults traditional
hostname bgp-tor
log stdout informational
!
router bgp 64513
 bgp router-id 192.168.111.1
 bgp log-neighbor-changes
 neighbor CLUSTER peer-group
 neighbor CLUSTER remote-as 64512
 bgp listen range 192.168.111.0/24 peer-group CLUSTER
 !
 address-family ipv4 unicast
  neighbor CLUSTER activate
 exit-address-family
!
```

`tor/daemons`:

```
zebra=yes
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no

vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
```

- [ ] **Step 2: Helper script** — `bgp-tor.sh`:

```bash
#!/bin/bash
# Manage the FRR ToR container for the BGP VIP demo.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=bgp-tor
IMAGE=quay.io/frrouting/frr:9.1.0

case "${1:-}" in
up)
  sudo firewall-cmd --zone=libvirt --add-port=179/tcp --permanent
  sudo firewall-cmd --reload
  sudo podman run -d --name "$NAME" --net host --privileged \
    -v "$DIR/tor/frr.conf:/etc/frr/frr.conf:z" \
    -v "$DIR/tor/daemons:/etc/frr/daemons:z" \
    "$IMAGE"
  echo "ToR up. BGP listening on 192.168.111.1:179 (host network)."
  ;;
down)
  sudo podman rm -f "$NAME" || true
  sudo firewall-cmd --zone=libvirt --remove-port=179/tcp --permanent
  sudo firewall-cmd --reload
  ;;
status)
  sudo podman exec "$NAME" vtysh -c "show bgp summary"
  sudo podman exec "$NAME" vtysh -c "show ip bgp"
  ip route show proto bgp || true
  ;;
*)
  echo "usage: $0 up|down|status" >&2; exit 1 ;;
esac
```

```bash
chmod +x bgp-tor.sh
```

- [ ] **Step 3: Commit**

```bash
git add tor/ bgp-tor.sh && git commit -m "demo: FRR ToR container helper"
```

### Task 17: dev-scripts configuration + install

**Files:**
- Modify: dev-scripts `config_$USER.sh` (user's local config)
- Modify (after `make install_config`): `dev-scripts/ocp/ostest/install-config.yaml` and `install-config.yaml.save`

- [ ] **Step 1: dev-scripts config** — ensure in `config_$USER.sh`:

```bash
export OPENSHIFT_RELEASE_IMAGE=quay.io/mkowalski/ocp-release:bgp-vip-demo
export KNI_INSTALL_FROM_GIT=true
export OPENSHIFT_INSTALL_PATH=/home/kmateusz/git/github.com/installer   # branch OPNET-595-bgp-vip-management-vendored checked out
export FEATURE_SET=DevPreviewNoUpgrade
export NUM_WORKERS=0
export NUM_MASTERS=3
export IP_STACK=v4
```

Personal pull secret must contain quay.io/mkowalski credentials (it is a public/personal registry — verify `podman pull` of the payload works unauthenticated or add creds to `pull_secret.json`).

- [ ] **Step 2: Start the ToR, generate install-config**

```bash
/home/kmateusz/git/github.com/bgp-vip-demo/bgp-tor.sh up
cd /home/kmateusz/git/github.com/dev-scripts
make requirements host configure   # if not already provisioned
make install_config
```

- [ ] **Step 3: Inject bgpVIPConfig**

Edit BOTH `ocp/ostest/install-config.yaml` and `ocp/ostest/install-config.yaml.save`, adding under `platform.baremetal:`:

```yaml
    bgpVIPConfig:
      localASN: 64512
      peers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
```

Verify `featureSet: DevPreviewNoUpgrade` is present at top level (emitted by `FEATURE_SET`).

- [ ] **Step 4: Run the install**

```bash
make ocp_run 2>&1 | tee /tmp/bgp-demo-install.log
```

Expected: install proceeds past bootstrap. This is the first full integration test — treat failures as findings, not surprises (see Task 18 checks to debug).

### Task 18: Demo verification

Run each check; record results in `bgp-vip-demo/docs/demo-results.md`.

- [ ] **Check 1 — bootstrap advertises API VIP:** during bootstrap:
  `ssh core@192.168.111.9 sudo ip route show table 198` → API VIP `/32` present;
  `./bgp-tor.sh status` → VIP prefix with next-hop 192.168.111.9; `sudo podman ps` on bootstrap shows `frr` container running.
- [ ] **Check 2 — RBAC identity (feeds Task 12 note):** on a master:
  `oc --kubeconfig=/etc/kubernetes/kubeconfig auth whoami` → record user/groups; adjust the CNO ClusterRoleBinding subject if not `system:nodes`. Also verify `label-node`: `oc get node <master> -o jsonpath='{.metadata.labels}' | grep frr-k8s-static-pod`; if NodeRestriction denied it, record and switch CNO anti-affinity to `node-role.kubernetes.io/master` (spec risk fallback).
- [ ] **Check 3 — pivot:** after bootstrap teardown, `./bgp-tor.sh status` shows the VIP next-hop moved to a master IP.
- [ ] **Check 4 — install completes:** `make ocp_run` exits 0; `oc get co` all Available.
- [ ] **Check 5 — ingress VIP:** `oc get pods -n openshift-ingress -o wide` (routers on masters); ToR shows ingress VIP `/32`; `curl -k https://console-openshift-console.apps.ostest.test.metalkube.org` works from the hypervisor; `ip route get 192.168.111.4` shows `proto bgp`.
- [ ] **Check 6 — handover:** `oc get frrconfiguration -n openshift-frr-k8s` → `bgp-vip-master` exists; `oc get bgpsessionstates -n openshift-frr-k8s` → Established; frr-k8s static pod `controller` container logs show config applied; ToR sessions did not flap permanently (re-establishment acceptable).
- [ ] **Check 7 — BGP path proof:** `ip route get 192.168.111.5` on hypervisor → via BGP next-hop (proto bgp), not the connected /24.
- [ ] **Record results + commit:**

```bash
cd /home/kmateusz/git/github.com/bgp-vip-demo
git add docs/demo-results.md && git commit -m "demo: record verification results"
```

---

## Execution notes

- Tasks 1–2 (installer), 3 (api), 11–12 (CNO), 14 (kube-vip/runtimecfg builds) are parallelizable. Tasks 4–10 (MCO) are sequential and depend on Task 3. Task 15 depends on 10, 13, 14. Tasks 16–18 depend on 15.
- Every code task ends with the repo's unit tests passing — do not proceed to the next phase with red tests.
- Expect Task 17/18 to loop back into Phases 3–4 fixes (first live integration). Re-run: rebuild affected image → `oc adm release new` (Task 15 Step 2) → `make clean_cluster; make ocp_run` (or full `make clean` if bootstrap assets changed).
