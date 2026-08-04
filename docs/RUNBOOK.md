# Runbook — building, deploying, verifying the BGP VIP demo

Everything operational. Assumes the branches from README.md are checked out
locally under `~/git/github.com/` and the demo hypervisor is `root@metal-u15`.

## 1. Credentials / auth files

- **quay.io/mkowalski push**: normal podman login (personal).
- **registry.ci.openshift.org**: token from
  https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/token/request
  then `oc login api.ci.l2s4.p1.openshiftapps.com:6443 --token=...` +
  `oc registry login`. Expires ~24h — builder pulls and payload assembly need it.
- **Merged auth for payload work** (release-dev quay read + personal push +
  CI). Recreate with:

```bash
AUTH=~/.config/containers/auth.json
[ -f "${XDG_RUNTIME_DIR}/containers/auth.json" ] && AUTH="${XDG_RUNTIME_DIR}/containers/auth.json"
jq -n --slurpfile rht ~/RHT/pull-secret.json --slurpfile cur "$AUTH" \
  '{auths: {"quay.io": $rht[0].auths["quay.io"],
            "quay.io/mkowalski": $cur[0].auths["quay.io"],
            "registry.ci.openshift.org": $cur[0].auths["registry.ci.openshift.org"],
            "registry.redhat.io": $rht[0].auths["registry.redhat.io"]}}' \
  > /tmp/bgp-payload-auth.json && chmod 600 /tmp/bgp-payload-auth.json
```

- **Cluster pull secret** (dev-scripts `pull_secret.json` on metal-u15):
  RHT pull secret + `quay.io/mkowalski` scoped entry + registry.ci — the
  quay.io/mkowalski repos are PRIVATE, nodes need the cred. Already placed at
  `/root/dev-scripts/pull_secret.json`.
- Use a **5.0 oc** for `oc adm release new` (old oc rejects 5.0 component
  versions). Extract: `podman create $(oc adm release info --image-for=cli
  <payload>)` + `podman cp <ctr>:/usr/bin/oc`.

## 2. Image builds

Local storage caveat: ~/.local/share/containers is a 98G loop device that
fills up — prune old images first (`podman image prune`; date-filtered rmi).
A full disk makes builds/pushes fail in confusing ways (stale-tag pushes!).
Always verify pushes: `skopeo inspect docker://<tag> | jq .Created`.
CI builder tags get GC'd — if `manifest unknown`, re-check
`skopeo list-tags docker://registry.ci.openshift.org/ocp/builder`.
Remote build fallback: metal-u15 (80 cores, 1.5T NVMe).

| Image | How |
|-------|-----|
| MCO | `podman build -f build/Dockerfile.mco ~/git/github.com/machine-config-operator` (repo Dockerfile with stale 4.22 builders replaced by 5.0 — see file) |
| CNO | `podman build -f build/Dockerfile.cno ~/git/github.com/cluster-network-operator` (same substitution) |
| runtimecfg | `podman build -f Dockerfile .` in baremetal-runtimecfg (builders still valid) |
| kube-vip | worktree the branch first (main checkout is elsewhere): `git worktree add /tmp/kv OPNET-595-bgp-vip-management && podman build -f Dockerfile.openshift /tmp/kv` |
| cluster-config-api | `podman build -f Dockerfile.ocp ~/git/github.com/openshift-api` |
| metallb-frr (FRR fix overlay) | 1) build patched zebra: clone FRRouting/frr @ frr-10.4.3, `git am patches/frr/*.patch` (TWO patches: 0001 SELECTED flag + 0002 table-scoped early cleanup), run `build/frr-build.sh` in a `quay.io/centos/centos:stream9` container (mount src + out; el9-compatible glibc 2.34). 2) `podman build build/ -f build/Dockerfile.frr-overlay` (copies zebra over /usr/lib/frr and /usr/libexec/frr — BOTH paths, see toolbox). Long-term this belongs in the frr10 RPM — see NEXT-STEPS |

Tag everything `quay.io/mkowalski/<name>:bgp-demo` and push. MCO note:
`go build ./...` locally fails on 5 gpgme-dependent packages (missing system
lib) — use `-tags containers_image_openpgp` for local test runs; container
builds are unaffected.

## 3. Payload assembly

```bash
oc adm release new --registry-config /tmp/bgp-payload-auth.json \
  --from-release registry.ci.openshift.org/ocp/release-5:5.0.0-0.nightly-2026-07-07-232341 \
  --name 5.0.0-0.bgpdemo --to-image quay.io/mkowalski/ocp-release:bgp-vip-demo \
  machine-config-operator=quay.io/mkowalski/machine-config-operator:bgp-demo \
  cluster-network-operator=quay.io/mkowalski/cluster-network-operator:bgp-demo \
  baremetal-runtimecfg=quay.io/mkowalski/baremetal-runtimecfg:bgp-demo \
  kube-vip=quay.io/mkowalski/kube-vip:bgp-demo \
  cluster-config-api=quay.io/mkowalski/cluster-config-api:bgp-demo \
  metallb-frr=quay.io/mkowalski/metallb-frr:bgp-demo
```

`kube-vip` is a NEW tag — `oc adm release new` accepts it. The payload stores
tag pullspecs, so **repushing an image tag is enough; no payload rebuild
needed** (bootstrap resolves at pull time). Only rebuild the payload to change
the base nightly or the tag set.

## 4. Hypervisor / dev-scripts (metal-u15)

- Demo config: `/root/dev-scripts/config_root.sh` (backup of the previous
  one: `config_root.sh.pre-bgp-demo`). Key vars: custom payload,
  `KNI_INSTALL_FROM_GIT=1` + `OPENSHIFT_INSTALL_PATH=/root/installer-bgp`
  (clone of the installer branch — transferred via git bundle),
  `FEATURE_SET=DevPreviewNoUpgrade`, `NUM_MASTERS=3 NUM_WORKERS=2`
  (`WORKER_VCPU=8 WORKER_MEMORY=16384 WORKER_DISK=60`),
  `IP_STACK=v4`, `MASTER_MEMORY=32768 MASTER_VCPU=10`.
- ToR: config-driven since dev-scripts branch `bgp-tor-speaker` —
  `ENABLE_BGP_TOR=true` in config_root.sh deploys it during `make configure`
  (`bgp/configure_bgp_tor.sh`, teardown in host_cleanup); `BGP_TOR_ASN=64513`,
  `BGP_CLUSTER_ASN=64512`, `BGP_TOR_IMAGE` overridable. metal-u15 already has
  the bgp/ scripts + config block. Manual fallback:
  `/root/bgp-vip-demo/bgp-tor.sh up|down|status`. Status/debug:
  `podman exec bgp-tor vtysh -c "show bgp summary"`.

### Deploy cycle (NEVER `make redeploy` — it regenerates the install-config)

Since 2026-07-30 the install-config patching is a dev-scripts knob
(`BGP_VIP_MANAGEMENT=true` in config_root.sh, dev-scripts#1939 — applied to
the metal-u15 checkout; localASN/peerASN/peer address default to the
ENABLE_BGP_TOR conventions):

```bash
cd /root/dev-scripts
tmux kill-session -t bgprun 2>/dev/null
make ocp_cleanup
make build_installer install_config      # regenerates install-config + rhcos.json
# metal-u15 quirk: the custom payload defeats the installer version parse,
# which trips the <=4.4 dnsVIP guard; strip it (CI is unaffected):
python3 - <<'EOF'
import yaml
for f in ("/root/dev-scripts/ocp/ostest/install-config.yaml",
          "/root/dev-scripts/ocp/ostest/install-config.yaml.save"):
    cfg = yaml.safe_load(open(f))
    cfg["platform"]["baremetal"].pop("dnsVIP", None)
    yaml.safe_dump(cfg, open(f, "w"), default_flow_style=False)
EOF
tmux new-session -d -s bgprun "make ocp_run 2>&1 | tee /tmp/ocp-run.log"
```

Install takes 60–75 min. First host provisioning: `make requirements configure`
(target is `configure`, not `host`).

## Current image-tag state (2026-07-14; provenance updated 2026-08-05)

`quay.io/mkowalski/metallb-frr:bgp-demo` = 10.4.3 + SELECTED-flag patch ONLY
(the table-scope fix from FRRouting/frr#22654 is NOT deployed; the bug is
now FIXED UPSTREAM via FRRouting/frr#22676, merged after 10.7.0 — no shipped
release has it yet).
`quay.io/mkowalski/kube-vip:bgp-demo` = realm-toggle workaround build (7d27248).
This is the run17/run19 configuration. run18 proved the FRR fix alone is
enough; to switch, rebuild zebra at 8989c33 into the overlay and repoint
kube-vip to 8cd17f7.

### FRR provenance (what actually ships where)

The payload tag `metallb-frr` is built from **github.com/openshift/frr** —
despite the name, that repo is the midstream **frr-k8s** source tree: its
Dockerfile.openshift compiles the frr-k8s Go binaries (controller,
frr-metrics, frr-status, reloader, statuscleaner) and then installs the FRR
daemons (zebra/bgpd/watchfrr/vtysh) as the RHEL 9 **`frr10` RPM**, which is
delivered through **FDP (Fast Datapath)**. Nothing is compiled from FRR
source in the image, and nothing comes from upstream frr-k8s's quay images.
Consequences:
- new FRR reaches the cluster as: FDP frr10 update → metallb-frr image
  rebuild → the one image consumed by all three paths (CNO worker
  DaemonSet, MCO master/bootstrap static pods, CNO metrics companion)
- FRR bug backports belong in the FDP frr10 package (hence RHEL-193997);
  once FDP ships ≥10.7 (SELECTED-flag fix) and the first release carrying
  #22676, stock releases satisfy every FRR need we have
- the demo overlay simply replaces the zebra binary inside that image

### kube-vip↔FRR relationship (positioning, for reviews/questions)

There is NO software integration between kube-vip and FRR, direct or via
frr-k8s: kube-vip (routing-table mode) health-gates VIP routes in kernel
table 198; FRR redistributes that table (`redistribute table-direct 198`).
The kernel table is the entire contract; frr-k8s is FRR's delivery and
configuration vehicle, not an integration layer. kube-vip's native BGP mode
is deliberately unused (single BGP speaker per node, one session set).

## 5. Verification checklist

```bash
# ToR view (hypervisor)
podman exec bgp-tor vtysh -c "show bgp summary"       # sessions per node
podman exec bgp-tor vtysh -c "show ip bgp"            # VIP /32s, origin '?', per-node paths
ip route show proto bgp                                # ECMP kernel routes for .5/.4
ip route get 192.168.111.5                             # via <node> = L3 path, not connected

# Cluster (KUBECONFIG=~/dev-scripts/ocp/ostest/auth/kubeconfig)
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.baremetal.vipManagement}'  # BGP
oc get frrconfiguration -n openshift-frr-k8s           # bgp-vip (cluster-wide; was bgp-vip-master pre-run15)
oc get bgpsessionstates -n openshift-frr-k8s           # Established per master
oc get frrnodestates                                   # one per master
oc get pods -n openshift-frr-k8s                       # static mirror pods 4/4

# Node-level (ssh core@<master>)
ip route show table 198                                # VIP on the kube-vip leader, proto 248
sudo crictl exec $(sudo crictl ps --name '^frr$' -q) vtysh -c "show ip bgp"           # '?' = gated redistribute
sudo crictl exec ... vtysh -c "show ip bgp neighbors 192.168.111.1 advertised-routes"
curl -s -o /dev/null -w %{http_code} http://localhost:1936/healthz   # router health (ingress gate)

# End-user path
curl -k https://console-openshift-console.apps.ostest.test.metalkube.org   # 200 via BGP-routed .4
```

Healthy end state: origin `?` paths (redistribute = health-gated); ingress VIP
advertised ONLY from router-bearing nodes (with workers present: the router
WORKERS only); karpenter CO unavailable is a known
base-nightly baremetal bug ("unsupported platform"), not BGP-related.

## 6. Debugging toolbox (what actually worked)

- Bootstrap node IP: `sudo virsh net-dhcp-leases ostestbm` (hostname `-`);
  masters are .20/.21/.22. ssh as `core@`.
- Static pod state: `sudo crictl ps -a | grep -E 'frr|kube-vip'`,
  `sudo crictl logs <ctr>`.
- Who am I (node kubeconfig): `oc --kubeconfig=/etc/kubernetes/kubeconfig auth whoami`
  → `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`.
- frr-k8s semantics questions → read the source in ~/git/github.com/frr
  (internal/controller/api_to_config.go, internal/frr/templates/).
- FRR behavior questions → `lab/frr-lab.sh` pattern: privileged container on
  the exact payload image, dummy iface, table-198 route, iterate configs in
  minutes instead of 75-minute cluster runs. Overlay candidate binaries with
  `-v ./zebra:/usr/lib/frr/zebra` — AND ALSO `/usr/libexec/frr/zebra`: the
  image ships zebra at BOTH paths; overlaying only /usr/lib silently runs
  the unpatched binary (falsely showed the table-scoped fix not working).
- Live CNO-managed objects get stomped by CNO's sync — hot `oc apply` fixes
  are only good for hypothesis testing; real fixes need the image rebuilt
  (payload tags make that cheap: rebuild + repush + fresh deploy).
- sushy-tools can wedge ("client socket is closed" on Redfish GET → BMHs
  stuck "registering") → `podman restart sushy-tools`.
- Changing NUM_WORKERS requires
  `rm /mnt/nvme0n1p1/dev-scripts/ostest/ironic_nodes.json` + `make configure`
  (stale node count fails install_config).
- Diagnosis pitfall: `ip monitor route` shows NO event for a no-op route
  replace — the kernel only emits netlink events for real changes.
