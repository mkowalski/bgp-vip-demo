# ART onboarding — ose-kube-vip payload member (OPNET-779)

Status: ocp-build-data config DRAFTED, branch `ose-kube-vip` on
mkowalski/ocp-build-data (commit bfffc96a, based on upstream/openshift-5.0).
PR to openshift-eng/ocp-build-data and the ART Jira: to be filed by Mat.

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
