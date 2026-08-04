# Patch Series — remaining unmerged code changes, per repository

`git format-patch` series for the BGP VIP management work (enhancement
openshift/enhancements#1982, OPNET-595) that is **not yet merged** upstream
or in openshift. Rationale for every commit:
[../docs/PATCHES.md](../docs/PATCHES.md).

Canonical carriers are the **open PRs** (tracker: docs/NEXT-STEPS.md);
these series are the historical/demo form.

Removed as merged (2026-08) — recover with
`git log --diff-filter=D -- patches/`:

- `openshift-api/` — openshift/api#2923
- `dev-scripts/` — openshift-metal3/dev-scripts#1929 + #1939
- `frr/` — 0001 SELECTED-flag = upstream b2c17ad52 (in FRR 10.7); 0002
  table-scoped early cleanup = FRRouting/frr#22654, fixed upstream via #22676
- `kube-vip/` — entire series: 0001 HTTP health check = upstream #1604;
  0005/0006 kubeconfig = kube-vip/kube-vip#1627; 0007/0008 route
  re-assertion + realm toggle = kube-vip/kube-vip#1636 (merged, includes
  the realm logic); 0002–0004 downstream build bits = openshift/kube-vip
  #4/#2/#3
- vendor patches (installer 0005, MCO 0011/0013, CNO 0003) — the api bump
  is merged everywhere (MCO#6334, CNO#3089, installer rebase wave);
  re-vendor from upstream openshift/api instead

## Bases

| Directory | Repository | Apply onto (base SHA) | Open PR |
|---|---|---|---|
| `installer/` | github.com/openshift/installer | `7746340202` (master, 2026-06) | openshift/installer#10718 (OPNET-781) |
| `machine-config-operator/` | github.com/openshift/machine-config-operator | `6a2c5c654` (master, 2026-06) | openshift/machine-config-operator#6326 (OPNET-782) |
| `cluster-network-operator/` | github.com/openshift/cluster-network-operator | `6dc18040e` (master, 2026-06) | openshift/cluster-network-operator#3047 + #3046 (OPNET-783) |
| `baremetal-runtimecfg/` | github.com/openshift/baremetal-runtimecfg | `2f969c7` (master) | openshift/baremetal-runtimecfg#395 (OPNET-785) |

```bash
cd <repo> && git checkout -b bgp-vip <base-sha> && git am -3 <this-repo>/patches/<dir>/*.patch
```

Use `git am -3` (three-way): the series have gaps where merged patches
were removed, and bases have drifted since the demo.

## Caveats for appliers

1. **Vendor patches removed.** The documented bases predate the merged
   openshift/api gate + `vipManagement` + `BGPVIPPeersJSON` (api#2923). To
   build the applied series, vendor a current openshift/api
   (`go get github.com/openshift/api@master && go mod vendor`) — or apply
   onto a current master where the api bump is already vendored (expect
   more `-3` fuzz).
2. **History is the debugging story, not a PR series.** MCO includes
   "hardcode kube-vip image" later reverted by the image-resolution commit;
   CNO's commits iterate the advertisement design. The open PRs carry the
   squashed/clean form.
3. Sequencing for real merges: docs/PATCHES.md "Production sequencing".
