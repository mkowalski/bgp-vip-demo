# Patch Series — remaining unmerged code changes, per repository

`git format-patch` series for the BGP VIP management work (enhancement
openshift/enhancements#1982, OPNET-595) that is **not yet merged** upstream
or in openshift. Apply with `git am` onto the documented base. Rationale
for every commit: [../docs/PATCHES.md](../docs/PATCHES.md).

Canonical carriers are the **open PRs** (tracker: docs/NEXT-STEPS.md);
these series are the historical/demo form.

Removed as merged (2026-08): `openshift-api/` (openshift/api#2923),
`dev-scripts/` (openshift-metal3/dev-scripts#1929 + #1939), `frr/`
(0001 SELECTED-flag = upstream b2c17ad52, in FRR 10.7; 0002 table-scoped
early cleanup = FRRouting/frr#22654, fixed upstream via #22676), and
kube-vip 0001/0005/0006 (HTTP health check = upstream #1604, kubeconfig
fixes = kube-vip/kube-vip#1627). Recover from git history if needed:
`git log --diff-filter=D -- patches/`.

## Bases

| Directory | Repository | Apply onto (base SHA) | Open PR |
|---|---|---|---|
| `installer/` | github.com/openshift/installer | `7746340202` (master, 2026-06) | openshift/installer#10718 (OPNET-781) |
| `machine-config-operator/` | github.com/openshift/machine-config-operator | `6a2c5c654` (master, 2026-06) | openshift/machine-config-operator#6326 (OPNET-782) |
| `cluster-network-operator/` | github.com/openshift/cluster-network-operator | `6dc18040e` (master, 2026-06) | openshift/cluster-network-operator#3047 + #3046 (OPNET-783) |
| `kube-vip/` | github.com/kube-vip/kube-vip | upstream main post-#1604/#1627 (gaps in numbering = merged patches) | kube-vip/kube-vip#1636 (re-assert); openshift/kube-vip#6; downstream build bits |
| `baremetal-runtimecfg/` | github.com/openshift/baremetal-runtimecfg | `2f969c7` (master) | openshift/baremetal-runtimecfg#395 (OPNET-785) |

```bash
cd <repo> && git checkout -b bgp-vip <base-sha> && git am -3 <this-repo>/patches/<dir>/*.patch
```

Use `git am -3` (three-way): the kube-vip series has gaps where merged
patches were removed, and bases have drifted since the demo.

## Caveats for appliers

1. **MCO `go.mod` local-path replace** (inside the vendor patch
   `machine-config-operator/0011-*vendor*`): the series pins
   `github.com/openshift/api => /home/kmateusz/git/github.com/openshift-api`.
   The api changes are merged (openshift/api#2923) — drop the vendor
   patches and re-vendor normally from upstream api instead. Same for the
   installer/CNO vendor patches; they are kept only so the series builds
   standalone against the documented bases. The merged api shape drops `""`
   from the `vipManagement` enum — a no-op for the consumers.
2. **History is the debugging story, not a PR series.** MCO includes
   "hardcode kube-vip image" later reverted by the image-resolution commit;
   CNO's commits iterate the advertisement design. The open PRs carry the
   squashed/clean form.
3. **kube-vip**: remaining patches are 0002–0004 (downstream build bits)
   and 0007/0008 (run15-17 route re-assertion + realm toggle). The
   re-assertion pair is **no longer required** — the FRR fix (now upstream)
   alone suffices (proven run18); upstream re-assert lives as
   kube-vip/kube-vip#1636 (single squashed commit), kept here for the demo
   record.
4. Sequencing for real merges: docs/PATCHES.md "Production sequencing".
