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
**UDP and TCP**. On AKS Automatic the answer is **LocalDNS**, a DNS cache on every node (`169.254.10.11`) – not
the CoreDNS pods.
</details>

<details><summary>Hint 4 – When the "textbook" DNS rule doesn't work</summary>

With Azure CNI powered by Cilium, traffic to the node-local LocalDNS listener counts as traffic to the node
itself (the Cilium `host` entity). A Kubernetes NetworkPolicy can't select the node: rules that allow 53 to the
`k8s-app=kube-dns` pods or to `ipBlock` `169.254.10.x` don't match. Either allow port 53 without restricting the
destination, or use a `CiliumNetworkPolicy` with `toEntities: [host]`
([AKS docs](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium#is-aks-local-dns-supported-with-azure-cni-powered-by-cilium)).
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
| **Technical feasibility** | **Medium-high – validated on Azure (2026-10-14).** The fault is deterministic: default-deny egress + an allow rule for the catalog only → `Temporary failure in name resolution`. **AKS Automatic twist:** pods resolve through LocalDNS (node-local `169.254.10.11`), and Cilium treats that traffic as the `host` entity, so the *textbook* fixes – allow 53 to the `kube-dns` pods, or `ipBlock` 169.254.10.x – **do not work** (verified). Working fixes (both verified): a port-only NetworkPolicy rule (UDP/TCP 53, no destination – the end state) or a `CiliumNetworkPolicy` with `toEntities: [host]` (least privilege). `ledger-api` and the internet stay blocked with either. |
| **Validation status** | Fault, fix and scoring validated locally (bash, PowerShell, Terraform) and on AKS Automatic 1.35 in westus3: begin state fails as designed; both fixes pass. |
| **Fit for 200-level users** | **Medium-low without hint 4, medium with it.** "DNS vs connectivity" is a valuable skill, but on AKS Automatic the first fix most people know fails silently, and the reason (LocalDNS + Cilium `host` entity) is advanced. Hint 4 turns it into a solvable – and memorable – platform lesson. |
| **Expected time** | 20–30 min with hints 1–4 (25+ min if participants try `ipBlock`/kube-dns variations first). |
| **Risks** | Participants burning the round on the textbook rule; facilitators should release hint 4 at ~10 minutes. Inspektor Gadget needs privileged pods: AKS Automatic's baseline Pod Security would require a namespace exclusion – keep it optional. |
| **Opinion** | **Alternate for an advanced round, or with hint 4 released early.** Excellent debrief material (LocalDNS, Cilium entities, DNS as an exfiltration path), but A2 or A5 are smoother substitutes for a 200-level core round. |
