# C4 · The AI assistant is up, but not working

| | |
|---|---|
| **Level** | Intermediate |
| **Namespace** | `c4-assistant` |
| **Suggested time** | 20–25 minutes |
| **Azure services** | Microsoft Foundry (Azure OpenAI) account with a `GlobalStandard` model deployment, a user-assigned managed identity with workload identity federation |

## Participant briefing

> The store's AI assistant passes all its health checks, but every time store staff click **Ask AI
> Assistant** to write a product description, it fails. Restore a successful end-to-end interaction.

## Learning objective

Trace an application request into an AI dependency and distinguish a configuration failure from Kubernetes
health.

## What's running

The AKS Store demo admin experience: `store-admin` (UI) → `product-service` → `ai-service` (Python/FastAPI,
OpenAI SDK) → a model deployment in a Microsoft Foundry (Azure OpenAI) account. `ai-service` authenticates
with **Microsoft Entra workload identity** (no API keys; key authentication is disabled on the account).
Supporting services: `order-service`, `makeline-service`, `rabbitmq`, `documentdb`.

```bash
kubectl get pods -n c4-assistant
kubectl port-forward -n c4-assistant svc/store-admin 8081:80     # http://localhost:8081
# Products -> edit (or add) a product -> "Ask AI Assistant"
```

## Success criteria

1. A synthetic request through the store (`store-admin` → `product-service` → `ai-service`) invokes the
   intended model deployment and returns a description (exact wording/quality does not matter).
2. The fix lives in the application's configuration; no credentials are hard-coded, access controls are not
   weakened, and there is no fabricated fallback response.

```bash
scoring/verify.sh --challenges c4          # bash
./scoring/verify.ps1 -Challenges c4        # PowerShell
```

## Hints

<details><summary>Hint 1 – Test useful functionality rather than pod status</summary>

All pods are Ready because `/health` doesn't call the model. Trigger a real request (UI button, or
`kubectl exec -n c4-assistant deploy/store-admin -- wget -q -O - --header 'Content-Type: application/json' --post-data '{"name":"Catnip Kicker","tags":["toy","cat"]}' http://localhost:8081/api/ai/generate/description`).
</details>

<details><summary>Hint 2 – Inspect the failed dependency call</summary>

`kubectl logs -n c4-assistant deploy/ai-service` – what did Azure OpenAI answer? Then check which endpoint and
deployment the service is configured to call: `kubectl exec -n c4-assistant deploy/ai-service -- printenv | grep AZURE_OPENAI`.
</details>

<details><summary>Hint 3 – Compare the configured deployment name with the actual deployments</summary>

Where does `ai-service` get `AZURE_OPENAI_DEPLOYMENT_NAME`? Compare it with the deployments that exist in the
Foundry account: `az cognitiveservices account deployment list -g <resource-group> -n <account> -o table`
(or the Microsoft Foundry portal). Model upgrades usually come with a *new deployment* – check the change
ticket on the ConfigMap.
</details>

## What doesn't count

* Switching `ai-service` to API keys (`USE_AZURE_AD=False`, adding `AZURE_OPENAI_API_KEY`), re-enabling key
  auth on the account, or granting broader Azure roles.
* Pointing `ai-service` at a bare model name such as `gpt-6-luna`: Foundry accounts answer those too, but that
  bypasses the provisioned deployment (its capacity, quota and policies) – use the deployment the platform team
  created.
* Re-creating a deployment with the old name, or returning a canned description.

## Stretch objective

Propose readiness, dependency telemetry and error handling that would make this failure easier to detect,
without making transient model errors restart the pod.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c c4
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c4
```
