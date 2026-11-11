## BGP VIP origin e2e tests — implementation plan

Implements design rev 5 (`docs/superpowers/specs/2026-11-09-bgp-vip-origin-tests-design.md`).
Delivered as **openshift/origin#31893** (branch `mkowalski:bgp-vip-origin-tests`).

### Task 1 — suites (done, `b760d1d8b`)

- `pkg/testsuites/standard_suites.go`: `openshift/bgp-vip` (20m) and
  `openshift/bgp-vip/disruptive` (30m, parallelism 1, disruptive), both on
  `source == "openshift:payload:origin"` + the gate tag, split on `[Disruptive]`.
- `TestBGPVIPSuiteSelection` (`pkg/testsuites/suites_test.go`) and
  `TestAppendSuiteNamesBGPVIP` (`pkg/test/extensions/suites_test.go`).

### Task 2 — helpers + unit tests (done)

`test/extended/networking/bgp_vip_util.go`: skip logic, bounded polling,
dynamic-client BGPVIPConfig access, vtysh on nodes and ToR, bounded hypervisor
SSH, the continuous HTTP probe, nftables scripts for the failover cut, MC
`frr-peers.json` timer parsing (never logs the payload), redacted failure dump.
Unit tests in `bgp_vip_util_test.go`.

### Task 3 — tests 1–6 (done)

`test/extended/networking/bgp_vip.go`, frozen It texts per the design.

### Task 4 — tests 7–8 (done)

`test/extended/networking/bgp_vip_disruptive.go`.

### Task 5 — live validation on metal-u15 (done 2026-11-11)

dev-scripts v4v6, 3+2, DevPreviewNoUpgrade, `5.1.0-0.nightly-multi-2026-11-09-143447`.

Findings that changed the code:

- FRR does not renegotiate timers on a frr-k8s reload; test 8 needs the
  `clear bgp *` fallback, and `checkBGPVIPNeighbor` checks the negotiated hold
  time only when asked (it exceeds the new configured value until the reset).
- A session reset or peering cut changes the API VIP's next hops on the
  hypervisor, which resets the test client's pooled connections (the exec reply
  and the framework's namespace delete failed). The reset no longer fails on an
  exec error, and both disruptive tests wait for 3 API answers in a row before
  returning.

Measured: failover withdrawal 6s (budget 45s), 0 failed API probes after the cut
(budget: none after 20s); ingress move 0/76 failed probes per VIP (budget 3).

Build note: build `openshift-tests` with `-trimpath` (or from a GOPATH-shaped
path) — the extension filter keeps only specs whose code location contains
`github.com/openshift/origin/`; a `/src` build lists no origin tests.

### Task 6 — CI lane (branch only, no PR until Mat says so)

openshift/release: step ref `baremetalds-e2e-bgp-vip-origin` running both
suites with the hypervisor JSON; dual-stack workflow; periodic
`e2e-metal-ipi-bgp-vip-dualstack` at `0 3,15 * * *`, v4 lane at
`0 2,14 * * *`; `-techpreview` names at the TP switch.
