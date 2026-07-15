# ART onboarding — ose-kube-vip payload member (OPNET-779)

Status:
- ART Jira FILED: ART-21663.
- CI promotion PR OPEN: openshift/release#81957 (images stanza + promotion
  to ocp/5.0 on main + release-5.0 config with disabled promotion; root
  cause of the missing release-5.0 branch was the test-only onboarding —
  no promotion means repo-brancher and private-org sync ignore the repo).
- ocp-build-data PR OPEN: openshift-eng/ocp-build-data#11838
  (base openshift-5.0, commit bfffc96a, titled ART-21663).

## ART Jira draft (project ART, "New Content Request")

Title: New payload image: ose-kube-vip (BGP-based VIP management, OPNET-595)

- What: add `openshift/ose-kube-vip-rhel9` as a payload member
  (payload tag `kube-vip`).
- Why: BGP-based VIP management for on-prem platforms (enhancement
  openshift/enhancements#1982, feature gate `BGPBasedVIPManagement`,
  DevPreviewNoUpgrade). MCO renders kube-vip static pods and resolves the
  image from the payload; the MCO image-references change (OPNET-782)
  cannot merge until this tag exists, or nightly payload assembly breaks.
- Source repo: github.com/openshift/kube-vip (downstream fork of
  kube-vip/kube-vip; OWNERS present; Dockerfile.openshift builds a static
  Go binary on base-rhel9; prow unit+integration jobs green).
- ocp-build-data config: see PR (images/ose-kube-vip.yml, openshift-5.0
  branch) — modeled on baremetal-runtimecfg (rhel9, gomod, for_payload).
- Contacts: mko@redhat.com (OPNET), team: OpenShift Networking / on-prem.

## Onboarding checklist (ART-side items to confirm in the Jira)

1. openshift-priv/kube-vip mirror creation + DPTP private-org sync
   (openshift/release tooling).
2. release-5.0 branch creation on openshift/kube-vip (branching
   automation; repo currently has `main` only). ci-operator config must
   promote to ocp/5.0 for the nightly to consume it.
3. distgit `ose-kube-vip-container` creation + brew package.
4. Comet/delivery repo `openshift5/ose-kube-vip-rhel9` (delivery section
   in the image config).
5. Ordering: ocp-build-data merge BEFORE openshift/machine-config-operator
   image-references references the `kube-vip` tag (OPNET-782 blocker).

## Notes

- The demo payload used `oc adm release new ... kube-vip=quay.io/...` to
  inject the tag manually; production nightlies need this onboarding.
- Fork carry status at time of writing: upstream #1604 + #1627 merged;
  re-assert PR kube-vip/kube-vip#1636 open; downstream openshift/kube-vip#6
  open. The Dockerfile.openshift and Makefile/go.mod CI tweaks stay
  downstream-only.
