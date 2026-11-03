# A2 · Walkthrough to the end state (facilitators)

> Spoilers. Numbers below were measured on AKS Automatic 1.36 (westus3) on 2026-11-03, with the background
> traffic running. Re-measure them on the event cluster.

## 1. Reproduce

```bash
kubectl exec -n a2-checkout deploy/loadgen -- python3 /app/loadtest.py
# {"requests": 120, "concurrency": 4, "errors": 0, "p50_ms": 1498.8, "p95_ms": 2593.8, ..., "duration_s": 48.1, "throughput_rps": 2.5, "result": "FAIL"}
```

## 2. Correlate latency with CPU and throttling

**Customers' view** – the background traffic's latency, between tests and during a test:

```bash
kubectl logs -n a2-checkout deploy/loadgen --tail=2
# last 30 s: 30 checkouts, p50 173 ms, p95 175 ms, errors 0, dropped (too many in flight) 0      <- no test running
# last 31 s: 30 checkouts, p50 1670 ms, p95 2569 ms, errors 0, dropped (too many in flight) 0    <- during a test
```

**Managed Prometheus** – Azure portal → the AKS cluster → **Monitoring** → **Dashboards with Grafana** →
**Kubernetes / Compute Resources / Pod** → namespace `a2-checkout`, pod `checkout-api-…` (last 30 minutes):

* **CPU Usage** stays far below the limit line (about 0.03 of the 0.1 CPU limit) and touches the limit only
  during a load test – "average usage looks fine".
* **CPU Throttling** shows roughly half of the CPU periods throttled from the background traffic alone (62% over a
  5-minute window that included a load test): each checkout needs ~30 ms of CPU but the container gets 10 ms per
  100 ms period.

The same ratio in PromQL (the cluster's Azure Monitor workspace → **Prometheus explorer**):

```promql
sum(rate(container_cpu_cfs_throttled_periods_total{namespace="a2-checkout", container="checkout-api"}[5m]))
  / sum(rate(container_cpu_cfs_periods_total{namespace="a2-checkout", container="checkout-api"}[5m]))
```

**Command line** (instant, no metric delay):

```bash
# terminal 2, while the test runs:
kubectl top pod -n a2-checkout                 # checkout-api ~27m between tests (a quarter of the limit), ~100m during one
kubectl exec -n a2-checkout deploy/checkout-api -- curl -s localhost:8080/stats
# {"cgroup_cpu_max": "10000 100000", "nr_periods": 1797, "nr_throttled": 1127, "throttled_seconds": 211.7, ...}
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
# {"requests": 120, ..., "p50_ms": 107.9, "p95_ms": 186.4, ..., "duration_s": 3.8, "result": "PASS"}
kubectl logs -n a2-checkout deploy/loadgen --tail=1    # background traffic: p50 ~36 ms
scoring/verify.sh --challenges a2
```

On the dashboard (2–3 minutes later) **CPU Throttling** drops to ~0 for the background traffic. A load test still
shows some throttling – 4 concurrent checkouts want more than 1 CPU – but latency stays inside the objective:
throttling is only a problem when it costs more than the latency budget.

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
