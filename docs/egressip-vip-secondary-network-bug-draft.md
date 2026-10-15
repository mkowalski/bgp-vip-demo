# Jira draft — NOT FILED

**Project**: OCPBUGS  
**Component**: Networking / ovn-kubernetes  
**Severity**: Medium (silent misassignment, but requires a VIP with a non-host prefix; the common `/32` VIP case is blocked by a different check)  
**Affects**: 4.16+ (all versions with secondary-host-network EgressIP, `1f52e7d33`), including 5.0/5.1  
**Related**: OCPBUGS-130338 (same root assumption, VTEP selection), OCPBUGS-29851, NGC-638 (EgressIP + MetalLB VRF coexistence)

## Summary

EgressIP cluster-manager treats host VIPs as secondary host networks and reports an EgressIP as Assigned that no node programs

## Description

### Description of problem

The cluster-manager EgressIP controller derives a node's "secondary host networks" from the `k8s.ovn.org/host-cidrs` annotation minus the exact string of `k8s.ovn.org/node-primary-ifaddr` (`util.ParseNodeHostCIDRsExcludeOVNNetworks` → `GetSecondaryHostNetworkContainingIP`). `host-cidrs` deliberately contains **every** address on the host, including VIPs owned by keepalived, kube-vip and MetalLB (see `0dddfd883`, `5c6edd627` — VIPs must stay in `host-cidrs` for the no-reroute policies). So every VIP, and on IPv6 even the node's own address (`::38/128` in `host-cidrs` vs `::38/120` in `node-primary-ifaddr` — different string), is classified as a secondary host network.

The node side uses a **different, stricter** selection (`getFilteredPrefixes` → `util.GetFilteredInterfaceAddrs`), which excludes keepalived-labelled, `IFA_F_SECONDARY` and `IFA_F_DEPRECATED` addresses and single-host (`/32`, `/128`) networks. The two sides disagree.

Consequences:

1. **VIP with a non-host prefix** (keepalived configured with a subnet mask, or any `deprecated` address with a real prefix on the gateway bridge): an EgressIP from that range is accepted by cluster-manager ("Successful assignment of egress IP X to network <VIP net>"), `status.items` says Assigned, **but the node silently programs nothing** — no address on the link, no OVN NAT, no nftables/iptables rule. `findLinkOnSameNetworkAsIP` returns `found=false` and the node code path does `continue` without an error or event. Pods selected by that EgressIP egress with their default SNAT, while the API reports the EgressIP as active. Second-order: cluster-manager will reject the same IP for other nodes as "already allocated".

2. **VIP with a host prefix** (`/32`/`/128` — kube-vip RT mode, keepalived default, MetalLB L2): the misclassification exists but is masked because `isEgressIPAddrConflict` (which reads the same `host-cidrs`) rejects the VIP address itself first, and a `/32` network contains only that address. This is ordering-dependent protection, not a design guarantee: downstream release-5.1 already relaxed `isEgressIPAddrConflict` to skip nodes with unparseable annotations.

3. The IPv6 node address itself being treated as a secondary network is harmless today for the same reason as (2), but makes the annotation-derived model wrong on every dual-stack node.

### Version-Release number of selected component

Reproduced on 5.1.0-0.nightly-2026-10-06-091356 with ovn-kubernetes at 00e4e2b2a (plus the OCPBUGS-130338 fix, which is unrelated to this path). Code is identical on upstream master `cca0923d6` and `openshift/ovn-kubernetes` release-5.1.

### How reproducible

Always.

### Steps to Reproduce

On a bare-metal cluster with a worker labelled `k8s.ovn.org/egress-assignable=""`:

1. Emulate a VIP with a subnet prefix on the gateway bridge (this is what keepalived does when given a mask, and `preferred_lft 0` is how kube-vip marks its VIPs):
   ```
   ip addr add 10.199.0.5/24 dev br-ex preferred_lft 0
   ```
   Observe `k8s.ovn.org/host-cidrs` on the node now contains `"10.199.0.5/24"`; `node-primary-ifaddr` is unchanged.
2. Create an EgressIP in that range:
   ```yaml
   apiVersion: k8s.ovn.org/v1
   kind: EgressIP
   metadata: {name: probe}
   spec:
     egressIPs: ["10.199.0.77"]
     namespaceSelector: {matchLabels: {app: whatever}}
   ```
3. Inspect:
   ```
   oc get egressip probe -o jsonpath='{.status}'
   ip -o addr show br-ex | grep 10.199.0.77
   ovn-nbctl lr-nat-list GR_<node> | grep 10.199.0.77
   nft list ruleset | grep 10.199.0.77
   ```

### Actual results

```
status: {"items":[{"egressIP":"10.199.0.77","node":"ostest-worker-0"}]}
cluster-manager: Successful assignment of egress IP: 10.199.0.77 to network 10.199.0.0/24 on node: ostest-worker-0
node br-ex has 10.199.0.77: 0
OVN NAT for 10.199.0.77: 0
node nft/iptables rules for 10.199.0.77: 0
ovnkube-node log: "Adding Egress IP probe" / "Processing Egress IP probe" — no error, no event
```

Control cases on the same node, same run:
- EgressIP `192.168.111.4` (the Ingress VIP, `/32`): correctly rejected — `EgressIPConflict: conflicting with a host (ostest-worker-0) IP address`.
- EgressIP `192.168.111.200` (node subnet): correctly assigned to the OVN network, address added to br-ex, GARP sent.

### Expected results

Either the cluster-manager refuses to assign `10.199.0.77` (no eligible secondary host network — matching what the node would decide), or the node reports the failure (error + event) instead of leaving the EgressIP in a claimed-Assigned, not-programmed state.

### Additional info

Suggested fix (small): make cluster-manager apply the same eligibility rules the node already applies.

- In `GetSecondaryHostNetworkContainingIP` / `ParseNodeHostCIDRsExcludeOVNNetworks`:
  - drop single-host prefixes (`/32`, `/128`) — mirrors node-side `isOneIPNetwork`;
  - exclude the primary-ifaddr by **address containment**, not string equality, so `::38/128` vs `::38/120` collapse.
- Longer term: `host-cidrs` cannot express "this address is a VIP" (the flags are lost at annotation time). Any consumer that *selects* a network/address from it — this path, and VTEP discovery (OCPBUGS-130338) — needs that information. Options: a sibling annotation listing VIP/deprecated addresses, or a shared `IsHostVIP`-style helper consulted on the node before annotating. Both bugs are the same root assumption ("every host-cidrs entry is the node's own stable address") and are best fixed by one owner.
- Also worth considering independently: the node-side `if !found { continue }` in `pkg/node/controllers/egressip/egressip.go` (both call sites) swallows the mismatch. An event on the EgressIP object would have made this visible.

Verified on the live cluster 2026-10-15; all probe objects, the emulated address and the egress-assignable label were removed afterwards.

---
This bug report was generated using AI. Please verify before acting on it.
