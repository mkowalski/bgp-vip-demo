# Design: `[OCPFeatureGate:BGPBasedVIPManagement]` origin tests and dual-stack lane

Date: 2026-11-09, rev 5 2026-11-10
Status: **approved** by both model reviewers (GPT-6 Astra max, Claude Opus 5.5
max) after four rounds; rev 5 applies their final small changes. Mat asked for model-only review, no human in the loop.
Jira: OPNET-595 (epic)
Target PRs: openshift/origin (tests and suites), openshift/release (lanes)

## Intent

BGP-based VIP management (enhancements#1982) is moving from Dev Preview to
Tech Preview. The openshift/api promotion PR (#3165) is with chaibot. The
enhancement's Dev → Tech Preview criteria (lines 1794–1803) ask for at least
5 e2e tests tagged `[OCPFeatureGate:BGPBasedVIPManagement]`, covering install,
failover and dual-stack, running at least 7 times a week. The api repo's
`featuregate-test-analyzer` later grades GA readiness from the same tests: at
least 5 tests, at least 14 runs per variant, 95% pass rate.

Today the coverage is a bash step (`baremetalds-e2e-bgp-vip-verify`) in
openshift/release. It is not gate-tagged, isn't visible to Sippy or Component
Readiness, and no lane runs `openshift-tests` against the feature. This work
ports those checks to origin as gate-tagged Ginkgo tests, adds failover and
data-plane coverage, and adds a daily dual-stack lane.

## Goals

- 8 gate-tagged origin tests in two dedicated suites:
  - `openshift/bgp-vip` (6 tests): non-disruptive.
  - `openshift/bgp-vip/disruptive` (2 tests): cuts one master off the ToR;
    changes the cluster-wide BGP peer config.
- The new dual-stack periodic and the existing v4 lane both run **both**
  suites twice a day during the TP soak, so the metal `ipv4` and `dual`
  variants each get all 8 tests 14 times a week. One skip or flake doesn't drop a variant below 5.
- Through origin's automatic suite tagging, tests 1–4 and 6 also land in
  `openshift/conformance/parallel` and test 5 in `openshift/conformance/serial`.
  Today `ovn-bgp-metallb` runs parallel conformance and reports tests 1–4
  (tests 5 and 6 need hypervisor config, which that lane doesn't pass). The `evpn` lane runs
  `ovn-kubernetes/conformance/parallel` and reports none of them.

## Non-goals

- An IPv6-only lane (needed for GA; separate change).
- Deleting the bash verify step. It stays after the origin step as a
  cross-check; removal is a follow-up.
- Bumping origin's vendored openshift/api (from 10-13, no `BGPVIPConfig` Go
  type). Tests use the dynamic client.
- Moving the lanes to `FEATURE_SET: TechPreviewNoUpgrade` before #3165 is in
  a nightly. They start on `DevPreviewNoUpgrade`.
- An API-VIP health-withdrawal test (kube-vip withdraws the API route when
  the local kube-apiserver is unhealthy). Needs a kube-apiserver outage on
  one master; follow-up. Test 5 covers the same kube-vip mechanism for the
  ingress VIP.

## Anti-goals

- Tests that pass on non-BGP clusters. They **skip** with a reason unless
  `vipManagement=BGP`.
- Flakes on BGP convergence. Every BGP-state check polls with a bounded
  timeout (5 min, as the bash step). API errors inside polls are retried: on
  baremetalds lanes the test client may reach the API through the BGP VIP.
- Disruptive behaviour in `openshift/bgp-vip` or `openshift/conformance/*`.
- A broken cluster after a failed disruptive test (see "Cleanup").
- False failures on other BGP topologies from over-strict checks (exact
  negotiated timers, all-namespace name greps).
- Secrets in test output: every dump of the FRRConfiguration or FRR running
  config redacts neighbor passwords (CNO renders the resolved password inline
  today, `cluster-network-operator` `pkg/network/bgp_vip.go`; see OPNET-823).

## Approaches considered

| Option | What | Trade-off |
|---|---|---|
| **A. Two dedicated suites (picked)** | `openshift/bgp-vip` + `openshift/bgp-vip/disruptive` (`Parallelism: 1`, `ClusterStabilityDuringTest: Disruptive`). Modeled on `openshift/two-node`. | Two small suites; fast lanes; BGP signal not buried in unrelated failures. |
| B. Reuse existing suites | Gate tag in `openshift/disruptive`; lane runs `conformance/parallel` then `openshift/disruptive`. | Pulls in etcd/node recovery tests and full conformance; slow, noisy. |
| C. One suite | Single suite. | One parallelism and stability setting for everything. Rejected. |

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
        `source == "openshift:payload:origin" && name.contains("[OCPFeatureGate:BGPBasedVIPManagement]") && !name.contains("[Disruptive]")`,
    },
    TestTimeout: 20 * time.Minute,
},
{
    Name: "openshift/bgp-vip/disruptive",
    Description: templates.LongDesc(`
    Disruptive tests for BGP-based VIP management: cut one control-plane node
    off the top-of-rack router, change the cluster-wide BGP peer configuration.
    `),
    Qualifiers: []string{
        `source == "openshift:payload:origin" && name.contains("[OCPFeatureGate:BGPBasedVIPManagement]") && name.contains("[Disruptive]")`,
    },
    TestTimeout:                30 * time.Minute,
    Parallelism:                1,
    ClusterStabilityDuringTest: ginkgo.Disruptive,
},
```

- Neither suite uses an early/late wrapper (like `two-node`, `ipsec`,
  `virtualization`). Default parallelism is fine: origin runs parallel tests
  first and `[Serial]` ones alone afterwards (`pkg/test/ginkgo/queue.go`).
- No `withStandardEarlyOrLateTests` on the disruptive suite: its early/late
  half has no `source` term and pulls in every `[Early]`/`[Late]` parallel
  conformance test (alerts, TLS registry, API graceful termination, and
  `[sig-ci] [Early] prow job name should match feature set`,
  `test/extended/ci/job_names.go:42-52`, which fails on a TechPreview
  cluster whose job name lacks `-techpreview`). The `[Late]` reboot check
  (`test/extended/machines/cluster.go:127`) wouldn't catch an MCO-planned
  reboot anyway; test 8's boot-ID check does.
- `source == "openshift:payload:origin"` keeps same-tagged tests from other
  extension binaries (CNO, MCO) out; `[sig-network]` alone wouldn't.
  Precedent: `openshift/network/third-party` filters on `source`.
- `appendSuiteNames` (`pkg/test/extensions/suites.go`) drops `[Disruptive]`
  names (`excluded.go`) and tags the rest into `conformance/{parallel,serial}`.
  `[Disruptive]` implies `[Serial]` (`labels.go`). No change needed.
- Run-time filtering (`pkg/test/filters/cluster_state.go`): tests with a
  disabled gate are dropped, and `[Requires:HypervisorSSHConfig]` tests are
  dropped without `--with-hypervisor-json` (`:70-72`). After promotion, every
  TechPreview conformance lane lists tests 1–4 (they skip in `BeforeEach`);
  tests 5 and 6 are listed only where the lane passes hypervisor config. Running
  `openshift/bgp-vip` with the gate off fails with "no tests to run";
  expected.
- Unit tests, two files (`appendSuiteNames` is unexported in
  `pkg/test/extensions`, and `testsuites` imports `extensions`):
  - `pkg/test/extensions/suites_test.go` (new): run `appendSuiteNames` on the
    8 names; 1–4 and 6 get `[Suite:openshift/conformance/parallel]`, 5 gets
    `.../serial`, 7–8 get nothing.
  - `pkg/testsuites/suites_test.go`, after
    `TestTNFMetricsSuiteSelectsOnlyTNFMetricsTests`: candidates carry
    `Source: "openshift:payload:origin"` and the suffixes from the first
    test. `openshift/bgp-vip` selects 1–6 and not 7–8;
    `openshift/bgp-vip/disruptive` selects 7–8 and not 1–6 nor an `[Early]`
    conformance test; an identical spec with
    `Source: "openshift:payload:cluster-network-operator"` is selected by neither.

### Test naming

Location: `test/extended/networking/` (`bgp_vip.go`,
`bgp_vip_disruptive.go`, `bgp_vip_util.go`). Every `Describe` carries

```
[sig-network][Jira:"Networking / On-Prem Load Balancer"][OCPFeatureGate:BGPBasedVIPManagement][Feature:BGPVIPManagement][apigroup:config.openshift.io][apigroup:machineconfiguration.openshift.io]
```

The tag set and It texts are frozen before merge (renames reset Sippy
history). Never add `[Slow]`, `[Flaky]`, `[Local]` (they leave conformance)
or `[Feature:IPv6DualStack]` / `[Feature:Networking-IPv6]` (filtered on v4).

### Common inputs and helpers

- `BeforeEach`: skip unless platform is BareMetal and
  `infrastructure.status.platformStatus.baremetal.vipManagement == "BGP"`.
- `BGPVIPConfig/cluster` (`machineconfiguration.openshift.io/v1alpha1`,
  dynamic client): `spec.defaultPeers[]` (`peerAddress`, `peerASN`,
  `failureDetection` `BFD|HoldTimer`, optional `holdTimeSeconds` /
  `keepaliveTimeSeconds`), `metadata.generation`, `status.conditions`.
  There is **no** `status.observedGeneration`; each condition has its own.
  `Rendered` is set by MCO (written into ControllerConfig), `SessionsConfigured`
  by CNO (written into the FRRConfiguration). Neither proves FRR applied it;
  that comes from node-side FRR state.
- `FRRConfiguration/bgp-vip` in `openshift-frr-k8s`. Unset CR timers stay
  unset there too.
- Node-side FRR: `vtysh -c '<cmd> json'` in container `frr` of the frr-k8s
  pod on that node, found by namespace `openshift-frr-k8s` + `spec.nodeName`
  (masters: MCO static pod `frr-k8s-<node>`; workers: CNO DaemonSet pod with
  a generated name). Exec as admin.
- Hypervisor (tests 5, 6, 7): `exutil.GetHypervisorConfig()`. A new
  `bgp_vip_util.go` helper runs SSH with `exec.CommandContext` and
  `-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3`;
  the shared `edge_topologies/utils/core/ssh.go:135` helper has no timeout
  and is left alone.
- Failure output: on every failed assertion, dump the relevant `vtysh` state,
  the CR, and the FRRConfiguration with passwords redacted.

### `openshift/bgp-vip` (non-disruptive), 6 tests

| # | Test (abbreviated) | From | Asserts |
|---|---|---|---|
| 1 | BGPVIPConfig is rendered for the current generation | verify [1/6] | CRD exists; `Rendered=True` and `SessionsConfigured=True`, each with condition `observedGeneration == metadata.generation`; Infrastructure says `BGP`. |
| 2 | control plane runs frr-k8s instead of keepalived | verify [2/6], [3/6] | Static pod `frr-k8s-<master>` Ready on every master; no keepalived pod in `openshift-kni-infra` (label `app=kni-infra-vrrp`, as `load_balancer.go:70-84` finds it). |
| 3 | every master has an Established session to every declared peer, with the configured timers and BFD | verify [4/6], node-side | Per master × `defaultPeers` entry: `show bgp neighbors <peer> json` → `bgpState == Established`. If the CR sets timers: `bgpTimerConfiguredHoldTimeMsecs` / `bgpTimerConfiguredKeepAliveIntervalMsecs` equal the CR, negotiated hold ≤ configured (FRR takes the minimum of both sides). If unset: log only. BFD peer `Up` iff `failureDetection == BFD`. Polled. |
| 4 | API and ingress VIPs are advertised per address family | verify [5/6], node-side | For every family the CR has a peer in: every master advertises each API VIP of that family (`/32`, `/128`) to that peer (`advertised-routes json`); exactly the nodes hosting a Ready default router pod advertise each ingress VIP of that family. A VIP family without a peer of that family is skipped with a log line (valid config). Dual-stack coverage is enforced by the lane guard. |
| 5 | ingress VIP follows the router pods `[Serial][Requires:HypervisorSSHConfig]` | new | Skip if fewer than 2 nodes host Ready router pods. Before mutating, per family, confirm the hypervisor reaches the ingress VIP over BGP (`ip -j route get <VIP>` shows a `/32`/`/128` route via a router node, installed by the ToR's zebra, `configure_bgp_tor.sh:14`; nodes would reach the in-subnet VIP over L2 and bypass BGP, so the probe can't run from the cluster). Start a continuous probe on the hypervisor: new-connection `curl --noproxy '*' --resolve` to the VIP every second, per family. Pick a router node; cordon it; delete its router pod with `gracePeriodSeconds: 30` (default is 3600, `cluster-ingress-operator` `deployment.go:325`). Poll, per family: that node stops advertising the ingress VIP while the other router node(s) still advertise it. The probe's failures over the whole window stay within a documented budget. Uncordon (in the body, and in `DeferCleanup`), then wait for the router deployment to be fully available and the advertising set to equal the Ready-router node set again, per family. With two workers and host ports, the replacement replica stays Pending while its node is cordoned. |
| 6 | ingress and API VIPs serve traffic in every family `[Requires:HypervisorSSHConfig]` | verify [6/6] | From the hypervisor, the path an external client takes: `curl --noproxy '*' --resolve <console host>:443:<VIP>` for each advertised ingress VIP → 200; `https://<api host>:6443/readyz` via each advertised API VIP → 200. Polled. Read-only, so not `[Disruptive]`. |

Test 5 is `[Serial]` because it moves router pods other tests use, and not
`[Disruptive]` because the ingress VIP keeps being served throughout. It
lands in `conformance/serial` and runs wherever hypervisor config is passed. Origin's
monitors already tolerate the ingress operator's `IngressUnavailable` /
`Reconciling` during it (`legacycvomonitortests/operators.go:389-391, 853-855`);
the rehearsal confirms nothing else fires.

### `openshift/bgp-vip/disruptive`, 2 tests

**Test 7 — API VIP fails over when one master is cut off from the ToR**
`[Disruptive][Serial][Requires:HypervisorSSHConfig]`

1. Register cleanup first (below). On the hypervisor, save and set
   `net.ipv4.fib_multipath_hash_policy=1` and
   `net.ipv6.fib_multipath_hash_policy=1`. The kernel default hashes only
   addresses, so every probe from the hypervisor would take one path; with
   port-based hashing, new connections spread across all masters. Pick any
   master and read its MAC on the dev-scripts external bridge
   (`ip -j neigh show <master IP>`; `vm_setup_vars.yml` `external_network`).
2. Start the sampler: per family, N new `readyz` connections to the API VIP
   per second (`curl --noproxy '*' --resolve`), recorded with timestamps,
   running until step 5 ends.
3. Inject in two stages, using two tables `bridge bgp_vip_e2e` and
   `inet bgp_vip_e2e`:
   - First the data-plane black hole only: a `bridge` family, `output` hook
     rule dropping frames to that master's MAC whose destination is an API
     VIP with TCP/6443 (IPv4 and IPv6), with a counter per family. Wait until
     both counters are non-zero. That proves the cut is being hit before BFD
     can withdraw anything. Scoped to VIP:6443, it leaves the hypervisor's SSH
     and direct-IP access to the master, and VM-to-VM traffic, alone. API
     traffic from the CI pod (via the hypervisor) hashed to that master is
     dropped too while the cut lasts; that's expected, and the test's API
     calls are retried.
   - Then the control-plane cut, which starts the convergence clock: an
     `inet` family table, `input` and `output` hooks, dropping TCP/179 and
     UDP/3784, 3785 and **4784** between the ToR and that master's addresses,
     both families. dev-scripts peers with `ebgp-multihop`, so FRR uses
     multihop BFD on 4784 (`configure_bgp_tor.sh:99-105`).
4. Assert:
   - At the ToR (`podman exec bgp-tor vtysh`), that master's session leaves
     Established, and each API VIP's path count drops to `masters-1` per
     family, within a BFD deadline well below the hold timer.
   - From the sampler: after the clock starts, `readyz` is all-200 per family
     within a measured, documented budget (BFD detection + withdrawal +
     margin), and stays all-200 until the cut is lifted.
5. Delete both tables; restore the hash policies. Poll: session Established, path count back to `masters`.

**Test 8 — day-2 peer timer change is applied without node disruption**
`[Disruptive][Serial]`

1. Require every MachineConfigPool settled (`spec.configuration.name ==
   status.configuration.name`, `Updated=True`, `Degraded=False`). Save the
   full CR spec, each pool's `spec.configuration.name`, and every node's boot
   ID. Start a node watch for `Unschedulable` before patching.
2. Patch every `defaultPeers[*]` to `holdTimeSeconds: 30`,
   `keepaliveTimeSeconds: 10`. That is within the CR's limits
   (hold ≥ 3 × keepalive) and below the ToR's FRR traditional defaults
   (180/60), so the negotiated values equal ours.
3. Poll: both conditions True for the new generation; `FRRConfiguration/bgp-vip`
   carries the new timers; on every master the configured timers match and
   sessions are Established with negotiated 30 s / 10 s.
4. Wait for the change to reach the nodes. `frr-peers.json` is a master-only
   file that carries the timers, so the master pool must move to a new
   rendered config:
   - Wait until the master pool's `spec.configuration.name` names a rendered
     MachineConfig whose `frr-peers.json` carries the new timers. Parse it in
     the test and never log it: it holds the peer password (OPNET-823).
   - Then wait until `status.configuration.name` equals it, with
     `Updated=True`, `Updating=False`, `Degraded=False`,
     `degradedMachineCount == 0` and `updatedMachineCount == machineCount`.
   - The worker pool's target must stay as saved.
5. Assert boot IDs unchanged and no node became Unschedulable from the patch
   to the end of step 4.
6. Restore the saved spec with `Update` (retry on conflict): `defaultPeers`
   is a list, so a merge patch would replace it wholesale. Do the per-master
   session reset again if step 3 needed it. Wait for the same step-4 barrier
   with the original timers. Wait for the
   original timers to be negotiated again and the pools to settle again.

FRR only renegotiates timers when a session restarts. If the frr-k8s reload
doesn't restart sessions, test 8 resets them itself, one master at a time
(`clear bgp <peer>` in that master's `frr` container), waiting for
Established before the next. The builder confirms which case applies on a
live cluster and documents it.

Why the cut is on the hypervisor: the ToR uses dynamic neighbors
(`bgp listen range` + peer-group), so there's no per-master neighbor to shut
down there, and a `neighbor shutdown` in the node's FRR is reverted by the
frr-k8s reloader. `bgp-tor` runs with `--net host`, so host nftables sees its
BGP and BFD traffic.

### Cleanup (tests 5, 7, 8)

- Register the undo with `DeferCleanup` **before** mutating. The nftables
  table delete is registered last so it runs first.
- Each cleanup runs the undo **and** its recovery wait (sessions back, pools
  settled, router available) on its own bounded context, so recovery also
  happens when an assertion fails mid-test.
- Time budget, enforced: the poll deadlines in a test body add up to at most
  `TestTimeout − cleanup budget − 2 min`. Disruptive suite: 30 min timeout,
  10 min cleanup, body ≤ 18 min. Test 5 (20 min suite timeout): 5 min
  cleanup, body ≤ 13 min. On timeout origin sends SIGINT, then SIGABRT 60 s
  later (`pkg/test/extensions/binary.go`), so a timeout never lands inside
  cleanup.

### Lanes (openshift/release)

**New ref `baremetalds-e2e-bgp-vip-origin`**
(`ci-operator/step-registry/baremetalds/e2e/bgp-vip/origin/`), same image
(`tests`) and credentials as `baremetalds-e2e-test`. It runs the suites in
`BGP_VIP_SUITES` (default `openshift/bgp-vip openshift/bgp-vip/disruptive`)
in order, each with its own `-o` / `--junit-dir` under
`${ARTIFACT_DIR}/<suite>/`, keeps going past a failing suite, and exits
non-zero if any failed.

It keeps the setup `baremetalds-e2e-test-commands.sh` does before running
`openshift-tests`:

- build-farm image-pull grant (`:9-17`);
- `packet-conf.sh`, `ds-vars.conf`, `proxy-conf.sh`, and
  `KUBECONFIG=${SHARED_DIR}/kubeconfig` (`:261-271`, `:374-382`);
- `set_test_provider` and test-image mirroring;
- wait for clusteroperators not Progressing;
- hypervisor config as in `build_hypervisor_config` (`:278-307`), but
  **failing** when `server-ip` or the key is missing instead of warning; and
  `--with-hypervisor-json` passed to **every** suite invocation (`:322-326`).

The shared logic is copied into the new ref; refactoring
`baremetalds-e2e-test` into a sourced library is out of scope.

Why a new ref: a workflow can't put step-level `env` on a `ref`, can't list
the same ref twice, and a ref can't point at another ref's commands file.

**Dual-stack guard**, in the same ref before the first suite: with
`BGP_VIP_REQUIRE_FAMILIES=ipv4,ipv6`, check that `BGPVIPConfig/cluster` has
a peer in each family and Infrastructure has API and ingress VIPs in each;
fail otherwise. This keeps the dual lane from silently testing only v4.

Test phase in both workflows:

```
test: baremetalds-e2e-bgp-vip-origin     # gate-tagged signal first
      baremetalds-e2e-bgp-vip-verify     # bash cross-check (skipped if the first fails)
```

New workflow `baremetalds-e2e-bgp-vip-dualstack`:

```
env:  DEVSCRIPTS_CONFIG: IP_STACK=v4v6, DHCP_LEASE_EXPIRY=0 (OCPBUGS-52194),
                         NUM_WORKERS=2, ENABLE_BGP_TOR=true, BGP_VIP_MANAGEMENT=true
      FEATURE_SET: DevPreviewNoUpgrade   (→ TechPreviewNoUpgrade with the other lanes)
      BGP_VIP_REQUIRE_FAMILIES: ipv4,ipv6
pre:  baremetalds-devscripts-conf-featureset
      chain baremetalds-ofcir-pre
test: baremetalds-e2e-bgp-vip-origin
      baremetalds-e2e-bgp-vip-verify
post: chain baremetalds-ofcir-post
```

Existing `baremetalds-e2e-bgp-vip` (daily, v4): add
`baremetalds-e2e-bgp-vip-origin` before verify, `BGP_VIP_REQUIRE_FAMILIES: ipv4`.

dev-scripts sets explicit CR timers (90/30, `ocp_install_env.sh:193-194`),
so test 3 has values to check on both lanes.

Periodic in `openshift-release-main__nightly-5.1.yaml`:
`e2e-metal-ipi-bgp-vip-dualstack`, cluster profile `equinix-ocp-metal`,
capability `intranet`, **twice daily** `0 3,15 * * *` during the TP soak,
so the `dual` variant keeps margin over 7 runs a week when an install fails.
Same for the existing v4 lane: `0 2,14 * * *`. Sippy
takes NetworkStack from cluster-data for 4.21+, so the job is labelled
`dual`; the `-dualstack` suffix keeps the name consistent with that.

## Facts the design relies on (checked 2026-11-09/10)

- **Dual-stack BGP works in dev-scripts** (dev-scripts#1945, OPNET-787):
  `ovn-bgp-metallb` run `2119611341911101440` (v4v6) peered with
  `192.168.111.1` and `fd2e:6f44:5dd8:c956::1`, and passed v4 and v6 path checks.
- **Hypervisor SSH on ofcir lanes**: `ofcir-acquire` writes
  `${SHARED_DIR}/server-ip`; `baremetalds-e2e-test-commands.sh:278-326`
  builds and passes `--with-hypervisor-json`; origin reads it
  (`pkg/cmd/openshift-tests/run/flags.go`) and filters
  `[Requires:HypervisorSSHConfig]` without it (`cluster_state.go:70-72`).
- **`bgp-tor`**: `--net host`, BFD on, `ebgp-multihop`
  (`configure_bgp_tor.sh:66-67, 99-105`), FRR `traditional` defaults.
- **External network is a host bridge** (`vm_setup_vars.yml`
  `external_network`), so bridge-family nftables sees the hypervisor's frames
  to the masters.
- **Day-2 peer edits don't need a reboot**: MCO's default
  NodeDisruptionPolicy is `None` for
  `/etc/kubernetes/static-pod-resources/frr-k8s/frr-peers.json`
  (`pkg/apihelpers/apihelpers.go`). The live path is CNO re-rendering
  `FRRConfiguration/bgp-vip`. MCO sets `Rendered` as soon as it writes
  ControllerConfig (`pkg/operator/sync.go`), before any rollout; hence
  test 8's pool check.
- **Router pods**: 1 h termination grace (`deployment.go:325-326`), host ports.
- **Coexistence lanes**: `ovn-bgp-metallb` runs `openshift/conformance/parallel`
  with `vipManagement=BGP` and no hypervisor config (tests 1–4). `evpn` runs
  `ovn-kubernetes/conformance/parallel` (workflow line 15): none.

## Known risks and follow-ups

- **Sippy tier**: jobs with `-bgp-` in the name are `candidate`. Fine for TP;
  before GA ask TRT for `standard` (precedent `-ovn-bgp-virt`).
- **TP switch requires renaming the BGP lanes with `-techpreview`.** Sippy's
  FeatureSet is name-based, and `[sig-ci] [Early] prow job name should match
  feature set` fails every conformance run (e.g. `ovn-bgp-metallb`) on a
  TechPreview cluster whose job name lacks it. Renaming resets job history;
  test history is per test name, so it's kept.
- **featuregate-test-analyzer**: `BGPBasedVIPManagement` names no platform,
  so at GA `filterVariants` checks every required SelfManagedHA variant, not
  just metal. Before GA: an explicit gate → platform mapping in the analyzer,
  or a recorded exception. Also the `ipv6` variant.
- **ci-test-mapping**: the `[Jira:...]` tag only breaks ties. A matcher under
  `Networking / On-Prem Load Balancer` (exists in OCPBUGS, no matchers yet)
  is still needed; follow-up PR to openshift-eng/ci-test-mapping.
- **Test 7 budget** depends on BFD; the builder measures it on a live
  cluster and documents the number.

## Left to the builder

- Exact It wording (frozen before merge).
- Helper structure and polling intervals.
- Test 7's measured budget; the session-reset question in test 8.
- Validation: run both suites on a live v4v6 dev-scripts BGP cluster, then
  rehearse both periodics, before opening PRs.

## Review log

Reviewers: GPT-6 Astra (max) and Claude Opus 5.5 (max); every finding was
checked against code before it was applied. "Fable 5.1" was requested but
isn't available on the configured model route; Opus 5.5 max stood in.

- **Round 1 (rev 1, 2026-11-09)**: Astra "rework" (13 findings), Opus
  "approve with changes" (12). Rev 2 applied:
  - per-condition generation instead of a nonexistent `status.observedGeneration`;
  - configured-vs-negotiated timers;
  - multihop BFD 4784;
  - a data-plane black hole and route-chosen master in the failover test;
  - pool settle and `Update`-based restore in the timer test;
  - a bounded router grace period;
  - a new data-plane test;
  - the keepalived check scoped by namespace and label;
  - exec target found by node;
  - bounded SSH and cleanup ordering;
  - a concrete runner ref, origin step first, a dual-stack guard;
  - corrected coexistence claims;
  - Sippy, analyzer and ci-test-mapping follow-ups.
- **Round 2 (rev 2, 2026-11-09)**: Astra "rework", with three items
  partially resolved and five new ones. The Opus re-review was interrupted.
  Rev 3 applied:
  - pools must settle on the *current* rendered config;
  - recovery waits moved into cleanup with their own budget;
  - a traffic probe during test 5;
  - test 7's black hole specified as a bridge `output` rule scoped to
    VIP:6443, which keeps hypervisor SSH working;
  - the runner ref keeps the full `baremetalds-e2e-test` setup and passes
    hypervisor config to every suite;
  - password redaction in dumps;
  - a `source` qualifier instead of `[sig-network]`;
  - the test 6 listing statement corrected.
- **Round 3 (rev 3, 2026-11-10)**: Astra "rework" (4 new), Opus "approve
  with changes" (8 new). Rev 4 applied:
  - disruptive suite wrapper dropped (it pulled in the job-name feature-set
    check and other unrelated early/late tests);
  - TP switch renames the lanes with `-techpreview`;
  - test 5 probes continuously from the hypervisor over the BGP route (from
    a node it'd bypass BGP over L2), and needs hypervisor config;
  - test 7: master chosen from IPv4, many new connections per poll, black-hole
    counters must be non-zero, two family-qualified tables, CI API blip noted;
  - test 8: wait for ControllerConfig and pool `observedGeneration` before
    comparing, settled baseline, Degraded checks, correct reason for `Update`;
  - enforced body deadlines that reserve the cleanup budget;
  - unit tests split so `appendSuiteNames` is tested in its own package;
  - dual-stack lane twice daily for margin.
- **Round 4 (rev 4, 2026-11-10)**: both "approve with changes", and both
  said the changes need no further review round. Rev 5 applied:
  - test 7 sets port-based multipath hashing on the hypervisor (the default
    hashes only addresses, so probes would always take one path);
  - test 7 starts the sampler first, injects the black hole alone until both
    counters are non-zero, then cuts BGP/BFD and starts the clock;
  - test 8 waits for the master pool's target rendered config to carry the
    new timers (parsed, never logged) before waiting for it to apply, with
    the same barrier on restore;
  - v4 lane twice daily too.
