# A2 · Fast yesterday, slow today

| | |
|---|---|
| **Round** | Preferred alternate · Intermediate |
| **Namespace** | `a2-checkout` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | AKS Automatic (metrics-server; Managed Prometheus/Container Insights optional) |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> A resource-policy change ("right-size checkout-api", CHG-1163) has made checkout slow. Restore the
> response-time objective **without giving the service unlimited resources**.
>
> Objective (fixed load test: 120 checkouts, concurrency 4): **p95 ≤ 300 ms, 0 errors**.
> Approved envelope for `checkout-api`: CPU limit ≤ 1 CPU per container, memory ≤ 512Mi, at most 2 replicas,
> limits must stay set. (Also in the ConfigMap `checkout-slo`.)

## Learning objective

Correlate latency, CPU throttling and resource configuration; tune within an approved resource budget.

## What's running

* `checkout-api` – CPU-bound (every checkout verifies an order token with PBKDF2). `GET /stats` reports the
  container's cgroup CPU quota and throttling counters.
* `loadgen` – runs the fixed, bounded load test on demand.

```bash
kubectl get pods,deploy,limitrange -n a2-checkout
kubectl get configmap checkout-slo -n a2-checkout -o jsonpath='{.data.README\.txt}'
kubectl exec -n a2-checkout deploy/loadgen -- python3 /app/loadtest.py     # ~30-60 s while slow
```

## Success criteria

1. The fixed load test meets the objective: **p95 ≤ 300 ms with 0 errors** at concurrency 4.
2. `checkout-api` stays within the envelope: CPU/memory limits set, CPU limit ≤ 1, ≤ 2 replicas, no autoscaling
   beyond 2.
3. The workload and the test are unchanged (same work per request, same test parameters).

```bash
scoring/verify.sh --challenges a2          # bash
./scoring/verify.ps1 -Challenges a2        # PowerShell
```

## Hints

<details><summary>Hint 1 – Reproduce with the supplied load test</summary>

Run the test and note p50/p95 and throughput. Then check how much CPU the service uses while it runs:
`kubectl top pod -n a2-checkout` (run the test in a second terminal).
</details>

<details><summary>Hint 2 – Correlate latency with throttling, not just average CPU use</summary>

A container can be throttled while average CPU looks "low". Compare the throttling counters before/after a test:
`kubectl exec -n a2-checkout deploy/checkout-api -- curl -s localhost:8080/stats` (or
`cat /sys/fs/cgroup/cpu.stat`). What is `cgroup_cpu_max`?
</details>

<details><summary>Hint 3 – Compare configured limits with workload demand</summary>

`kubectl get deploy checkout-api -n a2-checkout -o jsonpath='{.spec.template.spec.containers[0].resources}'` –
how does the CPU **limit** compare with what the service needs under 4 concurrent requests? What does the
`LimitRange` allow?
</details>

## What doesn't count

* Removing limits, scaling beyond 2 replicas, or an HPA with `maxReplicas > 2`.
* Changing the workload (`ITERATIONS`), the load-test parameters or the objective.

## Stretch objective

Explain the difference between CPU requests, CPU limits, throttling and autoscaling signals.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a2
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a2
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High.** Self-contained fixture (Python on an MCR image, no image build). The 100m CPU limit sits exactly at AKS Automatic's deployment-safeguards floor, so it is **not** auto-raised. Calibrated locally: 100m → p95 ≈ 1.2–1.6 s, 99% of CFS periods throttled (FAIL); 1 CPU → p95 ≈ 107 ms (PASS). Valid fixes: 1 replica at ~1 CPU, or 2 replicas with up to 1 CPU each (2 × 500m is borderline – p95 ≈ 297 ms locally because the Service doesn't spread 4 concurrent requests evenly). A LimitRange enforces the per-container ceiling, so "unlimited" fixes are rejected by the API server. |
| **Validation status** | Fault, fix and scoring validated locally with bash, PowerShell and Terraform, and **on AKS Automatic 1.35 (westus3, 2026-10-14)** on NAP's `Standard_D4als_v6` nodes: begin p95 ≈ 1.7 s (p50 1.1 s), end p95 ≈ 175–185 ms – a wide margin around the 300 ms objective, no recalibration needed. Check again if NAP picks a much slower VM family. |
| **Fit for 200-level users** | Good. The load test gives an immediate, objective signal; `kubectl top`, resource limits and rollouts are core skills; throttling counters make the root cause visible. |
| **Expected time** | 15–20 min (test runs: ~30–60 s broken, ~3 s fixed; a request increase may trigger a 1–3 min NAP node). |
| **Risks** | Performance variance across VM sizes (mitigate by calibrating thresholds in the pilot, keeping a large margin). Managed Prometheus dashboards lag a few minutes – keep them optional. |
| **Opinion** | **Strong alternate – recommended as the first substitute for C3** for a 200-level audience: deterministic, measurable, quick to reset, very relevant to day-2 operations. |
