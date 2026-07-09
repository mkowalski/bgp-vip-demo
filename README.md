# BGP VIP Management — Dev Demo Workspace

Working demo of [openshift/enhancements#1982](https://github.com/openshift/enhancements/pull/1982)
(OPNET-595/OPNET-773): BGP-based VIP management for on-premise OpenShift —
kube-vip (routing-table mode) + frr-k8s static pods replacing keepalived.

**Status (2026-07-09): COMPLETE — all six demo criteria proven** on a
dev-scripts baremetal IPI cluster (run14): API + Ingress VIPs advertised via
BGP from bootstrap through steady state, health-gated per node, CRD handover
working, console reachable over the BGP-routed path. See
[docs/demo-results.md](docs/demo-results.md).

## Document map

| Doc | Purpose |
|-----|---------|
| [docs/demo-results.md](docs/demo-results.md) | Acceptance evidence + 11 EP-relevant design findings |
| [docs/PATCHES.md](docs/PATCHES.md) | Every commit in every repo, with rationale; payload recipe; production sequencing |
| [docs/RUN-LEDGER.md](docs/RUN-LEDGER.md) | All 14 install runs: what failed, what fixed it (debugging narrative) |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Operational how-to: rebuild images, assemble payload, deploy, verify, debug |
| [docs/NEXT-STEPS.md](docs/NEXT-STEPS.md) | Handoff: productization work, EP corrections, upstreaming, PR strategy |
| [docs/superpowers/specs/](docs/superpowers/specs/) | Original design spec (+ execution addendum) |
| [docs/superpowers/plans/](docs/superpowers/plans/) | Original 18-task implementation plan (+ completion notes) |

## Artifacts in this repo

| Path | What |
|------|------|
| `bgp-tor.sh`, `tor/` | FRR ToR container helper for the hypervisor (up/down/status) |
| `patches/` | **Complete git-am-able patch series for every repository** (openshift-api, installer, MCO, CNO, kube-vip, baremetal-runtimecfg, dev-scripts, FRR backport) — base SHAs + apply caveats in `patches/README.md` |
| `patches/frr/0001-zebra-Do-not-clear-selected-flag-on-route-about-to-b.patch` | FRR backport (upstream b2c17ad52) fixing table-direct redistribution of pre-existing routes |
| `build/` | Dockerfiles used for the demo image builds (incl. the CI-builder tag substitutions) + FRR build script |
| `lab/` | Standalone FRR reproduction lab (4-case matrix) that isolated the zebra bug without a cluster |

## The demo in one picture

```
 install-config.yaml (bgpVIPConfig)
   └─ installer ──► bgp-vip-config ConfigMap ──► MCO (bootstrap file dep / day-2 sync)
                                                  └─► frr-peers.json on masters
 bootstrap/masters:                               └─► static pods: frr-k8s, kube-vip-api, kube-vip-ingress
   kube-vip (health-gated) ──route──► kernel table 198
   frr-k8s zebra (ip import-table 198) ──redistribute table-direct──► bgpd ──► ToR (AS 64513)
 day-2 handover: CNO ──► FRRConfiguration bgp-vip-master ──► static pod controller merges
   (sessions via CRD; advertisement stays on gated redistribution + raw egress permits)
```

## Where the code lives

Canonical carrier: **`patches/` in this repo** (git-am-able series per
repository, with bases). The same content exists on local branches:

| Repo (local path under ~/git/github.com) | Branch |
|---|---|
| openshift-api | `OPNET-595-bgp-vip-management` |
| installer | `OPNET-595-bgp-vip-management-vendored` |
| machine-config-operator | `OPNET-595-bgp-vip-management-dev` |
| cluster-network-operator | `OPNET-595-bgp-vip-management-vendored` |
| kube-vip | `OPNET-595-bgp-vip-management` |
| baremetal-runtimecfg | `OPNET-595-bgp-vip-management` |
| FRR fix | patch file here (no frr source repo locally; built from upstream tag frr-10.4.3) |

Images: `quay.io/mkowalski/{machine-config-operator,cluster-network-operator,baremetal-runtimecfg,kube-vip,cluster-config-api,metallb-frr}:bgp-demo`,
payload `quay.io/mkowalski/ocp-release:bgp-vip-demo`.

Demo environment: `root@metal-u15` (dev-scripts at `/root/dev-scripts`,
demo config `config_root.sh`, previous config preserved as
`config_root.sh.pre-bgp-demo`; ToR helper at `/root/bgp-vip-demo/`).
