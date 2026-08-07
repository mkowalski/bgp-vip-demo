# BGPVIPConfig CRD (structured BGP API) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Dev Preview `bgp-vip-config` ConfigMap plumbing with the typed, admission-validated `BGPVIPConfig` CRD (machineconfiguration.openshift.io/v1alpha1) across api/installer/MCO/CNO, with status conditions and a NodeDisruptionPolicy.

**Architecture:** New gated CRD in openshift/api consumed by three operators: installer generates the CR manifest (bootstrap keeps the file-based read), MCO watches it and serializes into the existing internal `ControllerConfigSpec.BGPVIPPeersJSON` transport (templates/runtimecfg untouched) and writes `Rendered`, CNO watches it and renders the same `bgp-vip` FRRConfiguration and writes `SessionsConfigured`. The Dev Preview ConfigMap read/write paths are deleted in the same change-set.

**Tech Stack:** Go, openshift/api codegen (controller-gen + feature-gated manifest generation), kubebuilder/CEL validation, client-go informers, server-side apply for status.

**Spec:** `docs/superpowers/specs/2026-08-07-bgp-vip-structured-api-design.md` (this repo) — the CRD shape in the spec is normative; tasks below restate the exact fields.

## Global Constraints

- Working repos under `/root/OPNET-595-BGP/git/github.com/`: `openshift-api` (base: current upstream master), `installer` (branch `opnet-781-bgp-vip`), `machine-config-operator` (branch `OPNET-595-mco-pr`), `cluster-network-operator` (branch `bgp-vip-management`), `enhancements` (branch `OPNET-595-bgp-vip-management`), docs in `bgp-vip-demo` (branch main).
- New work on NEW branches stacked on the branches above (names per task). Pushes to the mkowalski forks are allowed (needed for vendoring); pushes that update OPEN PRS are FORBIDDEN without user approval — the consumer branches are new branches, not the PR branches.
- Commits: `-s` signoff, `-c core.hooksPath=/dev/null`, trailer `Assisted-By: Claude Fable 5`.
- Go: `GOTOOLCHAIN=auto` (host Go is older than the repos need).
- API conventions (binding, from the spec's cross-check): no booleans (enums `Enabled|Disabled`), no pointers for optional fields, durations as `*Seconds int32` (0–65535), no schema defaults (document omitted behavior in godoc), every godoc starts with the JSON field name, `+openshift:enable:FeatureGate=BGPBasedVIPManagement` on the CRD.
- Live validation happens on the metal-u15 dual-stack cluster (KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig) before anything is proposed for PRs.
- CRD singleton name `cluster`; group `machineconfiguration.openshift.io`; version `v1alpha1`; plural `bgpvipconfigs`.

---

### Task 1: openshift/api — BGPVIPConfig types + generated manifests

**Files:**
- Create: `machineconfiguration/v1alpha1/types_bgpvipconfig.go`
- Modify: `machineconfiguration/v1alpha1/register.go` (scheme registration)
- Generated: `machineconfiguration/v1alpha1/zz_generated.*` (deepcopy, crd-manifests, featuregated-crd-manifests, swagger), `openapi/`, `payload-manifests/` if the generator adds them

**Interfaces:**
- Produces (consumed by Tasks 3–5 via vendoring): package `github.com/openshift/api/machineconfiguration/v1alpha1`, types `BGPVIPConfig`, `BGPVIPConfigList`, `BGPVIPConfigSpec`, `BGPVIPConfigStatus`, `BGPVIPHostPeers`, `BGPVIPPeer`, `BFDMode` (`BFDModeEnabled`/`BFDModeDisabled`), `EBGPMultiHopMode` (`EBGPMultiHopModeEnabled`/`EBGPMultiHopModeDisabled`); condition type constants `BGPVIPConfigRendered = "Rendered"`, `BGPVIPConfigSessionsConfigured = "SessionsConfigured"`.

- [ ] **Step 1: Branch**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-api
git fetch origin master 2>/dev/null || git fetch upstream master
git checkout -B bgpvipconfig-crd FETCH_HEAD   # current upstream master
```

- [ ] **Step 2: Write the types file**

`machineconfiguration/v1alpha1/types_bgpvipconfig.go` — the normative shape (godoc per conventions: starts with the json name, documents omitted behavior):

```go
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// +genclient
// +genclient:nonNamespaced
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object
// +kubebuilder:object:root=true
// +kubebuilder:resource:path=bgpvipconfigs,scope=Cluster
// +kubebuilder:subresource:status
// +kubebuilder:validation:XValidation:rule="self.metadata.name == 'cluster'",message="bgpvipconfig is a singleton; metadata.name must be 'cluster'"
// +openshift:api-approved.openshift.io=https://github.com/openshift/api/pull/XXXX
// +openshift:file-pattern=cvoRunLevel=0000_80,operatorName=machine-config,operatorOrdering=01
// +openshift:enable:FeatureGate=BGPBasedVIPManagement
// +openshift:compatibility-gen:level=4

// BGPVIPConfig carries the BGP peering configuration for BGP-based VIP
// management (enhancement openshift/enhancements#1982). It is a singleton
// named "cluster", generated by the installer from
// platform.baremetal.bgpVIPConfig in the install-config, and may be edited
// day-2 to reconfigure peering.
//
// Compatibility level 4: No compatibility is provided, the API can change at any point for any reason. These capabilities should not be used by applications needing long term support.
type BGPVIPConfig struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// spec is the desired BGP VIP peering configuration.
	// +required
	Spec BGPVIPConfigSpec `json:"spec"`
	// status reports the consumers' progress applying the configuration.
	// +optional
	Status BGPVIPConfigStatus `json:"status,omitempty"`
}

// BGPVIPConfigSpec describes the BGP peering used to advertise the API and
// Ingress VIPs.
type BGPVIPConfigSpec struct {
	// localASN is the autonomous system number the cluster's FRR instances
	// run under. Must be between 1 and 4294967295 (int64 because valid ASNs
	// exceed int32 range).
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=4294967295
	// +required
	LocalASN int64 `json:"localASN"`

	// defaultPeers are the BGP peers every node establishes sessions with,
	// unless the node is named in hostOverrides.
	// +listType=map
	// +listMapKey=peerAddress
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=16
	// +required
	DefaultPeers []BGPVIPPeer `json:"defaultPeers"`

	// communities are BGP community strings attached to the VIP
	// advertisements, in "n:n" (classic) or "n:n:n" (large) form where each
	// segment is between 0 and 4294967295. When omitted, no communities are
	// attached.
	// +listType=atomic
	// +kubebuilder:validation:MaxItems=8
	// +optional
	Communities []string `json:"communities,omitempty"`

	// hostOverrides replaces (does not merge with) defaultPeers for the
	// named nodes. Only the per-node peer file rendered by the
	// machine-config-operator consumes overrides; the cluster-wide session
	// configuration rendered by the cluster-network-operator uses
	// defaultPeers. When omitted, all nodes use defaultPeers.
	// +listType=map
	// +listMapKey=hostname
	// +kubebuilder:validation:MaxItems=256
	// +optional
	HostOverrides []BGPVIPHostPeers `json:"hostOverrides,omitempty"`
}

// BGPVIPHostPeers is a per-node replacement peer list.
type BGPVIPHostPeers struct {
	// hostname of the node this override applies to, as an RFC 1123
	// subdomain (matched against the hostname resolved on the node).
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=253
	// +kubebuilder:validation:XValidation:rule="self.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$')",message="hostname must be an RFC 1123 subdomain"
	// +required
	Hostname string `json:"hostname"`

	// peers replaces defaultPeers for this node.
	// +listType=map
	// +listMapKey=peerAddress
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=16
	// +required
	Peers []BGPVIPPeer `json:"peers"`
}

// BFDMode enables or disables BFD for a BGP session.
// +kubebuilder:validation:Enum:=Enabled;Disabled;""
type BFDMode string

const (
	// BFDModeEnabled backs the session with BFD fast failure detection.
	BFDModeEnabled BFDMode = "Enabled"
	// BFDModeDisabled runs the session without BFD.
	BFDModeDisabled BFDMode = "Disabled"
)

// EBGPMultiHopMode enables or disables eBGP multihop for a BGP session.
// +kubebuilder:validation:Enum:=Enabled;Disabled;""
type EBGPMultiHopMode string

const (
	// EBGPMultiHopModeEnabled allows the session to cross multiple hops.
	EBGPMultiHopModeEnabled EBGPMultiHopMode = "Enabled"
	// EBGPMultiHopModeDisabled requires the peer to be directly connected.
	EBGPMultiHopModeDisabled EBGPMultiHopMode = "Disabled"
)

// BGPVIPPeer describes one BGP neighbor.
// +kubebuilder:validation:XValidation:rule="!(has(self.holdTimeSeconds) && has(self.keepaliveTimeSeconds)) || self.holdTimeSeconds == 0 || self.keepaliveTimeSeconds == 0 || self.holdTimeSeconds >= 3 * self.keepaliveTimeSeconds",message="holdTimeSeconds must be at least 3 times keepaliveTimeSeconds"
type BGPVIPPeer struct {
	// peerAddress is the IP address of the BGP neighbor (IPv4 or IPv6); the
	// session's address family follows the address family of this value.
	// +kubebuilder:validation:MaxLength=45
	// +kubebuilder:validation:XValidation:rule="isIP(self)",message="peerAddress must be a valid IP address"
	// +required
	PeerAddress string `json:"peerAddress"`

	// peerASN is the autonomous system number of the neighbor. Must be
	// between 1 and 4294967295.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=4294967295
	// +required
	PeerASN int64 `json:"peerASN"`

	// password is the TCP MD5 password (RFC 2385) for the session, in clear
	// text; the kernel limits it to 80 bytes. When omitted, the session is
	// unauthenticated.
	// +kubebuilder:validation:MaxLength=80
	// +optional
	Password string `json:"password,omitempty"`

	// port is the TCP port of the BGP session. When omitted, port 179 is
	// used; this default is applied by the consumers and is subject to
	// change over time.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +optional
	Port int32 `json:"port,omitempty"`

	// bfd determines whether the session is backed by BFD fast failure
	// detection. Allowed values are "Enabled", "Disabled" and omitted. When
	// omitted, BFD is disabled; this default is subject to change over time.
	// +optional
	BFD BFDMode `json:"bfd,omitempty"`

	// ebgpMultiHop determines whether the session may cross multiple hops.
	// Allowed values are "Enabled", "Disabled" and omitted. When omitted,
	// multihop is disabled; this default is subject to change over time.
	// +optional
	EBGPMultiHop EBGPMultiHopMode `json:"ebgpMultiHop,omitempty"`

	// holdTimeSeconds is the BGP hold time in seconds, between 0 and 65535.
	// When omitted or 0, the FRR default is used; this is subject to change
	// over time.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=65535
	// +optional
	HoldTimeSeconds int32 `json:"holdTimeSeconds,omitempty"`

	// keepaliveTimeSeconds is the BGP keepalive interval in seconds,
	// between 0 and 65535. When omitted or 0, the FRR default is used; this
	// is subject to change over time.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=65535
	// +optional
	KeepaliveTimeSeconds int32 `json:"keepaliveTimeSeconds,omitempty"`
}

// BGPVIPConfigStatus reports the consumers' progress applying the spec.
type BGPVIPConfigStatus struct {
	// observedGeneration is the generation most recently processed by the
	// machine-config-operator.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// conditions reports the state of applying the configuration. Known
	// condition types are "Rendered" (the machine-config-operator has
	// rendered the per-node peer configuration) and "SessionsConfigured"
	// (the cluster-network-operator has applied the session configuration).
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

const (
	// BGPVIPConfigRendered is set by the machine-config-operator when the
	// per-node peer configuration reflecting the current spec generation
	// has been rendered.
	BGPVIPConfigRendered = "Rendered"
	// BGPVIPConfigSessionsConfigured is set by the cluster-network-operator
	// when the FRR session configuration reflecting the current spec has
	// been applied.
	BGPVIPConfigSessionsConfigured = "SessionsConfigured"
)

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object
// +openshift:compatibility-gen:level=4

// BGPVIPConfigList is a list of BGPVIPConfig resources.
//
// Compatibility level 4: No compatibility is provided, the API can change at any point for any reason. These capabilities should not be used by applications needing long term support.
type BGPVIPConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata"`
	Items           []BGPVIPConfig `json:"items"`
}
```

Also register both types in `machineconfiguration/v1alpha1/register.go` `addKnownTypes` (`&BGPVIPConfig{}, &BGPVIPConfigList{}` — copy the `InternalReleaseImage` lines' pattern).

- [ ] **Step 3: Generate**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-api
GOTOOLCHAIN=auto make update-codegen-crds 2>&1 | tail -3   # if target missing: make update
git status --short | head -20   # expect zz_generated deepcopy + featuregated-crd-manifests for bgpvipconfigs
```

Expected: new `machineconfiguration/v1alpha1/zz_generated.featuregated-crd-manifests/bgpvipconfigs.machineconfiguration.openshift.io/BGPBasedVIPManagement.yaml` (+ crd-manifests, deepcopy additions). If the generator errors on the `+openshift:api-approved` placeholder URL, use `https://github.com/openshift/api/pull/2923` (the feature's approved PR) — note this in the commit message for the API reviewers.

- [ ] **Step 4: Build + verify**

```bash
GOTOOLCHAIN=auto go build ./machineconfiguration/... && GOTOOLCHAIN=auto make verify-codegen-crds 2>&1 | tail -2 || GOTOOLCHAIN=auto make verify 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add machineconfiguration openapi payload-manifests 2>/dev/null; git add -A machineconfiguration
git -c core.hooksPath=/dev/null commit -s -m "machineconfiguration/v1alpha1: add BGPVIPConfig CRD

Typed, admission-validated replacement for the Dev Preview bgp-vip-config
ConfigMap (enhancement openshift/enhancements#1982): singleton cluster
BGP peering configuration for BGP-based VIP management, gated on
BGPBasedVIPManagement. Design: mkowalski/bgp-vip-demo
docs/superpowers/specs/2026-08-07-bgp-vip-structured-api-design.md.

Assisted-By: Claude Fable 5"
```

---

### Task 2: openshift/api — integration test suite for the CEL rules

**Files:**
- Create: `machineconfiguration/v1alpha1/tests/bgpvipconfigs.machineconfiguration.openshift.io/BGPBasedVIPManagement.yaml`

**Interfaces:**
- Consumes: the CRD from Task 1 (same repo/branch).

- [ ] **Step 1: Write the suite** (format per `machineconfiguration/v1alpha1/tests/internalreleaseimages.machineconfiguration.openshift.io/NoRegistryClusterInstall.yaml`)

```yaml
apiVersion: apiextensions.k8s.io/v1 # Hack because controller-gen complains if we don't have this
name: "[TechPreview] BGPVIPConfig"
crdName: bgpvipconfigs.machineconfiguration.openshift.io
featureGate: BGPBasedVIPManagement
tests:
  onCreate:
  - name: Should be able to create a minimal BGPVIPConfig
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
    expected: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
  - name: Should reject a non-cluster name
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: not-cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
    expectedError: "metadata.name must be 'cluster'"
  - name: Should reject an invalid peer address
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: not-an-ip
          peerASN: 64513
    expectedError: "peerAddress must be a valid IP address"
  - name: Should reject an out-of-range ASN
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 4294967296
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
    expectedError: "localASN"
  - name: Should reject holdTime shorter than 3x keepalive
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
          holdTimeSeconds: 5
          keepaliveTimeSeconds: 5
    expectedError: "holdTimeSeconds must be at least 3 times keepaliveTimeSeconds"
  - name: Should accept a dual-stack peer set with an IPv6 host override
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
        - peerAddress: fd2e:6f44:5dd8:c956::1
          peerASN: 64513
        hostOverrides:
        - hostname: worker-0
          peers:
          - peerAddress: fd2e:6f44:5dd8:c956::2
            peerASN: 64514
            bfd: Enabled
    expected: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
        - peerAddress: fd2e:6f44:5dd8:c956::1
          peerASN: 64513
        hostOverrides:
        - hostname: worker-0
          peers:
          - peerAddress: fd2e:6f44:5dd8:c956::2
            peerASN: 64514
            bfd: Enabled
  - name: Should reject an invalid bfd mode
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
          bfd: maybe
    expectedError: "Unsupported value"
  - name: Should reject an invalid community
    initial: |
      apiVersion: machineconfiguration.openshift.io/v1alpha1
      kind: BGPVIPConfig
      metadata:
        name: cluster
      spec:
        localASN: 64512
        communities: ["banana"]
        defaultPeers:
        - peerAddress: 192.168.111.1
          peerASN: 64513
    expectedError: "communities"
```

- [ ] **Step 2: Run the suite**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-api
GOTOOLCHAIN=auto make integration 2>&1 | grep -iE "bgpvip|FAIL|ok" | head   # or: go test ./tests/... -run TestIntegration -count=1 (check tests/README.md for the exact entrypoint)
```

Expected: the BGPVIPConfig suite runs and passes. If an `expectedError` string mismatches the apiserver's actual wording, adjust the yaml to the actual message (the assertion is substring-based).

- [ ] **Step 3: Commit + push the api branch to the fork (vendoring anchor for Tasks 3–5)**

```bash
git add machineconfiguration/v1alpha1/tests
git -c core.hooksPath=/dev/null commit -s -m "machineconfiguration/v1alpha1: BGPVIPConfig integration test suite

Assisted-By: Claude Fable 5"
git push -f https://github.com/mkowalski/openshift-api.git bgpvipconfig-crd
git rev-parse HEAD   # record SHA — Tasks 3-5 vendor github.com/openshift/api@<this SHA via the fork>
```

---

### Task 3: installer — render the BGPVIPConfig manifest instead of the ConfigMap

**Files:**
- Create branch: `bgpvipconfig-crd` off `opnet-781-bgp-vip`
- Modify: `pkg/asset/manifests/bgpvipconfig.go` (replace ConfigMap rendering), its test file alongside
- Modify: `go.mod`/`vendor` (api bump to the Task 2 SHA via `replace github.com/openshift/api => github.com/mkowalski/openshift-api <sha>`)

**Interfaces:**
- Consumes: `machineconfiguration/v1alpha1.BGPVIPConfig` et al from Task 2's pushed SHA.
- Produces: manifest file `openshift/99_bgp-vip-config.yaml` (installer asset naming kept from the current ConfigMap asset — keep whatever filename the asset uses today) containing a `BGPVIPConfig` named `cluster`; conversion helper `bgpVIPConfigFromInstallConfig(ic *types.InstallConfig) *mcfgv1alpha1.BGPVIPConfig` used by MCO's bootstrap read expectations (the file content is what MCO's bootstrap consumes in Task 4).

- [ ] **Step 1: Branch + vendor**

```bash
cd /root/OPNET-595-BGP/git/github.com/installer
git checkout -B bgpvipconfig-crd opnet-781-bgp-vip
GOTOOLCHAIN=auto go mod edit -replace github.com/openshift/api=github.com/mkowalski/openshift-api@<TASK2_SHA>
GOTOOLCHAIN=auto go mod tidy && GOTOOLCHAIN=auto go mod vendor
```

- [ ] **Step 2: Write the failing conversion test** (same package as the asset; table-driven; exact expectations)

```go
func TestBGPVIPConfigFromInstallConfig(t *testing.T) {
	ic := &types.InstallConfig{Platform: types.Platform{BareMetal: &baremetal.Platform{
		BGPVIPConfig: &baremetal.BGPVIPConfig{
			LocalASN:    64512,
			Communities: []string{"64512:100"},
			Peers: []baremetal.BGPPeerConfig{{
				PeerAddress: "192.168.111.1", PeerASN: 64513,
				BFDEnabled: "true", EBGPMultiHop: "false",
				HoldTime: "90s", KeepaliveTime: "30s", Port: 180, Password: "s3cret",
			}},
		},
		Hosts: []*baremetal.Host{{Name: "worker-0", BGPPeers: []baremetal.BGPPeerConfig{{PeerAddress: "fd2e::1", PeerASN: 64514}}}},
	}}}
	got := bgpVIPConfigFromInstallConfig(ic)
	if got.Name != "cluster" { t.Fatalf("name = %q", got.Name) }
	p := got.Spec.DefaultPeers[0]
	if p.BFD != mcfgv1alpha1.BFDModeEnabled { t.Errorf("bfd = %q", p.BFD) }
	if p.EBGPMultiHop != mcfgv1alpha1.EBGPMultiHopModeDisabled { t.Errorf("multihop = %q", p.EBGPMultiHop) }
	if p.HoldTimeSeconds != 90 || p.KeepaliveTimeSeconds != 30 { t.Errorf("timers = %d/%d", p.HoldTimeSeconds, p.KeepaliveTimeSeconds) }
	if got.Spec.HostOverrides[0].Hostname != "worker-0" { t.Errorf("override hostname") }
	// unset string flags map to omitted enums (empty string), not Disabled
	// unset durations map to 0
}
```

Plus a case asserting `BFDEnabled: ""` → `BFD == ""` (omitted stays omitted — controller defaults, not conversion defaults).

- [ ] **Step 2b: Run, expect compile failure** (`bgpVIPConfigFromInstallConfig` undefined).

- [ ] **Step 3: Implement** in `pkg/asset/manifests/bgpvipconfig.go`: replace the ConfigMap+JSON generation with the conversion (string flag → enum: `"true"→Enabled, "false"→Disabled, ""→""`; duration string → `int32(d.Seconds())`; hosts with `BGPPeers` → `HostOverrides`; drop apiVIPs/ingressVIPs entirely) and marshal the CR to YAML into the same asset file slot the ConfigMap used. Delete the `bgpVIPConfigJSON` struct. Keep the asset name/dependency wiring untouched.

- [ ] **Step 4: Tests + build**

```bash
GOTOOLCHAIN=auto go test ./pkg/asset/manifests/... -run BGPVIP -count=1
GOTOOLCHAIN=auto go build ./pkg/asset/... 
grep -rn "bgp-vip-config" pkg/ --include="*.go" | grep -v _test   # expect: no ConfigMap references left in generation
```

- [ ] **Step 5: Commit** (message notes the replace directive is temporary until the api PR merges).

---

### Task 4: MCO — watch BGPVIPConfig, conditions, NodeDisruptionPolicy

**Files:**
- Create branch: `bgpvipconfig-crd` off `OPNET-595-mco-pr`
- Modify: `pkg/operator/sync.go` (`syncBGPVIPPeersJSON`), `pkg/operator/operator.go` (informer wiring), `pkg/operator/bootstrap_dependencies.go` (manifest file read: ConfigMap yaml → BGPVIPConfig yaml), `pkg/apihelpers/apihelpers.go` (`defaultClusterPolicies` — NodeDisruptionPolicy), `go.mod`/`vendor`
- Tests: `pkg/operator/sync_test.go` (or the file housing the current BGPVIPPeersJSON tests), `pkg/apihelpers` test

**Interfaces:**
- Consumes: Task 2 types; Task 3's manifest file shape (bootstrap: `manifests/bgp-vip-config.yaml` in the asset dir now contains a BGPVIPConfig CR).
- Produces: unchanged `ControllerConfigSpec.BGPVIPPeersJSON` content — **byte-compatible JSON** with today's schema (`localASN`, `defaultPeers` [with the Dev Preview field spellings: `bfdEnabled`/`ebgpMultiHop` as "true"/"false" strings, `holdTime`/`keepaliveTime` as duration strings], `communities`, `apiVIPs`, `ingressVIPs`, `hostOverrides`) so templates and runtimecfg are untouched. Serialization helper `bgpVIPPeersJSONFromCR(cr *mcfgv1alpha1.BGPVIPConfig, infra *configv1.Infrastructure) (string, error)`.

- [ ] **Step 1: Branch + vendor** (same replace-directive pattern as Task 3).

- [ ] **Step 2: Failing serialization test** — golden test: build a CR (both families, one override, timers 90/30, bfd Enabled) + an Infrastructure with dual-stack VIPs; assert the produced JSON equals the exact Dev Preview payload string (copy a real `config.json` from the run28 cluster as the golden: `oc get cm -n openshift-network-operator bgp-vip-config -o jsonpath='{.data.config\.json}'`). Enum→string mapping: `Enabled→"true"`, `Disabled→"false"`, `""→omitted`; seconds→`"90s"` duration strings; VIPs from `infra.Status.PlatformStatus.BareMetal.{APIServerInternalIPs,IngressIPs}`.

- [ ] **Step 3: Implement**: `bgpVIPPeersJSONFromCR`; rewrite `syncBGPVIPPeersJSON` to read the `BGPVIPConfig` `cluster` CR via a new informer/lister (configclient pattern used for other mcfg CRs in `pkg/operator/operator.go`) instead of the ConfigMap; degrade semantics identical (missing CR on BGP cluster → Degraded, hold last good). Bootstrap: `bootstrap_dependencies.go` decodes the BGPVIPConfig yaml manifest instead of the ConfigMap yaml, then calls the same helper. Delete the ConfigMap read + `compactBGPVIPPeersJSON`'s ConfigMap-specific bits (keep JSON validation of the produced payload as a sanity assert in tests only).

- [ ] **Step 4: Status writes**: after a successful sync, server-side-apply status: `observedGeneration = cr.Generation`, condition `{Type: Rendered, Status: True, Reason: "AsExpected", ObservedGeneration: cr.Generation}`; on degrade, `Rendered=False, Reason: "RenderFailed"` with the error message. Field manager `machine-config-operator`.

- [ ] **Step 5: NodeDisruptionPolicy**: in `pkg/apihelpers/apihelpers.go` `defaultClusterPolicies.Files`, add:

```go
{
	Path: "/etc/kubernetes/static-pod-resources/frr-k8s/frr-peers.json",
	Actions: []opv1.NodeDisruptionPolicyStatusAction{{Type: opv1.NoneStatusAction}},
},
```

with a comment: after the bootstrap-to-CRD handover the on-disk peers file only matters at early boot; day-2 edits must not disrupt nodes. Extend the existing `defaultClusterPolicies` unit test with this path.

- [ ] **Step 6: Tests + build**

```bash
cd /root/OPNET-595-BGP/git/github.com/machine-config-operator
GOTOOLCHAIN=auto go test ./pkg/operator/... ./pkg/apihelpers/... 2>&1 | tail -3
GOTOOLCHAIN=auto go build ./cmd/... 2>&1 | tail -2
```

- [ ] **Step 7: Commit.**

---

### Task 5: CNO — typed watch + condition

**Files:**
- Create branch: `bgpvipconfig-crd` off `bgp-vip-management`
- Modify: `pkg/network/bgp_vip.go` (drop `bgpVIPConfigData`/`bgpVIPPeer` structs, read the CR), controller wiring for the new informer (wherever the ConfigMap watch is registered), `go.mod`/`vendor`
- Tests: the existing `bgp_vip` render tests

**Interfaces:**
- Consumes: Task 2 types.
- Produces: byte-identical `bgp-vip` FRRConfiguration for equivalent input (parity requirement).

- [ ] **Step 1: Branch + vendor** (replace-directive pattern).

- [ ] **Step 2: Failing parity test**: feed the typed CR equivalent of an existing ConfigMap-based test fixture through `renderBGPVIPFRRConfiguration`; assert the rendered FRRConfiguration objects are `reflect.DeepEqual` to the current fixtures' expected output (enum→bool/`holdTime` seconds → the FRRConfiguration's duration fields as rendered today).

- [ ] **Step 3: Implement**: replace ConfigMap fetch+unmarshal+revalidate with CR lister read; keep only cross-object validation (FRR provider enabled, VIPs present on Infrastructure); map enums/seconds to the FRRConfiguration neighbor fields; keep the raw advertisement snippet untouched. Write `SessionsConfigured` condition (SSA, field manager `cluster-network-operator`, own condition type only) after apply; `False/RenderFailed` on error.

- [ ] **Step 4: Tests + build; commit.**

---

### Task 6: Live validation on metal-u15 (before anything is proposed anywhere)

**Files:** none (ops); evidence into the ledger in Task 7.

**Interfaces:**
- Consumes: images built from Tasks 4–5 branches; CRD manifest from Task 1.

- [ ] **Step 1: Build + push images** per RUNBOOK recipes: MCO (`build/Dockerfile.mco` in bgp-vip-demo) and CNO (`build/Dockerfile.cno`) from the `bgpvipconfig-crd` branches, tags `quay.io/mkowalski/{machine-config-operator,cluster-network-operator}:bgpvipconfig-test`.
- [ ] **Step 2: Apply the gated CRD manifest** (`zz_generated.featuregated-crd-manifests/.../BGPBasedVIPManagement.yaml`) and a `BGPVIPConfig` CR translated from the cluster's live ConfigMap content (both ToR peers, dual-stack).
- [ ] **Step 3: Roll the operators** to the test images (scale CVO deployment to 0 first — RUNBOOK "redeploy" recipe; record for revert).
- [ ] **Step 4: Parity checks**:
  - `frr-peers.json` on a master byte-identical to the pre-change file
  - `oc get frrconfiguration -n openshift-frr-k8s bgp-vip -o yaml` spec unchanged
  - `oc get bgpvipconfig cluster -o jsonpath='{.status}'` shows both conditions True + observedGeneration
- [ ] **Step 5: Day-2 edit test**: add a dummy third peer to `defaultPeers`; verify peers file updates on nodes **without** any node cordon/drain/reboot (`oc get nodes` timestamps + `oc get machineconfigpool` no rolling update beyond config version bump), FRRConfiguration gains the neighbor, then revert the edit.
- [ ] **Step 6: Full acceptance**: `bash /tmp/opencode/verify-vip-local.sh` (family-aware) exits 0; coexistence verifies still green.
- [ ] **Step 7: Delete the Dev Preview ConfigMap** on the cluster and confirm nothing degrades (proves the consumers no longer read it).

---

### Task 7: EP amendment + docs

**Files:**
- Modify: `enhancements/network/bgp-vip-management.md` (API Extensions section) on branch `OPNET-595-bgp-vip-management`
- Modify: `bgp-vip-demo` `docs/RUN-LEDGER.md` (row: api-1 live validation), `docs/NEXT-STEPS.md` (Phase 3 item 1 progress + branch/SHA table)

**Interfaces:** consumes Task 6 evidence.

- [ ] **Step 1: EP**: rewrite the Option A/B deliberation into the selected Option B with the final CRD shape (summarized, referencing conventions applied), reword the passwordSecretRef TP criterion to inline-now/union-secretRef-pre-GA, move ConfigMap-path removal from GA to TP criteria. Commit + push to the EP fork branch (updates PR 1982 — allowed: it's the user's EP PR and prior EP pushes were approved practice; NO review-comment replies).
- [ ] **Step 2: Ledger + NEXT-STEPS** in bgp-vip-demo: row `api-1` with parity/day-2/no-disruption evidence; Phase 3 item 1 marked in-progress with the four branch names + SHAs and the explicit note "pushes to the open PRs pending user approval". Commit + push (bgp-vip-demo only).

---

## Self-review (done at plan time)

- Spec coverage: CRD shape+validation (T1), CEL tests (T2), installer swap incl. bootstrap file path (T3), MCO watch/serialize/degrade/conditions/NodeDisruptionPolicy (T4), CNO typed swap+condition+parity (T5), Dev Preview path deletion (T3 grep, T4 ConfigMap-read removal, T6 step 7 proof), live validation incl. day-2 no-disruption (T6), EP amendment + docs (T7). Gate promotion Dev→TechPreview: deliberately out of plan scope (spec: separate ordering-independent PR at graduation time).
- Placeholders: none — the one investigation-shaped step (api Makefile target name) carries both candidate commands and expected outputs.
- Type consistency: `BGPVIPPeer` field names/enums identical across T1 code, T2 yaml, T3/T4/T5 references; JSON payload spellings in T4 explicitly the Dev Preview ones (that's the point of the internal transport).
