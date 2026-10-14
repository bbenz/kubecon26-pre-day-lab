# A2 · Walkthrough to the end state (facilitators)

> Spoilers. Re-measure the numbers below on the pilot cluster and update them.

## 1. Reproduce

```bash
kubectl exec -n a2-checkout deploy/loadgen -- python3 /app/loadtest.py
# {"requests": 120, "concurrency": 4, "errors": 0, "p50_ms": 991.2, "p95_ms": 1597.2, ..., "throughput_rps": 4.0, "result": "FAIL"}
```

## 2. Correlate latency with CPU and throttling

```bash
# terminal 2, while the test runs:
kubectl top pod -n a2-checkout                 # checkout-api pinned at ~100m
kubectl exec -n a2-checkout deploy/checkout-api -- curl -s localhost:8080/stats
# {"cgroup_cpu_max": "10000 100000", "nr_periods": 555, "nr_throttled": 551, "throttled_seconds": 208.5, ...}
```

`cpu.max = 10000 100000` means 10 ms of CPU per 100 ms period = **0.1 CPU**. Nearly every period is throttled:
each checkout needs tens of ms of CPU, so requests queue behind the quota.

## 3. Compare configuration with demand and the envelope

```bash
kubectl get deploy checkout-api -n a2-checkout -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
#   {"limits":{"cpu":"100m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
kubectl describe limitrange checkout-resource-envelope -n a2-checkout     # max cpu 1, memory 512Mi
kubectl get configmap checkout-slo -n a2-checkout -o jsonpath='{.data.README\.txt}'
```

## 4. Tune within the envelope

Option A – one replica, 1 CPU (top of the envelope):

```bash
kubectl set resources deployment/checkout-api -n a2-checkout --requests=cpu=500m --limits=cpu=1
kubectl rollout status deployment/checkout-api -n a2-checkout
```

Option B – two replicas, each with a 1 CPU limit (spreads the 4 concurrent requests):

```bash
kubectl set resources deployment/checkout-api -n a2-checkout --requests=cpu=500m --limits=cpu=1
kubectl scale deployment/checkout-api -n a2-checkout --replicas=2
```

> 2 replicas × **500m** limits is borderline (p95 ≈ 297 ms locally): the Service does not spread 4 concurrent
> requests evenly, so one pod often gets 3. Good debrief material on "average vs. worst case".

(Trying `--limits=cpu=2` is rejected by the LimitRange: `maximum cpu usage per Container is 1`.)

## 5. Prove it

```bash
kubectl exec -n a2-checkout deploy/loadgen -- python3 /app/loadtest.py
# {"requests": 120, ..., "p50_ms": 97.5, "p95_ms": 106.7, ..., "result": "PASS"}
scoring/verify.sh --challenges a2
```

## End state

Matches [`challenge-end-state/challenges/a2-fast-yesterday-slow-today`](../../../challenge-end-state/challenges/a2-fast-yesterday-slow-today/README.md)
(option A: requests 500m, limit 1 CPU, 1 replica).

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Remove the CPU limit | Unbounded resources – outside the envelope; scoring requires limits. |
| `--limits=cpu=4` | Rejected by the LimitRange (max 1 CPU per container). |
| Scale to 4+ replicas / HPA to 10 | Unbounded scaling – outside the envelope (≤ 2 replicas). |
| Raise only the request | Requests reserve capacity but the **limit** still throttles. |

## Stretch objective – notes

* **Request**: what the scheduler reserves on a node (and the basis for HPA CPU utilisation %).
* **Limit**: a hard CFS quota per period; exceeding it causes **throttling** (latency), not OOM.
* **Throttling** shows up as `nr_throttled/throttled_usec` in `cpu.stat` (or
  `container_cpu_cfs_throttled_periods_total` in Prometheus) even when average CPU looks moderate.
* **Autoscaling signals**: HPA scales on usage relative to *requests*; a throttled pod can never exceed its limit,
  so scaling out may not trigger while every request is slow – fix the limit first, then scale on a meaningful
  signal (CPU or latency/queue depth via KEDA).
