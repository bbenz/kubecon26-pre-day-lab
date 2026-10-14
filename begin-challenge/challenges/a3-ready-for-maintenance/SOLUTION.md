# A3 · Walkthrough to the end state (facilitators)

> Spoilers.

## 1. Read the pre-maintenance report

```bash
kubectl logs -n a3-maintenance job/pre-maintenance-check
```

```text
Deployment inventory-api: desired replicas=1, ready=1
PodDisruptionBudget inventory-api: minAvailable=1 maxUnavailable=None currentHealthy=1 disruptionsAllowed=0
Requesting voluntary eviction of pod inventory-api-... ...
Eviction BLOCKED (HTTP 429): Cannot evict pod as it would violate the pod's disruption budget.
RESULT: FAIL - a voluntary disruption is not possible; maintenance (node drain/upgrade) would stall
```

## 2. Inspect the budget against the replicas

```bash
kubectl get pdb -n a3-maintenance          # MIN AVAILABLE 1, ALLOWED DISRUPTIONS 0
kubectl get deploy inventory-api -n a3-maintenance
```

One ready replica and `minAvailable: 1` → evicting the only pod would drop availability to 0, so the API refuses
(`429`). A node drain or AKS upgrade would block on this pod until a timeout – or, with a forced drain, cause the
outage the budget was meant to prevent.

## 3. Add redundancy (keep the budget)

```bash
kubectl scale deployment/inventory-api -n a3-maintenance --replicas=2
kubectl rollout status deployment/inventory-api -n a3-maintenance
kubectl get pdb -n a3-maintenance          # ALLOWED DISRUPTIONS 1
```

(For a permanent fix, change `replicas: 2` in the Deployment manifest. `maxUnavailable: 1` instead of
`minAvailable: 1` is an equivalent budget with 2 replicas.)

## 4. Prove it

```bash
kubectl create job -n a3-maintenance --from=cronjob/maintenance-check check-2
kubectl logs -n a3-maintenance -f job/check-2
# Eviction ACCEPTED (HTTP 201) ... Synthetic requests during the check: 30 succeeded, 0 failed
# RESULT: PASS - eviction accepted, no failed requests, inventory-api back to 2 ready replicas
scoring/verify.sh --challenges a3
```

## End state

Matches [`challenge-end-state/challenges/a3-ready-for-maintenance`](../../../challenge-end-state/challenges/a3-ready-for-maintenance/README.md):
`replicas: 2`, PDB `minAvailable: 1` unchanged.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Delete the PDB / `minAvailable: 0` | Eviction is accepted but the only replica goes away – requests fail (an avoidable outage). |
| `kubectl delete pod --force` | Bypasses the Eviction API and the budget; not a maintenance-ready state. |
| `kubectl drain <node>` | Affects every workload on the node (other rounds), and still blocks on the budget. |

## Stretch objective – notes

* **Proves**: a voluntary eviction of one pod is allowed by the budget and the app keeps serving while it is
  rescheduled – the precondition for drains during node-image upgrades, NAP consolidation and AKS upgrades.
* **Does not prove**: the app survives a whole node (all replicas on one node? use topology spread), surge/drain
  timeouts and `maxSurge` settings, API deprecations in the new Kubernetes version, or behaviour under load.
* **Unhealthy replicas**: a not-Ready replica doesn't count as "available", so a budget can block evictions even
  with 2 replicas; `unhealthyPodEvictionPolicy: AlwaysAllow` lets broken pods be evicted.
