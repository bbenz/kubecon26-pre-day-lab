# C1 · The store won't start

| | |
|---|---|
| **Level** | Foundational |
| **Namespace** | `c1-store` |
| **Suggested time** | 15–20 minutes |
| **Azure services** | AKS Automatic only |

## Participant briefing

> A configuration rollout has taken the order service offline. Restore order
> processing **without reverting the entire application**.

## Learning objective

Use events, previous-container logs and configuration to diagnose and repair an
application startup failure.

## What's running

The AKS Store demo (v2.2.0): `store-front` (web UI) → `order-service` (Node.js /
Fastify) → `rabbitmq` (order queue), plus `product-service`. `order-service` reads
its settings from the ConfigMap `order-service-configs` and the Secret
`order-service-secrets`.

```bash
kubectl get all -n c1-store
# Open the store UI (optional):
kubectl port-forward -n c1-store svc/store-front 8080:80   # http://localhost:8080
```

## Success criteria

1. `order-service` has all required replicas **Ready**.
2. Restart counts do **not** increase during a 60-second observation after the rollout.
3. A synthetic order (`POST /api/orders` through the storefront) succeeds and lands in the `orders` queue.
4. The fix lives in the **authoritative configuration** (the ConfigMap), not in a temporary override that
   disappears on the next deployment.

Check your work (from the repository root):

```bash
scoring/verify.sh --challenges c1          # bash
./scoring/verify.ps1 -Challenges c1        # PowerShell
```

## Hints

<details><summary>Hint 1 – Find the component that is failing to become ready</summary>

`kubectl get pods -n c1-store` – which pod is not `Running`/`Ready`, and what does `kubectl describe pod`
say in its **Events**?
</details>

<details><summary>Hint 2 – Inspect logs from the previous container instance</summary>

A crash-looping container has already exited; its logs are on the *previous* instance:
`kubectl logs -n c1-store deploy/order-service --previous`. Read the whole log – the real error is
above some unrelated `npm notice` lines.
</details>

<details><summary>Hint 3 – Trace the rejected setting to its configuration source</summary>

Where does the container get its environment from? (`kubectl describe deployment order-service -n c1-store`,
look for `Environment Variables from`). Environment variables are read when a container **starts** – what
has to happen after you change the source?
</details>

## What doesn't count

* `kubectl set env` / editing the Deployment to override the value (a temporary edit the next deployment
  would undo).
* Rolling back the whole application or deleting the ConfigMap.

## Stretch objective

Explain why restarting the pod alone did not fix the issue, and propose a pre-deployment configuration check
that would have caught it.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c c1        # re-creates the challenge with its fault (default --reset)
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c1
```
