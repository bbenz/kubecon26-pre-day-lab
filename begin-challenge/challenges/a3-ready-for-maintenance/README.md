# A3 · Ready for maintenance?

| | |
|---|---|
| **Round** | Reserve · Intermediate–advanced (no real cluster upgrade) |
| **Namespace** | `a3-maintenance` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | AKS Automatic only |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> Node maintenance is scheduled for tonight, and the pre-maintenance check shows that `inventory-api` cannot
> tolerate a voluntary disruption. Make it maintenance-ready **without accepting an avoidable outage**.
>
> Availability requirement: at least **one** replica of `inventory-api` must keep serving requests at all times,
> including during maintenance.

## Learning objective

Understand disruption budgets and workload availability; prepare an application for maintenance safely.

## What's running

* `inventory-api` (Deployment + Service) and its PodDisruptionBudget.
* `maintenance-check` – a suspended CronJob you trigger on demand. It performs **one controlled voluntary
  eviction** of an `inventory-api` pod (the Eviction API, the same call `kubectl drain` makes) while sending
  synthetic requests, and reports PASS/FAIL. The Job `pre-maintenance-check` shows the result after the last
  deployment.

```bash
kubectl get deploy,pdb,pods,cronjob -n a3-maintenance
kubectl logs -n a3-maintenance job/pre-maintenance-check
# run the check again after a change:
kubectl create job -n a3-maintenance --from=cronjob/maintenance-check check-1
kubectl logs -n a3-maintenance -f job/check-1
```

## Success criteria

1. A controlled eviction of an `inventory-api` pod is **accepted**.
2. Synthetic requests keep succeeding during the disruption (0 failures).
3. The workload returns to its target replica count.
4. The disruption budget still protects the application (not deleted, not set to allow everything) and no pod is
   force-deleted.

```bash
scoring/verify.sh --challenges a3          # bash
./scoring/verify.ps1 -Challenges a3        # PowerShell
```

## Hints

<details><summary>Hint 1 – Inspect disruptionsAllowed</summary>

`kubectl get pdb -n a3-maintenance` – look at `ALLOWED DISRUPTIONS`. Why is it what it is?
</details>

<details><summary>Hint 2 – Compare the budget with ready replicas</summary>

`minAvailable: 1` with how many ready replicas? What would a node drain do with that pod?
</details>

<details><summary>Hint 3 – Add safe redundancy before changing the disruption allowance</summary>

Meet the availability requirement *and* allow a disruption: more ready replicas, not a weaker budget.
</details>

## What doesn't count

* Deleting the PDB, setting `minAvailable: 0`, or `maxUnavailable: 100%`.
* `kubectl delete pod --force`, draining nodes, or starting a real cluster/node upgrade.

## Stretch objective

Explain what this preflight proves, what it does **not** prove about an AKS upgrade, and how unhealthy replicas
affect maintenance.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a3
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a3
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High.** AKS Automatic's deployment safeguards do **not** inspect PodDisruptionBudgets, so a one-replica Deployment with `minAvailable: 1` (0 disruptions allowed) stays broken. The in-cluster `maintenance-check` Job uses its own narrowly scoped RBAC to request evictions – no node drains, no real upgrade, nothing that affects other rounds. The app drains gracefully (`preStop`), so the only failure is the one being taught. Safeguards add anti-affinity when replicas > 1; the manifest pre-sets a topology spread so this does not surprise participants. |
| **Validation status** | Fault, fix and scoring validated locally with bash, PowerShell and Terraform (begin: eviction `429`; end: eviction accepted, 0 failed requests) and **on AKS Automatic 1.35 (westus3, 2026-10-14)** with the same results (end: 31 requests, 0 failed during the eviction). |
| **Fit for 200-level users** | Good, slightly easy: the check output names the PDB, and `kubectl get pdb` shows `ALLOWED DISRUPTIONS 0`. The `kubectl create job --from=cronjob` pattern is new to some participants but given in the brief. |
| **Expected time** | 10–15 min – may finish early; use the stretch objective to fill the round. |
| **Risks** | Low. A second replica may need a new NAP node (1–3 min). |
| **Opinion** | **Good reserve / easy round.** Reliable and safe; less depth than the others, so pair it with the stretch discussion about AKS upgrades. |
