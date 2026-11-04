# A3 · Ready for maintenance?

| | |
|---|---|
| **Level** | Intermediate–advanced |
| **Namespace** | `a3-maintenance` |
| **Suggested time** | 20–25 minutes |
| **Azure services** | AKS Automatic only |

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
