# BGP-VIP + day-2 MetalLB-BGP CI lane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third CI job to openshift/release#82912 that installs the MetalLB operator day-2 in BGP mode via the shared frr-k8s on a BGP-VIP-managed cluster, and verifies the coexistence.

**Architecture:** New step-registry refs `baremetalds-e2e-bgp-vip-metallb-pre` (day-2 operator install: OLM probe → upstream-manifest fallback; MetalLB CR in `frr-k8s-external` mode; pool/peer/advertisement; LB workload) and `baremetalds-e2e-bgp-vip-metallb-verify`, composed into workflow `baremetalds-e2e-bgp-vip-metallb`, wired as optional presubmit `e2e-metal-ipi-bgp-vip-metallb` on openshift/installer. Every behavior is validated on the live metal-u15 cluster (dry run) before the scripts are written from the proven commands.

**Tech Stack:** bash step-registry scripts (ssh-to-hypervisor pattern), oc, podman/vtysh, ci-operator config + prowgen.

**Spec:** `docs/superpowers/specs/2026-08-05-bgp-vip-metallb-lane-design.md` (same repo).

## Global Constraints

- Working repos: `/root/OPNET-595-BGP/git/github.com/openshift-release` (branch `bgp-vip-ovn-bgp-lane`) and `/root/OPNET-595-BGP/git/github.com/bgp-vip-demo` (branch `main`).
- Live cluster: `export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig` on this host (metal-u15). ToR: container `bgp-tor`, host-net, 192.168.111.1, AS 64513. Cluster AS 64512. RA coexistence setup from ledger `coex-1` is live — leave it running (3-producer data point).
- **Do NOT push to any remote in this plan.** Local commits only in openshift-release (user gates the PR push). bgp-vip-demo doc commits may be pushed (established practice).
- All commits: `Assisted-By: Claude Fable 5` trailer, `-s` signoff, `-c core.hooksPath=/dev/null`.
- Script style (review-hardened, from the sibling lane): `set -o nounset -o errexit -o pipefail`, bounded deadlines on every wait (no unbounded `until`), idempotent applies (`--dry-run=client -o yaml | oc apply -f -` for namespaces), `CLI` podman/docker detection for container execs, `curl --fail --show-error`, diagnostics dumped only on timeout.
- IPAddressPool range: `192.168.111.30-192.168.111.50` (established baremetalds range).
- MetalLB CR shape (pinned from metallb-operator `api/v1beta1/metallb_types.go`): `spec.bgpBackend: frr-k8s-external`, `spec.frrk8sConfig.namespace: openshift-frr-k8s`.
- Known fact: this cluster's `redhat-operators` catalog has NO `metallb-operator` packagemanifest → dry run exercises the fallback path; the OLM path stays in the script as the preferred branch.

---

### Task 1: Dry run — day-2 operator install (fallback path) on the live cluster

**Files:**
- Create: `/tmp/opencode/metallb-dryrun/notes.md` (scratch findings; feeds Tasks 4 and 7)

**Interfaces:**
- Produces: a running metallb-operator in `metallb-system`, and in notes.md: the pinned manifest ref (branch/SHA), the exact apply command, CSV/deployment names, any RBAC/SCC surprises.

- [ ] **Step 1: Confirm the OLM probe negative result (goes into the script's if-branch)**

```bash
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
oc get packagemanifest metallb-operator   # expect: NotFound → fallback branch
```

- [ ] **Step 2: Pick the manifest pin**

Check whether the latest release branch supports `frr-k8s-external`:

```bash
curl -s https://raw.githubusercontent.com/metallb/metallb-operator/v0.14/api/v1beta1/metallb_types.go | grep -c "FRRK8sExternalMode"
```

If `>=1`, pin `REF=v0.14`; otherwise pin `REF=main` and record the current main SHA (`gh api repos/metallb/metallb-operator/commits/main --jq .sha`) in notes.md. The deploy manifest is `https://raw.githubusercontent.com/metallb/metallb-operator/${REF}/bin/metallb-operator.yaml`.

- [ ] **Step 3: Deploy the operator**

```bash
oc apply -f "https://raw.githubusercontent.com/metallb/metallb-operator/${REF}/bin/metallb-operator.yaml"
oc rollout status -n metallb-system deploy/metallb-operator-controller-manager --timeout=5m
```

If the deployment name differs, record the actual name in notes.md. If pods fail on SCC/security, record the exact error and the minimal fix (e.g. `oc adm policy add-scc-to-user` target) — the fix must go into the pre-step script, not remain a manual action.

- [ ] **Step 4: Record findings**

Write to `/tmp/opencode/metallb-dryrun/notes.md`: REF chosen, apply command, deployment names, webhook readiness wait needed (yes/no + command), SCC fixes (or "none").

---

### Task 2: Dry run — MetalLB CR in frr-k8s-external mode

**Files:**
- Modify: `/tmp/opencode/metallb-dryrun/notes.md`

**Interfaces:**
- Consumes: running operator from Task 1.
- Produces: MetalLB instance using `openshift-frr-k8s`; notes.md gains: exact CR accepted, controller/speaker deployment+daemonset names, confirmation that NO second frr-k8s got deployed.

- [ ] **Step 1: Apply the MetalLB CR**

```bash
oc apply -f - <<'YAML'
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
spec:
  bgpBackend: frr-k8s-external
  frrk8sConfig:
    namespace: openshift-frr-k8s
YAML
```

If the CR is rejected (older CRD without `bgpBackend`), record the validation error verbatim and re-pin REF (back to Task 1 Step 2 with `main`).

- [ ] **Step 2: Wait for the workload and verify no frr-k8s duplication**

```bash
oc rollout status -n metallb-system deploy/controller --timeout=5m
oc rollout status -n metallb-system ds/speaker --timeout=5m
# must be zero: metallb must NOT deploy its own frr-k8s
oc get ds -n metallb-system | grep -c frr-k8s || echo "no duplicate frr-k8s (good)"
oc get pods -n openshift-frr-k8s | grep -v Running || true   # existing instance undisturbed
```

- [ ] **Step 3: Record findings in notes.md** (deployment/DS names, timings, any events worth encoding as waits)

---

### Task 3: Dry run — BGP objects, workload, ToR verification

**Files:**
- Modify: `/tmp/opencode/metallb-dryrun/notes.md`

**Interfaces:**
- Consumes: MetalLB instance from Task 2.
- Produces: LB service IP advertised at ToR + working datapath; notes.md gains: LB IP, path count at ToR, MetalLB-owned FRRConfiguration names in `openshift-frr-k8s`, session count delta (must be zero new sessions — same-neighbor merge).

- [ ] **Step 1: Snapshot pre-MetalLB session state at the ToR**

```bash
podman exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary json' | jq '[.peers[] | select(.state=="Established")] | length'
# record the number (expect 5: one per node, from the VIP + RA setup)
```

- [ ] **Step 2: Apply pool, peer, advertisement**

```bash
oc apply -f - <<'YAML'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: bgp-vip-lane-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.111.30-192.168.111.50
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: tor
  namespace: metallb-system
spec:
  peerAddress: 192.168.111.1
  peerASN: 64513
  myASN: 64512
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-vip-lane-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - bgp-vip-lane-pool
YAML
```

- [ ] **Step 3: Deploy the LB workload**

```bash
oc create deployment lb-echo --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --replicas=2 -- /agnhost netexec --http-port=8080
oc expose deployment lb-echo --type=LoadBalancer --port=8080 --name=lb-echo
LB_IP=""
deadline=$((SECONDS + 180))
until LB_IP="$(oc get svc lb-echo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" && [ -n "$LB_IP" ]; do
  (( SECONDS >= deadline )) && { oc describe svc lb-echo; break; }
  sleep 5
done
echo "LB_IP=${LB_IP}"
```

- [ ] **Step 4: Verify merge, advertisement, datapath**

```bash
# (a) MetalLB-owned FRRConfigurations exist in the shared namespace
oc get frrconfiguration -n openshift-frr-k8s -l app=metallb   # record actual label/names
# (b) same-neighbor merge: STILL the same number of Established sessions as Step 1 (no new/dup sessions)
podman exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary json' | jq '[.peers[] | select(.state=="Established")] | length'
# (c) LB /32 at the ToR with one path per frr-k8s-bearing node (5)
podman exec bgp-tor vtysh -c "show ip bgp ${LB_IP}/32" | sed -n 's/^Paths: (\([0-9]*\) available.*/\1/p'
# (d) datapath from hypervisor over the BGP-installed kernel route
ip route get "${LB_IP}"                       # expect: via the ToR-learned path
curl --fail --show-error --max-time 20 -s "http://${LB_IP}:8080/hostname"
# (e) VIP regression: re-run the existing verify
bash /tmp/opencode/verify-vip-local.sh
```

If (b) shows NEW sessions from the nodes: that's a real finding (frr-k8s rendered a second neighbor instead of merging) — record exact FRRConfiguration content and stop for review; the EP claims merge.

- [ ] **Step 5: Record all findings in notes.md** (LB IP, counts, label selector for MetalLB CRs, exact wait durations observed)

---

### Task 4: Write the pre-step ref

**Files:**
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/pre/baremetalds-e2e-bgp-vip-metallb-pre-commands.sh`
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/pre/baremetalds-e2e-bgp-vip-metallb-pre-ref.yaml`
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/pre/OWNERS` (copy of `ci-operator/step-registry/baremetalds/e2e/bgp-vip/OWNERS`)

**Interfaces:**
- Consumes: dry-run notes (`/tmp/opencode/metallb-dryrun/notes.md`) for REF pin, names, waits.
- Produces: ref `baremetalds-e2e-bgp-vip-metallb-pre` (from: dev-scripts); creates `metallb-system` operator + MetalLB CR + pool/peer/adv + `lb-echo` Deployment/Service consumed by the verify step.

- [ ] **Step 1: Write the script**

Shape (fill names/waits from notes.md; the heredoc-over-ssh wrapper is identical to `bgp-vip/verify/baremetalds-e2e-bgp-vip-verify-commands.sh`):

```bash
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip metallb pre command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" "METALLB_OPERATOR_REF='${METALLB_OPERATOR_REF}'" bash -x - << 'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

# --- install the operator: OLM (customer path) first, upstream manifests as fallback
if oc get packagemanifest metallb-operator &>/dev/null; then
  echo "metallb-operator found in the catalog: installing via OLM"
  oc create namespace metallb-system --dry-run=client -o yaml | oc apply -f -
  oc label namespace metallb-system openshift.io/cluster-monitoring=true --overwrite
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator
  namespace: metallb-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  deadline=$((SECONDS + 900))
  until [ "$(oc get csv -n metallb-system -o jsonpath='{.items[?(@.spec.displayName=="MetalLB Operator")].status.phase}' 2>/dev/null)" = "Succeeded" ]; do
    if (( SECONDS >= deadline )); then
      oc get csv,subscription,installplan -n metallb-system || true
      echo "Timed out waiting for the MetalLB operator CSV" >&2
      exit 1
    fi
    sleep 15
  done
else
  echo "metallb-operator not in any catalog: deploying upstream manifests (${METALLB_OPERATOR_REF})"
  oc apply -f "https://raw.githubusercontent.com/metallb/metallb-operator/${METALLB_OPERATOR_REF}/bin/metallb-operator.yaml"
  oc rollout status -n metallb-system deploy/metallb-operator-controller-manager --timeout=10m
fi

# --- MetalLB in external frr-k8s mode: reuse the cluster's openshift-frr-k8s
#     (static pods on masters, CNO DaemonSet on workers)
oc apply -f - <<'YAML'
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
spec:
  bgpBackend: frr-k8s-external
  frrk8sConfig:
    namespace: openshift-frr-k8s
YAML
oc rollout status -n metallb-system deploy/controller --timeout=10m
oc rollout status -n metallb-system ds/speaker --timeout=10m

# --- BGP objects: peer with the existing ToR; frr-k8s must merge this into
#     the neighbor already declared by the bgp-vip FRRConfiguration
oc apply -f - <<'YAML'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: bgp-vip-lane-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.111.30-192.168.111.50
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: tor
  namespace: metallb-system
spec:
  peerAddress: 192.168.111.1
  peerASN: 64513
  myASN: 64512
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-vip-lane-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - bgp-vip-lane-pool
YAML

# --- LoadBalancer workload the verify step curls
oc create deployment lb-echo --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
  --replicas=2 --dry-run=client -o yaml -- /agnhost netexec --http-port=8080 | oc apply -f -
oc expose deployment lb-echo --type=LoadBalancer --port=8080 --name=lb-echo \
  --dry-run=client -o yaml | oc apply -f -
EOF
```

Adjust from notes.md: deployment names, extra waits, SCC fixes, MetalLB CR corrections. If the dry run found the OLM branch untestable (no catalog entry), keep the branch as written — it is the documented customer path and the CSV displayName check comes from the existing `operatorhub-subscribe-metallb-operator` ref.

- [ ] **Step 2: Write the ref yaml**

```yaml
ref:
  as: baremetalds-e2e-bgp-vip-metallb-pre
  from: dev-scripts
  commands: baremetalds-e2e-bgp-vip-metallb-pre-commands.sh
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
  grace_period: 10m
  env:
  - name: METALLB_OPERATOR_REF
    default: "v0.14"
    documentation: |-
      Git ref of metallb/metallb-operator whose bin/metallb-operator.yaml is
      applied when no metallb-operator packagemanifest exists in the cluster
      catalogs (e.g. pre-release OCP). Ignored when the OLM path is taken.
  documentation: |-
    Day-2 installs the MetalLB operator (OLM when the catalog carries it,
    upstream manifests otherwise) on a cluster deployed with BGP-based VIP
    management, configures MetalLB in frr-k8s-external mode against the
    cluster's openshift-frr-k8s instance (frr-k8s static pods on the control
    plane), creates an IPAddressPool/BGPPeer/BGPAdvertisement peering with
    the same top-of-rack FRR speaker that serves the VIPs, and deploys a
    LoadBalancer-type workload for the verify step.
```

(Replace the `default:` with the REF pinned in Task 1.)

- [ ] **Step 3: Validate + commit (local only)**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-release
bash -n ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/pre/baremetalds-e2e-bgp-vip-metallb-pre-commands.sh
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/**/*.yaml', recursive=True)]; print('ok')"
git add ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/pre
git -c core.hooksPath=/dev/null commit -s -m "bgp-vip/metallb: add day-2 MetalLB install pre step

Assisted-By: Claude Fable 5"
```

---

### Task 5: Write the verify-step ref and validate it on the live cluster

**Files:**
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/verify/baremetalds-e2e-bgp-vip-metallb-verify-commands.sh`
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/verify/baremetalds-e2e-bgp-vip-metallb-verify-ref.yaml`
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/verify/OWNERS` (copy of `ci-operator/step-registry/baremetalds/e2e/bgp-vip/OWNERS`)

**Interfaces:**
- Consumes: `lb-echo` Service, `bgp-vip-lane-pool`, MetalLB instance (Task 4 objects); MetalLB FRRConfiguration label recorded in Task 3.
- Produces: ref `baremetalds-e2e-bgp-vip-metallb-verify`.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip metallb coexistence verify command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash -x - << 'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

CLI="podman"
if ! command -v podman &>/dev/null; then
    CLI="docker"
fi

FAILURES=0
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

# poll <deadline-seconds> <function> — re-evaluate until success or timeout
poll() {
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 10
    done
}

nodes="$(oc get nodes -o name | wc -l)"

echo "[1/4] MetalLB is deployed and produced FRRConfigurations in openshift-frr-k8s"
check_metallb() {
    [[ "$(oc get deploy -n metallb-system controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ]] \
        && [[ "$(oc get frrconfiguration -n openshift-frr-k8s -o name | grep -c metallb)" -ge 1 ]]
}
if ! poll 300 check_metallb; then
    oc get deploy,ds -n metallb-system || true
    oc get frrconfiguration -n openshift-frr-k8s || true
    fail "MetalLB not deployed or no MetalLB-owned FRRConfiguration in openshift-frr-k8s"
fi

echo "[2/4] same-neighbor merge: still exactly one Established ToR session per node"
check_sessions() {
    local established
    established="$(${CLI} exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary json' \
        | jq '[.peers[] | select(.state=="Established")] | length')"
    [[ "${established:-0}" -eq "${nodes}" ]]
}
if ! poll 300 check_sessions; then
    ${CLI} exec bgp-tor vtysh -c 'show bgp ipv4 unicast summary' || true
    fail "ToR does not have exactly ${nodes} Established sessions (MetalLB must merge into the existing neighbor, not add or flap sessions)"
fi

echo "[3/4] the LoadBalancer service IP is advertised to the ToR from every frr-k8s node"
lb_ip=""
get_lb_ip() {
    lb_ip="$(oc get svc lb-echo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
    [[ -n "${lb_ip}" ]]
}
if ! poll 180 get_lb_ip; then
    oc describe svc lb-echo || true
    fail "lb-echo never received a LoadBalancer IP from the pool"
else
    check_lb_paths() {
        local paths
        paths="$(${CLI} exec bgp-tor vtysh -c "show ip bgp ${lb_ip}/32" \
            | sed -n 's/^Paths: (\([0-9]*\) available.*/\1/p')"
        [[ "${paths:-0}" -eq "${nodes}" ]]
    }
    if ! poll 300 check_lb_paths; then
        ${CLI} exec bgp-tor vtysh -c "show ip bgp ${lb_ip}/32" || true
        fail "LB IP ${lb_ip}/32 does not have ${nodes} BGP paths at the ToR"
    fi
fi

echo "[4/4] datapath: the LB service answers over the BGP-routed path"
if [[ -n "${lb_ip}" ]]; then
    if curl --fail --show-error --max-time 20 -s "http://${lb_ip}:8080/hostname"; then
        echo "LB service reachable over BGP"
    else
        ip route get "${lb_ip}" || true
        fail "LB service ${lb_ip}:8080 not reachable from the hypervisor"
    fi
fi

if [[ "${FAILURES}" -ne 0 ]]; then
    echo "BGP VIP + MetalLB coexistence verification failed with ${FAILURES} error(s)"
    exit 1
fi
echo "BGP VIP + MetalLB coexistence verification passed"
EOF
```

Adjust `grep -c metallb` selector to the actual FRRConfiguration naming/label recorded in Task 3 notes.

- [ ] **Step 2: Write the ref yaml**

```yaml
ref:
  as: baremetalds-e2e-bgp-vip-metallb-verify
  from: dev-scripts
  commands: baremetalds-e2e-bgp-vip-metallb-verify-commands.sh
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
  grace_period: 10m
  documentation: |-
    Verifies coexistence of BGP-based VIP management and a day-2 MetalLB
    (frr-k8s-external mode): MetalLB produced FRRConfigurations in
    openshift-frr-k8s, the ToR still has exactly one merged Established
    session per node, the LoadBalancer service IP is advertised from every
    frr-k8s-bearing node, and the service answers over the BGP-routed path.
```

- [ ] **Step 3: Run the verify against the live cluster**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-release/ci-operator/step-registry/baremetalds/e2e/bgp-vip
sed -n '/^ssh /,/^EOF$/p' metallb/verify/baremetalds-e2e-bgp-vip-metallb-verify-commands.sh | sed '1d;$d' > /tmp/opencode/verify-metallb-local.sh
bash /tmp/opencode/verify-metallb-local.sh
```

Expected: exit 0, all four checks pass (cluster state from Tasks 1-3). Also re-run `bash /tmp/opencode/verify-vip-local.sh` (VIP regression) and `bash /tmp/opencode/verify-coex-local2.sh` (OVN-K RA still green → 3-producer proof). All three must pass.

- [ ] **Step 4: Commit (local only)**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-release
bash -n ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/verify/baremetalds-e2e-bgp-vip-metallb-verify-commands.sh
git add ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/verify
git -c core.hooksPath=/dev/null commit -s -m "bgp-vip/metallb: add coexistence verify step

Assisted-By: Claude Fable 5"
```

---

### Task 6: Workflow, metadata, installer wiring, generators

**Files:**
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/baremetalds-e2e-bgp-vip-metallb-workflow.yaml`
- Create: `ci-operator/step-registry/baremetalds/e2e/bgp-vip/metallb/OWNERS` (copy of `ci-operator/step-registry/baremetalds/e2e/bgp-vip/OWNERS`)
- Modify: `ci-operator/config/openshift/installer/openshift-installer-main.yaml` (after the `e2e-metal-ipi-bgp-vip-ovn-bgp` test entry)
- Generated: `ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml`, `*-metadata.json` files (via make targets — never hand-edit jobs)

**Interfaces:**
- Consumes: refs from Tasks 4-5 (`baremetalds-e2e-bgp-vip-metallb-pre`, `baremetalds-e2e-bgp-vip-metallb-verify`) and existing `baremetalds-e2e-bgp-vip-verify`.
- Produces: workflow `baremetalds-e2e-bgp-vip-metallb`; job `e2e-metal-ipi-bgp-vip-metallb`.

- [ ] **Step 1: Write the workflow**

```yaml
workflow:
  as: baremetalds-e2e-bgp-vip-metallb
  steps:
    cluster_profile: equinix-ocp-metal
    env:
      DEVSCRIPTS_CONFIG: |
        IP_STACK=v4
        NUM_WORKERS=2
        ENABLE_BGP_TOR=true
        BGP_VIP_MANAGEMENT=true
      FEATURE_SET: DevPreviewNoUpgrade
    pre:
      - ref: baremetalds-devscripts-conf-featureset
      - chain: baremetalds-ofcir-pre
      - ref: baremetalds-e2e-bgp-vip-metallb-pre
    test:
      - ref: baremetalds-e2e-bgp-vip-verify
      - ref: baremetalds-e2e-bgp-vip-metallb-verify
    post:
      - chain: baremetalds-ofcir-post
  documentation: |-
    Coexistence lane for BGP-based VIP management (enhancement 1982) and a
    day-2 MetalLB operator in BGP mode. Installs a baremetal IPI cluster via
    dev-scripts with BGP_VIP_MANAGEMENT=true, then installs the MetalLB
    operator day-2 (OLM when the catalog carries it, upstream manifests
    otherwise) configured in frr-k8s-external mode against the cluster's
    openshift-frr-k8s instance and peering with the same top-of-rack FRR
    speaker that serves the VIPs. Verification asserts the VIP acceptance
    criteria still hold and that MetalLB's FRRConfigurations merged into the
    existing ToR neighbor (no session duplication or flap) with the
    LoadBalancer service IP advertised from every node and reachable over
    the BGP path. No conformance suite: MetalLB's own e2e machinery needs
    source checkouts and would drown the coexistence signal.
```

- [ ] **Step 2: Wire the installer job**

In `ci-operator/config/openshift/installer/openshift-installer-main.yaml`, insert directly after the `e2e-metal-ipi-bgp-vip-ovn-bgp` entry:

```yaml
- always_run: false
  as: e2e-metal-ipi-bgp-vip-metallb
  capabilities:
  - intranet
  optional: true
  steps:
    cluster_profile: equinix-ocp-metal
    workflow: baremetalds-e2e-bgp-vip-metallb
```

- [ ] **Step 3: Run the generators and validations**

```bash
cd /root/OPNET-595-BGP/git/github.com/openshift-release
make jobs
make registry-metadata
make ci-operator-checkconfig
```

Expected: job appears in `openshift-installer-main-presubmits.yaml`; checkconfig exits 0. (`make validate-step-registry` is known-broken on HEAD — do not use it as a gate.)

- [ ] **Step 4: Commit (local only — DO NOT push)**

```bash
git add -A
git -c core.hooksPath=/dev/null commit -s -m "installer: add e2e-metal-ipi-bgp-vip-metallb day-2 coexistence lane

Third bgp-vip lane: day-2 MetalLB operator install (OLM with upstream
manifest fallback) in frr-k8s-external mode on a BGP-VIP-managed cluster,
peering with the existing ToR. Verifies the same-neighbor
FRRConfiguration merge (no session duplication), LoadBalancer IP
advertisement from every node, datapath over the BGP route, and that the
VIP acceptance criteria still hold. Validated end to end against a live
dev-scripts cluster before submission.

Assisted-By: Claude Fable 5"
```

---

### Task 7: Documentation (bgp-vip-demo)

**Files:**
- Modify: `docs/RUN-LEDGER.md` (new row `coex-2` after `coex-1`)
- Modify: `docs/NEXT-STEPS.md` (§E1: add the MetalLB lane result + pending-push state)

**Interfaces:**
- Consumes: notes.md findings, verify outputs from Task 5 Step 3.

- [ ] **Step 1: Add ledger row `coex-2`**

Content requirements (table row, same three-column format as coex-1): date, what was run (day-2 MetalLB via which install path + REF, frr-k8s-external CR, pool/peer/adv, lb-echo), the results (FRRConfiguration merge outcome, session count stable, LB /32 path count, datapath, VIP + RA verifies still green → three FRRConfiguration producers coexisting), findings (anything from notes.md: SCC fixes, CR shape surprises, wait durations), and the cluster end-state + revert recipe (delete MetalLB objects + operator manifests, `oc delete deploy/svc lb-echo`).

- [ ] **Step 2: Update NEXT-STEPS §E1**

Add below the ovn-bgp dry-run bullet: MetalLB lane implemented per spec `2026-08-05-bgp-vip-metallb-lane-design.md`, dry-run results, and "commits staged locally on `bgp-vip-ovn-bgp-lane`, push to release#82912 pending user approval".

- [ ] **Step 3: Commit and push (bgp-vip-demo only)**

```bash
cd /root/OPNET-595-BGP/git/github.com/bgp-vip-demo
git add docs/RUN-LEDGER.md docs/NEXT-STEPS.md
git -c core.hooksPath=/dev/null commit -s -m "docs: coex-2 — day-2 MetalLB-BGP coexistence proven; lane staged

Assisted-By: Claude Fable 5"
git push origin main
```

---

## Self-review (done at plan time)

- Spec coverage: workflow shape (T6), pre step incl. OLM/fallback/CR/objects/workload (T4), verify assertions 1-5 (T5; VIP regression via existing ref in workflow), risks → dry-run tasks (T1-T3), validation sequence (T1-T3 before T4-T6, ledger in T7). Push embargo honored (T6 commits local; explicit DO NOT push).
- No placeholders: all YAML/commands concrete; the two empirically-bound values (operator REF, FRRConfiguration label) have explicit discovery steps (T1S2, T3S4) and explicit consumers (T4S2, T5S1).
- Naming consistent: `baremetalds-e2e-bgp-vip-metallb{,-pre,-verify}`, `bgp-vip-lane-pool`, `bgp-vip-lane-adv`, `lb-echo`, `tor` used identically across tasks.
