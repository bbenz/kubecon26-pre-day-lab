# A5 · Running is not ready

| | |
|---|---|
| **Round** | Additional candidate (lower dependency) · Foundational–intermediate |
| **Namespace** | `a5-releases` |
| **Investigation time (design target)** | 15–20 minutes |
| **Azure services** | AKS Automatic only |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> Every release of the `web` tier causes a burst of customer errors, even though the new pods show `Running`
> (and even `Ready`). Make the rollout safe – a release must not fail customer requests.

## Learning objective

Distinguish Running, Ready and customer-visible availability; validate probe behaviour during a rollout.

## What's running

* `web` (3 replicas) – on start it loads its product cache for ~20 s and cannot serve customers until then.
  Endpoints: `/healthz` (the process is alive), `/ready` (cache loaded and not shutting down), `/` (customer
  request; 503 while warming up). See the comments in ConfigMap `web-script`.
* `rollout-tester` – sends steady customer traffic, starts a new rollout of `web` (a new pod-template revision,
  same image) and reports failed requests.

```bash
kubectl get deploy,pods,endpointslices -n a5-releases
kubectl exec -n a5-releases deploy/rollout-tester -- python3 /app/rollout_test.py    # ~10-90 s
```

## Success criteria

1. A controlled rollout under traffic completes with **zero failed customer requests**.
2. Unready replicas don't receive Service traffic: the readiness probe reflects whether the pod can serve.
3. The Deployment converges within the test's timeout (240 s).
4. No long arbitrary delay (`initialDelaySeconds`/`sleep`) instead of correct readiness, and no liveness probe
   that would restart pods while they warm up.

```bash
scoring/verify.sh --challenges a5          # bash
./scoring/verify.ps1 -Challenges a5        # PowerShell
```

## Hints

<details><summary>Hint 1 – Compare Running with Ready</summary>

Run the test and watch in another terminal: `kubectl get pods -n a5-releases -w`. When do new pods become
`READY 1/1`, and when do they actually answer `/` successfully?
(`kubectl exec -n a5-releases deploy/rollout-tester -- curl -s web:8080/`)
</details>

<details><summary>Hint 2 – Observe when replicas enter the Service's endpoints</summary>

`kubectl get endpointslices -n a5-releases -l kubernetes.io/service-name=web -w` during a rollout. A pod
receives traffic as soon as it is Ready.
</details>

<details><summary>Hint 3 – Verify what the readiness endpoint actually measures</summary>

`kubectl get deploy web -n a5-releases -o yaml` – which path does the readiness probe call? Compare with the
endpoints the app offers. Also look at the rollout strategy: how many old pods may be removed before new ones
are ready?
</details>

## What doesn't count

* `initialDelaySeconds: 60` (or a startup `sleep`) on the old probe instead of a meaningful readiness check.
* Using `/ready` as the **liveness** probe (restarts pods that are merely warming up).
* Changing the image/app or the test.

## Stretch objective

Explain when startup, readiness and liveness probes are appropriate, and how a poorly chosen dependency check
can destabilise a service.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a5
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a5
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High.** Deterministic 20 s warm-up, a readiness probe on `/healthz` (passes immediately) and `maxUnavailable: 1` make every rollout fail customer requests. Locally: 172 of 342 requests failed (HTTP 503) during an 8 s rollout. After the fix (`/ready` + `maxUnavailable: 0`): 1,521 ok / 0 failed in a 70 s rollout. AKS Automatic safeguards only require probes to *exist*, so they don't fix the fault. The app drains gracefully on SIGTERM, so the only failure source is readiness. |
| **Validation status** | Fault, fix and scoring validated locally with bash, PowerShell and Terraform. **Pending:** run on AKS Automatic (rollout duration with NAP-provisioned nodes). |
| **Fit for 200-level users** | Very good – one of the best "concept" rounds: the test gives an objective signal, and the fix is a small, well-explained change. |
| **Expected time** | 15–20 min (each test run ~10–90 s). |
| **Risks** | Low. If replicas land on a new NAP node the first rollout is slower (image pull), still well within the 240 s timeout. |
| **Opinion** | **Strong alternate; recommended for a less experienced audience** or as the substitute when an Azure dependency (C3/C4) fails its pilot. |
