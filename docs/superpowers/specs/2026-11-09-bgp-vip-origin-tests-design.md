# Design: `[OCPFeatureGate:BGPBasedVIPManagement]` origin tests and dual-stack lane

Date: 2026-11-09
Status: draft, awaiting Mat's approval (brainstorm on WORK-11, option A picked 2026-11-09)
Jira: OPNET-595 (epic)
Target PRs: openshift/origin (tests and suites), openshift/release (lanes)

## Intent

BGP-based VIP management (enhancements#1982) is moving from Dev Preview to
Tech Preview. The openshift/api promotion PR is with chaibot. The enhancement's
Dev → Tech Preview criteria (lines 1794–1803) ask for at least 5 e2e tests
tagged `[OCPFeatureGate:BGPBasedVIPManagement]`, covering install, failover
and dual-stack, and running at least 7 times a week. The api repo's
`featuregate-test-analyzer` will later grade GA readiness from these same
tests: at least 5 tests, at least 14 runs per variant, 95% pass rate, on the
metal `ipv4`, `ipv6` and `dual` variants.

Today the coverage lives in a bash step (`baremetalds-e2e-bgp-vip-verify`) in
openshift/release. It is not tagged with the gate, isn't visible to Sippy or
Component Readiness, and no lane runs `openshift-tests` against the feature.
This work ports those checks to origin as gate-tagged Ginkgo tests, adds
failover coverage, and adds a daily dual-stack lane that runs them.

## Goals

- At least 5 gate-tagged origin tests, split across two dedicated suites:
  - `openshift/bgp-vip`: non-disruptive, safe next to any other test.
  - `openshift/bgp-vip/disruptive`: cuts one master's BGP session, changes
    global BGP config.
- A new daily dual-stack periodic that runs both suites.
- The existing daily v4 `bgp-vip` lane also runs `openshift/bgp-vip`, so the
  metal `ipv4` and `dual` variants each get 7 runs a week.
- The non-disruptive tests also run as part of `openshift/conformance/*`
  through origin's automatic suite tagging. Any BGP lane that runs conformance
  (today `ovn-bgp-metallb`, `evpn`) reports them as well.

## Non-goals

- An IPv6-only lane. GA will need the `ipv6` variant; that's a separate change.
- Deleting the bash verify step. It stays in the lanes for now, as a
  cross-check while the Go tests settle in. Removing it is a follow-up.
- Bumping origin's vendored openshift/api. It is from 10-13 and lacks the
  `BGPVIPConfig` Go type; the tests read it with the dynamic client.
- Moving the lanes to `FEATURE_SET: TechPreviewNoUpgrade`. That happens once
  the api PR is in a nightly; the lanes in this design start on
  `DevPreviewNoUpgrade` and switch with the others.

## Anti-goals

- Tests that silently pass on non-BGP clusters by asserting nothing useful.
  They must **skip** (with a reason) unless `vipManagement=BGP`.
- Tests that flake on BGP convergence timing. Every check on BGP state polls
  with a bounded timeout (same budget as the bash step: 5 minutes).
- Disruptive behaviour leaking into `openshift/bgp-vip` or
  `openshift/conformance/*`. Anything that can withdraw a VIP path cluster-wide
  is `[Disruptive]`.
- Leaving a cluster broken after a failed disruptive test. Every disruption
  is undone in `DeferCleanup`, and the test waits for full recovery before it ends.

## Approaches considered

| Option | What | Trade-off |
|---|---|---|
| **A. Two dedicated suites (picked)** | `openshift/bgp-vip` (gate tag, not Disruptive) + `openshift/bgp-vip/disruptive` (gate tag + Disruptive, `Parallelism: 1`, `ClusterStabilityDuringTest: Disruptive`). Modeled on `openshift/two-node`. | Two small suites to own; fast lanes (~30–40 min of tests), BGP signal not buried in unrelated failures. |
| B. Reuse existing suites | Add the gate tag to the `openshift/disruptive` qualifier; lane runs `conformance/parallel` then `openshift/disruptive`. | Nothing new to own, but pulls in the etcd/node recovery tests (90-min timeout) and full conformance; slow and noisy (cf. the 6 unrelated failures on `ovn-bgp-metallb` 11-09). |
| C. One suite for both | Single suite holding everything. | A suite has one parallelism and one stability setting, so everything would run serially with relaxed monitors. Rejected. |

Mat picked A on 2026-11-09.

## Decided

### Suites (`pkg/testsuites/standard_suites.go`)

```go
{
    Name: "openshift/bgp-vip",
    Description: templates.LongDesc(`
    Non-disruptive tests for BGP-based VIP management on bare metal.
    `),
    Qualifiers: []string{
        `name.contains("[OCPFeatureGate:BGPBasedVIPManagement]") && !name.contains("[Disruptive]")`,
    },
    TestTimeout: 20 * time.Minute,
},
{
    Name: "openshift/bgp-vip/disruptive",
    Description: templates.LongDesc(`
    Disruptive tests for BGP-based VIP management: cut one control-plane node's
    BGP session, change the cluster-wide BGP peer configuration.
    `),
    Qualifiers: []string{
        `name.contains("[OCPFeatureGate:BGPBasedVIPManagement]") && name.contains("[Disruptive]")`,
    },
    TestTimeout:                30 * time.Minute,
    Parallelism:                1,
    ClusterStabilityDuringTest: ginkgo.Disruptive,
},
```

Whether to wrap the qualifiers in `withStandardEarlyTests` / `withStandardEarlyOrLateTests` follows what `openshift/two-node` and `openshift/network/*` do; builder's call.

Origin's `appendSuiteNames` (`pkg/test/extensions/suites.go`) already skips
`[Disruptive]` tests (via `ExcludedTests`) and tags the rest into
`openshift/conformance/{parallel,serial}`. No change needed there.

### Tests

Location: a new file set under `test/extended/networking/` (`bgp_vip.go`,
`bgp_vip_disruptive.go`, `bgp_vip_util.go`). Every `Describe` carries
`[sig-network][OCPFeatureGate:BGPBasedVIPManagement][Feature:BGPVIPManagement][apigroup:config.openshift.io]`
(plus `[apigroup:machineconfiguration.openshift.io]` where the CR is read).

Common `BeforeEach`: skip unless platform is BareMetal and
`infrastructure.status.platformStatus.baremetal.vipManagement == "BGP"`.

Inputs every test needs, read once per test:

- `BGPVIPConfig/cluster` (`machineconfiguration.openshift.io/v1alpha1`,
  dynamic client): `spec.defaultPeers[]` (`peerAddress`, `peerASN`,
  `failureDetection` `BFD|HoldTimer`, `holdTimeSeconds`,
  `keepaliveTimeSeconds`), `status.conditions`, `status.observedGeneration`.
- `FRRConfiguration/bgp-vip` in `openshift-frr-k8s`: the rendered form the
  node-side FRR actually applies.
- Node-side BGP state: `oc exec -n openshift-frr-k8s frr-k8s-<master> -c frr
  -- vtysh -c '<cmd> json'`. Needs no hypervisor access, so it works in any
  lane, including conformance on other BGP lanes.
- ToR-side BGP state (disruptive suite only): `podman exec bgp-tor vtysh`
  over SSH to the hypervisor, through origin's existing
  `exutil.GetHypervisorConfig()` + `edge_topologies/utils/core` SSH helpers.
  Tests that need it carry `[Requires:HypervisorSSHConfig]`, so origin skips
  them when the lane doesn't pass `--with-hypervisor-json`.

#### `openshift/bgp-vip` (non-disruptive), 5 tests

| # | Test (It text, abbreviated) | Ported from | Asserts |
|---|---|---|---|
| 1 | BGPVIPConfig is accepted and applied | verify [1/6] + new | CRD `bgpvipconfigs.machineconfiguration.openshift.io` exists; `BGPVIPConfig/cluster` has `Rendered=True` and `SessionsConfigured=True`, with `status.observedGeneration == metadata.generation`; Infrastructure says `BGP`. |
| 2 | control plane runs frr-k8s instead of keepalived | verify [2/6], [3/6] | Pod `frr-k8s-<node>` Ready on every master; no pod named `*keepalived*` in any namespace. |
| 3 | every master has an Established session to every declared peer with the configured timers and BFD | verify [4/6], moved node-side | For each master × each `defaultPeers` entry: `show bgp neighbors <peer> json` → `bgpState == Established`; negotiated `bgpTimerHoldTimeMsecs` / `bgpTimerKeepAliveIntervalMsecs` match the CR (or the rendered FRRConfiguration value when the CR leaves them unset); BFD `Up` iff `failureDetection == BFD`. Polled, 5 min. |
| 4 | API and ingress VIPs are advertised per address family | verify [5/6], moved node-side; dual-stack coverage | For every family the CR declares a peer in: every master advertises each API VIP of that family (`/32` or `/128`) to that peer (`show bgp <af> unicast neighbors <peer> advertised-routes json`); every node hosting a Ready default router pod advertises each ingress VIP of that family. A VIP family with no peer of that family is skipped with a log line. Fails on a dual-stack cluster with peers in both families if either family is missing. |
| 5 | ingress VIP follows the router pods `[Serial]` | new | Pick a node hosting a router pod; cordon it, delete that router pod; poll: the node stops advertising the ingress VIP(s) while at least one other node still advertises them; uncordon (DeferCleanup), wait for the router deployment to be fully available and advertisement to be back on a router node. |

Test 5 is `[Serial]` because it moves router pods, which other parallel tests
rely on. It is not `[Disruptive]`: the ingress VIP stays advertised from the
other router node(s) throughout. It lands in `conformance/serial` too.

#### `openshift/bgp-vip/disruptive`, 2 tests

| # | Test | Asserts |
|---|---|---|
| 6 | API VIP stays reachable when one master loses its BGP session `[Disruptive][Serial][Requires:HypervisorSSHConfig]` | Pick one master. On the hypervisor, drop that master's BGP and BFD traffic to the ToR (TCP/179, UDP/3784-3785, both families) with a dedicated nftables table. Poll at the ToR: that master's session leaves Established, and the API VIP path count drops to `masters-1` per family. Throughout the cut, `https://<API VIP>:6443/readyz` (with `--resolve`, `--noproxy '*'`) from the hypervisor keeps returning 200. Brief failures are allowed while BGP converges, within a budget the builder sets and documents. DeferCleanup deletes the nftables table. Then poll: session Established again, path count back to `masters`. |
| 7 | day-2 peer timer change is applied without node disruption `[Disruptive][Serial]` | Record node boot IDs. Patch `BGPVIPConfig/cluster` `defaultPeers[*]` `holdTimeSeconds`/`keepaliveTimeSeconds` to new valid values (hold ≥ 3 × keepalive). Poll: `observedGeneration` catches up; `Rendered` and `SessionsConfigured` True; `FRRConfiguration/bgp-vip` carries the new timers; sessions on every master Established with the new negotiated timers. Boot IDs unchanged and no node went `Unschedulable` during the test. DeferCleanup restores the original spec and waits for the original timers to be negotiated again. |

Test 7 is in the disruptive suite rather than `openshift/bgp-vip` because it
changes cluster-wide config that test 3 checks, and because applying new
timers may reset every master's session at once (a brief API VIP gap).
FRR only renegotiates timers when the session restarts. If frr-k8s's reload
doesn't restart the sessions, the test must reset them itself, one master at
a time (`clear bgp <peer>` in that master's frr container), and wait for
Established before moving on. The builder confirms which case applies on a
live cluster and documents it in the test.

Why the API failover cut is done on the hypervisor and not on the node: the
ToR uses dynamic neighbors (`bgp listen range` + peer-group), so there is no
per-master neighbor to `shutdown` there, and a `neighbor shutdown` inside the
node's FRR is reverted by the frr-k8s reloader. Dropping packets on the host
is deterministic, independent of FRR config, and trivially undone.

### Lanes (openshift/release)

New workflow `baremetalds-e2e-bgp-vip-dualstack`
(`ci-operator/step-registry/baremetalds/e2e/bgp-vip/dualstack/`):

```
env:  DEVSCRIPTS_CONFIG: IP_STACK=v4v6, DHCP_LEASE_EXPIRY=0 (OCPBUGS-52194),
                         NUM_WORKERS=2, ENABLE_BGP_TOR=true, BGP_VIP_MANAGEMENT=true
      FEATURE_SET: DevPreviewNoUpgrade   (→ TechPreviewNoUpgrade with the other lanes)
pre:  baremetalds-devscripts-conf-featureset
      chain baremetalds-ofcir-pre
test: baremetalds-e2e-bgp-vip-verify
      openshift-tests openshift/bgp-vip
      openshift-tests openshift/bgp-vip/disruptive   (ENABLE_HYPERVISOR_SSH_CONFIG=true)
post: chain baremetalds-ofcir-post
```

Periodic in `openshift-release-main__nightly-5.1.yaml`:
`e2e-metal-ipi-bgp-vip-dualstack`, cluster profile `equinix-ocp-metal`,
capability `intranet`, daily (`0 3 * * *`, offset from the others at 02:00).
The `-dualstack` suffix is what Sippy uses to label the `NetworkStack:dual`
variant (with cluster-data as a fallback for 4.21+).

Existing workflow `baremetalds-e2e-bgp-vip` (daily, v4): add an
`openshift-tests openshift/bgp-vip` step after the verify step. The
disruptive suite is not added there.

The baremetalds `baremetalds-e2e-test` ref takes `TEST_SUITE` from workflow
env, so one workflow can't call it twice with two suites. The builder picks
the mechanism (thin per-suite refs that reuse `baremetalds-e2e-test-commands.sh`,
or step-level env overrides if ci-operator allows them for refs in a
workflow) and follows existing step-registry conventions.

## Facts the design relies on (checked 2026-11-09)

- **dev-scripts already brings up a dual-stack BGP cluster with an IPv6
  peer.** dev-scripts#1945 (OPNET-787) added the v6 ToR peer. The
  `ovn-bgp-metallb` periodic run `2119611341911101440` (IP_STACK=v4v6)
  rendered `bgp-vip` with neighbors `192.168.111.1` and
  `fd2e:6f44:5dd8:c956::1`, and the bash verify passed with v4 and v6 VIP path
  checks. No dev-scripts change is needed; the `dual` variant really tests
  both families.
- **Hypervisor SSH works on ofcir lanes.** `ofcir-acquire` writes
  `${SHARED_DIR}/server-ip`, and the two-node fencing workflows already use
  `baremetalds-ofcir-pre` with `ENABLE_HYPERVISOR_SSH_CONFIG: "true"`.
- **The `bgp-tor` container runs with `--net host`**
  (dev-scripts `bgp/configure_bgp_tor.sh`). Its BGP and BFD sockets are in
  the hypervisor's network namespace, so test 6's drop rule is an `inet`
  table hooked on `input` (and `output` for the replies) on the hypervisor,
  matching the chosen master's addresses in both families.
- **Day-2 peer edits don't roll MachineConfigs.** MCO's default
  NodeDisruptionPolicy has action `None` for
  `/etc/kubernetes/static-pod-resources/frr-k8s/frr-peers.json`
  (`pkg/apihelpers/apihelpers.go`). The live path is CNO re-rendering
  `FRRConfiguration/bgp-vip`. Test 7's "no node disruption" assertion is
  therefore a guarantee, not a hope. Asserting "no MCP update" is too
  strict: MCO may bump a rendered config without draining. So test 7 asserts
  unchanged node boot IDs and no node `Unschedulable`/drain, not MCP
  generation.
- **`ovn-bgp-metallb` and `evpn` run with `vipManagement=BGP`** (the bash
  verify is their first test step), so their conformance runs report the
  non-disruptive tests. Both have 2 workers and the default 2 router
  replicas, same as the dedicated lanes. Test 5 skips with a reason when
  fewer than 2 nodes host Ready router pods. With 2 workers and the router's
  anti-affinity, the evicted replica stays Pending while its node is
  cordoned. The test expects that, and asserts the ingress VIP is still
  advertised from the remaining router node.

## Known risks

- **Sippy classifies every job with `-bgp-` in its name as `candidate` tier.**
  The api analyzer still counts candidate runs but warns that they are outside
  Component Readiness. That's fine for Tech Preview. Before GA, ask TRT to move
  the two lanes to `standard` (precedent: `-ovn-bgp-virt`).
- **ci-test-mapping**: the new tests need a component matcher (likely
  `Networking / On-Prem Load Balancer`, which has no matchers today) so they
  show up under the right component in Component Readiness. Follow-up PR to
  openshift-eng/ci-test-mapping.
- **Test 6 depends on BFD being on in dev-scripts' ToR config** (`neighbor
  CLUSTER bfd`). Without BFD, withdrawal waits for the hold timer
  (dev-scripts default 90 s), and the poll timeout must allow for it.

## Left to the builder

- Exact It/Describe wording (keep test names stable once merged: renames
  reset Sippy history).
- Helper structure, polling intervals, log output on failure (dump `vtysh`
  state and the CR on every failed assertion, as the bash step does).
- The API-reachability failure budget in test 6, and the new timer values in test 7.
- Unit test in `pkg/testsuites/suites_test.go` proving each suite selects
  only its intended tests (pattern: `TestTNFMetricsSuiteSelectsOnlyTNFMetricsTests`).
- Validation: run both suites against a live dev-scripts BGP cluster
  (v4v6) before opening PRs, then rehearse the new periodic.
