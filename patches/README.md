# Patch Series — all code changes, per repository

Complete `git format-patch` series for every repository touched by the BGP
VIP management demo (enhancement openshift/enhancements#1982, OPNET-595).
Apply with `git am` onto the documented base. Rationale for every commit:
[../docs/PATCHES.md](../docs/PATCHES.md).

## Bases

| Directory | Repository | Apply onto (base SHA) | Produces branch equivalent |
|---|---|---|---|
| `openshift-api/` | github.com/openshift/api | `580f1c1ba` (master, 2026-07) | `opnet-595-bgp-vip-api` — **PR open: openshift/api#2923 (OPNET-780), CI green** |
| `installer/` | github.com/openshift/installer | `7746340202` (master, 2026-06) | `OPNET-595-bgp-vip-management-vendored` |
| `machine-config-operator/` | github.com/openshift/machine-config-operator | `6a2c5c654` (master, 2026-06) | `OPNET-595-bgp-vip-management-dev` |
| `cluster-network-operator/` | github.com/openshift/cluster-network-operator | `6dc18040e` (master, 2026-06) | `OPNET-595-bgp-vip-management-vendored`; statusmanager fix extracted standalone: **PR open: openshift/cluster-network-operator#3046 (OPNET-783)** |
| `kube-vip/` | github.com/kube-vip/kube-vip | `12928dc` (main, 2026-06) | `OPNET-595-bgp-vip-management`; kubeconfig fixes upstream: **PR open: kube-vip/kube-vip#1627** |
| `baremetal-runtimecfg/` | github.com/openshift/baremetal-runtimecfg | `2f969c7` (master) | `OPNET-595-bgp-vip-management`; upstream-clean subset (label-node dropped, rebased on main): **PR open: openshift/baremetal-runtimecfg#395 (OPNET-785)** |
| `dev-scripts/` | github.com/openshift-metal3/dev-scripts | `06759b3` (master, 2026-07) | `bgp-tor-speaker` — **PR open: openshift-metal3/dev-scripts#1929** |
| `frr/` | github.com/FRRouting/frr | tag `frr-10.4.3` | `table-scoped-early-cleanup` on mkowalski/frr — 0001 = backport of upstream `b2c17ad52` (fixed in 10.7), 0002 = 8989c33 table-scoped early cleanup fix (FRRouting/frr#22654, upstream PR to submit) |

```bash
cd <repo> && git checkout -b bgp-vip <base-sha> && git am <this-repo>/patches/<dir>/*.patch
```

Exact base SHAs are also in each patch file's `From <sha>` header lineage —
if `git am` complains, `git am -3` (three-way) resolves minor drift.

## Caveats for appliers

1. **MCO `go.mod` local-path replace** (inside the vendor patch
   `machine-config-operator/0011-*vendor*`): the series pins
   `github.com/openshift/api => /home/kmateusz/git/github.com/openshift-api`.
   After applying the openshift-api series somewhere, point the replace at
   YOUR path (or a pushed fork ref) and re-run `go mod vendor`. This is the
   #1 landmine — see docs/NEXT-STEPS.md §C3.
2. **History is the debugging story, not a PR series.** MCO includes
   "hardcode kube-vip image" later reverted by the image-resolution commit;
   CNO's 15 commits iterate the advertisement design. Squash guidance for
   real PRs: docs/NEXT-STEPS.md §C3.
3. **Vendor patches** (installer/MCO/CNO "vendor openshift/api" commits) are
   included verbatim so the series builds standalone. They carry the DEV-era
   api shape (`vipManagement` enum still permitting `""`); the merged shape
   from openshift/api#2923 drops `""` from the enum — a no-op for the
   consumers (they compare against `"BGP"`). When the api PR merges, drop the
   vendor patches and re-vendor normally; the demo-validated behavior is
   unaffected.
4. **kube-vip** series applies onto upstream `main` (commit above); the fork
   needs the whole series (4 upstreamable fixes + 4 downstream build bits —
   0007/0008 are the run15-17 route re-assertion + realm-toggle fixes).
5. **frr**: apply onto the `frr-10.4.3` tag; TWO patches: 0001 (SELECTED-flag
   backport of upstream b2c17ad52) + 0002 (table-scoped early route queue
   cleanup, our fix for FRRouting/frr#22654 — upstream master still lacks the
   table check; PR to submit). Run18 proved the FRR fixes ALONE suffice —
   the kube-vip realm-toggle workaround is not required with patched zebra.
   Build with `../build/frr-build.sh` in a CentOS Stream 9 container (glibc
   2.34 ABI compatible with the RHEL9 runtime image); overlay via
   `../build/Dockerfile.frr-overlay` (BOTH /usr/lib/frr and /usr/libexec/frr
   zebra paths). Production destiny: frr10 RPM backport (both patches).
6. Sequencing for real merges (api first, ocp-build-data before MCO, etc.):
   docs/PATCHES.md "Production sequencing".
