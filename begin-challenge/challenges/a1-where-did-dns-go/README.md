# A1 · Where did DNS go?

| | |
|---|---|
| **Round** | Preferred alternate · Intermediate |
| **Namespace** | `a1-inventory` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | AKS Automatic (Azure CNI powered by Cilium enforces NetworkPolicy; LocalDNS) |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> After a network-isolation change, `inventory-sync` can no longer reach the catalog API it depends on.
> Restore access **without opening unrestricted egress** – `inventory-sync` must still be unable to reach
> anything other than what it needs (for example the `ledger-api` or the internet).

## Learning objective

Separate DNS, connectivity and application failure; repair network policy without removing isolation.

## What's running

* `inventory-sync` – syncs the catalog every few seconds; logs every attempt and serves its last result at
  `/status`.
* `catalog-api` – the dependency `inventory-sync` is allowed to call.
* `ledger-api` – a sensitive service `inventory-sync` must **not** reach.
* NetworkPolicies from change CHG-1150.

```bash
kubectl get pods,svc,networkpolicy -n a1-inventory
kubectl logs -n a1-inventory deploy/inventory-sync --tail=5
```

The `inventory-sync` image includes `curl` and `getent` for testing from inside the pod:
`kubectl exec -n a1-inventory deploy/inventory-sync -- getent hosts catalog-api`.

## Success criteria

Tested **from inside `inventory-sync`** (so its policy applies):

1. Name resolution works and the application transaction (`GET http://catalog-api:8080/items`) succeeds.
2. A prohibited destination is still blocked (`ledger-api`, the internet).
3. Namespace isolation remains: `default-deny-egress` is unchanged and no policy allows unrestricted egress.
4. You did not edit cluster-wide DNS (CoreDNS / kube-system) or delete the policies.

```bash
scoring/verify.sh --challenges a1          # bash
./scoring/verify.ps1 -Challenges a1        # PowerShell
```

## Hints

<details><summary>Hint 1 – Test name resolution independently</summary>

Does the name resolve? Does the service answer if you skip DNS?
`kubectl exec ... -- getent hosts catalog-api` vs.
`kubectl exec ... -- curl -s -m 3 http://$(kubectl get svc catalog-api -n a1-inventory -o jsonpath='{.spec.clusterIP}'):8080/items`.
</details>

<details><summary>Hint 2 – Inspect the workload's effective egress policy</summary>

Which policies select the `inventory-sync` pod? `kubectl get networkpolicy -n a1-inventory -o yaml` – egress
from a pod is allowed only if *some* policy selecting it allows that destination and port.
</details>

<details><summary>Hint 3 – Compare DNS traffic and destinations with the allow rules</summary>

Where does the pod actually send DNS queries? `kubectl exec ... -- cat /etc/resolv.conf`. DNS uses port 53 over
**UDP and TCP**. On AKS Automatic, LocalDNS answers on a node-local address; elsewhere CoreDNS (`k8s-app=kube-dns`
in `kube-system`) does.
</details>

## What doesn't count

* Deleting `default-deny-egress` or `inventory-sync-egress`, or adding an "allow all egress" rule.
* Allowing all UDP (or all ports) to everywhere, editing CoreDNS, or changing the app to use IP addresses.

## Stretch objective

Explain why opening all UDP traffic or deleting the policy fixes the symptom but fails the security requirement.
(Optional: trace DNS with Inspektor Gadget, e.g. `kubectl gadget run trace_dns -n a1-inventory`, if it is
available in your environment.)

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a1
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a1
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **Medium – depends on the Azure pilot.** On a standard cluster (validated locally with an enforcing CNI) the fault and fix are deterministic: default-deny egress + an allow rule for the catalog only → `Temporary failure in name resolution`; adding UDP/TCP 53 to the DNS path fixes it while `ledger-api` and the internet stay blocked. **AKS Automatic enables LocalDNS by default** (pods resolve through a node-local listener, 169.254.10.10/11). With Cilium that destination may be treated as the *host*, which Kubernetes `ipBlock` rules may not match. Whether the seeded policy blocks DNS, and which allow rule fixes it, must be confirmed on AKS Automatic. The end-state policy allows 53 to both the LocalDNS addresses and the kube-dns pods. |
| **Validation status** | Fault, fix and scoring validated locally with bash, PowerShell and Terraform. **Pending Azure pilot (critical):** DNS path under LocalDNS + Cilium. If `ipBlock` does not match, switch the expected fix to a port-only DNS rule or a `CiliumNetworkPolicy` (`toEntities: [host]` / `toFQDNs` needs ACNS). |
| **Fit for 200-level users** | Medium. The symptom is clear and "DNS vs connectivity" is a valuable skill, but writing NetworkPolicy YAML correctly (selectors, UDP *and* TCP, namespaceSelector + podSelector in one peer) is error-prone, and LocalDNS is unfamiliar even to experienced users. |
| **Expected time** | 20–30 min; risk of overrun if the LocalDNS nuance bites. |
| **Risks** | Platform-specific DNS behaviour (above). Inspektor Gadget needs privileged pods: AKS Automatic's baseline Pod Security would require a namespace exclusion – keep it optional. |
| **Opinion** | **Strong alternate only if the pilot shows deterministic behaviour with a simple, explainable fix.** Otherwise prefer A2 or A5 as the alternate. |
