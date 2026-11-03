# A2 · Fast yesterday, slow today

| | |
|---|---|
| **Round** | Preferred alternate · Intermediate |
| **Namespace** | `a2-checkout` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | AKS Automatic with **Azure Monitor managed service for Prometheus** – viewed through **Dashboards with Grafana** in the Azure portal (no Grafana instance to run); metrics-server for `kubectl top` |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> A resource-policy change ("right-size checkout-api", CHG-1163) has made checkout slow. Customers notice;
> `kubectl top` says the service is barely busy. Find out what the platform's metrics say, then restore the
> response-time objective **without giving the service unlimited resources**.
>
> Objective (fixed load test: 120 checkouts, concurrency 4): **p95 ≤ 300 ms, 0 errors**.
> Approved envelope for `checkout-api`: CPU limit ≤ 1 CPU per container, memory ≤ 512Mi, at most 2 replicas,
> limits must stay set. (Also in the ConfigMap `checkout-slo`.)

## Learning objective

Use the cluster's **Managed Prometheus** metrics (the AKS Automatic default) to correlate latency, CPU usage,
CPU **throttling** and resource configuration – then tune within an approved resource budget.

## What's running

* `checkout-api` – CPU-bound (every checkout verifies an order token with PBKDF2). `GET /stats` reports the
  container's cgroup CPU quota and throttling counters.
* `loadgen` – sends steady background "customer" traffic (about one checkout per second) and runs the fixed,
  bounded load test on demand. Its log shows what customers experience (p50/p95 every 30 s).
* The cluster sends its metrics to an Azure Monitor workspace (Managed Prometheus), so the
  **Kubernetes / Compute Resources** dashboards in the Azure portal show this namespace without any setup.

```bash
kubectl get pods,deploy,limitrange -n a2-checkout
kubectl get configmap checkout-slo -n a2-checkout -o jsonpath='{.data.README\.txt}'
kubectl logs -n a2-checkout deploy/loadgen --tail=3                         # what customers see right now
kubectl exec -n a2-checkout deploy/loadgen -- python3 /app/loadtest.py      # ~40-60 s while slow
```

**Dashboards:** Azure portal → your AKS cluster → **Monitoring** → **Dashboards with Grafana** →
**Kubernetes / Compute Resources / Pod** (type *Compute Resources* in the search box), then pick namespace
`a2-checkout` and the `checkout-api-…` pod. Metrics arrive 1–3 minutes after the fact – set the time range to
*Last 30 minutes* and refresh.

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

<details><summary>Hint 1 – Reproduce, and see what customers see</summary>

Run the load test and note p50/p95 and throughput. `kubectl logs -n a2-checkout deploy/loadgen --tail=3` shows
what the steady background traffic experiences – note those numbers, and look again while a load test runs. Now
check how busy the service is: `kubectl top pod -n a2-checkout`. Does a few tens of millicores explain a
multi-second checkout?
</details>

<details><summary>Hint 2 – Ask Managed Prometheus: usage against the limit, and throttling</summary>

Open the **Kubernetes / Compute Resources / Pod** dashboard (see *Dashboards* above) for the `checkout-api` pod.
Compare the **CPU Usage** panel with its **limit** line, then look at **CPU Throttling**: the share of CPU
scheduling periods in which the container wanted more CPU than its limit allowed. Average usage can look low
while most periods are throttled – and every throttled period adds latency.

Command-line equivalent: compare the throttling counters before/after a test –
`kubectl exec -n a2-checkout deploy/checkout-api -- curl -s localhost:8080/stats` (or `cat /sys/fs/cgroup/cpu.stat`).
What is `cgroup_cpu_max`?
</details>

<details><summary>Hint 3 – Compare configured limits with workload demand</summary>

`kubectl get deploy checkout-api -n a2-checkout -o jsonpath='{.spec.template.spec.containers[0].resources}'` –
how does the CPU **limit** compare with what the service needs under 4 concurrent requests? What does the
`LimitRange` allow? After the change, watch the throttling panel drop (give it 2–3 minutes).
</details>

## What doesn't count

* Removing limits, scaling beyond 2 replicas, or an HPA with `maxReplicas > 2`.
* Changing the workload (`ITERATIONS`), the load-test parameters or the objective.

## Stretch objectives

* Explain the difference between CPU requests, CPU limits, throttling and autoscaling signals.
* Query the throttling ratio yourself: Azure portal → the cluster's Azure Monitor workspace → **Prometheus
  explorer**, using `container_cpu_cfs_throttled_periods_total` and `container_cpu_cfs_periods_total`.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a2
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a2
```

## Troubleshooting

* **"No data" on the dashboard** – metrics lag 1–3 minutes; widen the time range and refresh. Check the
  namespace/pod selectors at the top of the dashboard.
* **Access denied on the dashboard** – viewing Managed Prometheus data needs read access to the cluster's Azure
  Monitor workspace data (subscription/resource group Owner worked in testing; otherwise ask for
  **Monitoring Data Reader** on the workspace). `kubectl top` and `/stats` (Hint 2) work without it.

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High.** Self-contained fixture (Python on an MCR image, no image build). The 100m CPU limit sits exactly at AKS Automatic's deployment-safeguards floor, so it is **not** auto-raised. Calibrated locally: 100m → p95 ≈ 1.2–1.6 s, 99% of CFS periods throttled (FAIL); 1 CPU → p95 ≈ 107 ms (PASS). Valid fixes: 1 replica at ~1 CPU, or 2 replicas with up to 1 CPU each (2 × 500m is borderline – p95 ≈ 297 ms locally because the Service doesn't spread 4 concurrent requests evenly). A LimitRange enforces the per-container ceiling, so "unlimited" fixes are rejected by the API server. Managed Prometheus is on by default for AKS Automatic clusters created with the Azure CLI or portal; the Terraform deployment adds the same data collection rule and recording rules, and every deployment keeps the Azure Monitor workspace in the lab resource group. The background traffic (~1 checkout/s) keeps the throttling visible on the dashboards between load tests. |
| **Validation status** | Fault, fix and scoring validated locally with bash, PowerShell and Terraform, on AKS Automatic 1.35 (westus3, 2026-10-14), and again **with the background traffic and Managed Prometheus on AKS Automatic 1.36 (westus3, 2026-11-03)**: begin – background checkouts p95 ≈ 175 ms, `kubectl top` ≈ 27m (a quarter of the limit) while ≈ 50–60% of CPU periods are throttled; load test p95 ≈ 2.6 s (48 s run, FAIL; background p95 ≈ 2.6 s meanwhile). End – load test p95 ≈ 186 ms (PASS, 3.8 s run), background p50 ≈ 36 ms. The throttling ratio, CPU usage and the recording rules behind the dashboard panels were confirmed in the Azure Monitor workspace with PromQL. |
| **Fit for 200-level users** | Good. The load test gives an immediate, objective signal; the portal dashboards turn "kubectl top looks fine" into a visible throttling problem – and show off an AKS Automatic default (Managed Prometheus + Dashboards with Grafana) instead of only kubectl. |
| **Expected time** | 20–25 min (test runs: ~40–60 s broken, ~3 s fixed; dashboards lag 1–3 min; a request increase may trigger a 1–3 min NAP node). |
| **Risks** | Metric ingestion delay (1–3 min) – the hints say so and `/stats` is an instant fallback. Viewing the dashboards needs read access to the Azure Monitor workspace data (a Skillable role question). Performance variance across VM sizes (large margin around the objective). |
| **Opinion** | **Strong alternate – recommended as the first substitute for C3** for a 200-level audience: deterministic, measurable, quick to reset, very relevant to day-2 operations, and now a showcase for AKS Automatic's built-in monitoring. |
