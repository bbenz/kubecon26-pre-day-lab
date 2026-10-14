# C4 · The AI assistant is up, but not working

| | |
|---|---|
| **Round** | Proposed core, round 4 (pilot gate) · Intermediate |
| **Namespace** | `c4-assistant` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | Microsoft Foundry (Azure OpenAI) account with a `GlobalStandard` model deployment, a user-assigned managed identity with workload identity federation |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

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

`kubectl logs -n c4-assistant deploy/ai-service` – what did Azure OpenAI answer, and which endpoint and
deployment did the service call?
</details>

<details><summary>Hint 3 – Compare the configured deployment name with the actual deployment</summary>

Where does `ai-service` get `AZURE_OPENAI_DEPLOYMENT_NAME`? Compare it with the deployments that exist in the
Foundry account: `az cognitiveservices account deployment list -g <resource-group> -n <account> -o table`
(or the Microsoft Foundry portal). A *model* name is not a *deployment* name.
</details>

## What doesn't count

* Switching `ai-service` to API keys (`USE_AZURE_AD=False`, adding `AZURE_OPENAI_API_KEY`), re-enabling key
  auth on the account, or granting broader Azure roles.
* Creating a new model deployment named after the wrong value, or returning a canned description.

## Stretch objective

Propose readiness, dependency telemetry and error handling that would make this failure easier to detect,
without making transient model errors restart the pod.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c c4
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c4
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **Medium–high.** `ai-service` (aks-store-demo 2.2.0) only checks environment variables in `/health`, so the pod stays healthy; with `AZURE_OPENAI_DEPLOYMENT_NAME` set to the **model name** (`gpt-6-luna`) instead of the **deployment name** (`store-assistant`) every generation call fails with Azure OpenAI's `DeploymentNotFound` (404) and `ai-service` returns HTTP 500 with that text. Identity, network, model availability and quota stay healthy, so there is a single fault. `ai-service` sends only `temperature=1` (no `max_tokens`), which is compatible with GPT-5/6 reasoning models. |
| **Validation status** | Manifests validated; deployment code creates the account (keys disabled), the `gpt-6-luna` 2026-09-22 GlobalStandard deployment, the identity, role and federated credential. **Pending Azure pilot:** an end-to-end call with `gpt-6-luna` using ai-service's default API version `2024-12-01-preview`; role-assignment propagation time on a fresh deployment; the exact error text participants see. |
| **Fit for 200-level users** | Good. The evidence is explicit (`DeploymentNotFound` in the logs) and "model name ≠ deployment name" is one of the most common real-world Azure OpenAI mistakes. Participants need **Reader** access to the Foundry account (or the portal) to list deployments. |
| **Expected time** | 10–20 min. |
| **Risks** | Per-subscription model availability and quota (the test subscription has 10M TPM gpt-6-luna GlobalStandard quota; Skillable subscriptions must be checked); the model must exist in the chosen `AOAI_LOCATION`. AI features attract audiences – a strong reason to keep it. |
| **Opinion** | **Keep as round 4 once the pilot confirms an end-to-end call.** If model access per subscription is a problem, swap in **A4** (identity) as the doc suggests – it reuses the same workload identity concepts without a model dependency. |
