# C4 · Walkthrough to the end state (facilitators)

> Spoilers. Paste the exact error text captured during the Azure pilot into step 2.

## 1. Reproduce with a real request

```bash
kubectl get pods -n c4-assistant                         # everything Running/Ready
kubectl exec -n c4-assistant deploy/store-admin -- wget -S -q -O - \
  --header 'Content-Type: application/json' \
  --post-data '{"name":"Contoso Catnip Kicker","tags":["toy","cat"]}' \
  http://localhost:8081/api/ai/generate/description
# HTTP/1.1 500 Internal Server Error
```

In the UI (`kubectl port-forward -n c4-assistant svc/store-admin 8081:80`) the "Ask AI Assistant" button shows
an error.

## 2. Inspect the dependency call

```bash
kubectl logs -n c4-assistant deploy/ai-service --tail=50
```

```text
Using Azure OpenAI: gpt-6-luna at https://aoai-ctf-xxxxxx.openai.azure.com/
Using Microsoft Entra authentication
Error creating completion ... Error code: 404 - {'error': {'code': 'DeploymentNotFound', 'message': 'The API deployment for this resource does not exist. ...'}}
```

Authentication worked (otherwise it would be 401/403); the **deployment** `gpt-6-luna` does not exist.

## 3. Compare configuration with what is provisioned

```bash
kubectl get configmap ai-service-configs -n c4-assistant -o yaml      # AZURE_OPENAI_DEPLOYMENT_NAME: gpt-6-luna
az cognitiveservices account list -g <resource-group> -o table          # the Foundry account (aoai-ctf-xxxxxx)
az cognitiveservices account deployment list -g <resource-group> -n <account> \
  --query "[].{deployment:name, model:properties.model.name, version:properties.model.version}" -o table
```

```text
Deployment       Model       Version
---------------  ----------  ----------
store-assistant  gpt-6-luna  2026-09-22
```

The configuration names the **model**; Azure OpenAI requests address a **deployment**.

## 4. Fix the configuration and restart

```bash
kubectl patch configmap ai-service-configs -n c4-assistant --type merge \
  -p '{"data":{"AZURE_OPENAI_DEPLOYMENT_NAME":"store-assistant"}}'
kubectl rollout restart deployment/ai-service -n c4-assistant
kubectl rollout status deployment/ai-service -n c4-assistant
```

## 5. Prove it

Repeat step 1 (HTTP 200 with `{"description": "..."}`), use the UI button, and run
`scoring/verify.sh --challenges c4`. The ai-service log shows `Using Azure OpenAI: store-assistant at ...` with
no error.

## End state

Matches [`challenge-end-state/challenges/c4-ai-assistant-up-but-not-working`](../../../challenge-end-state/challenges/c4-ai-assistant-up-but-not-working/README.md):
`AZURE_OPENAI_DEPLOYMENT_NAME: store-assistant`, Entra ID authentication unchanged.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Switch to API keys | Key authentication is disabled on the account (and hard-coding credentials is out of bounds). |
| Create a deployment called `gpt-6-luna` | Changes the platform to match a typo, adds an unapproved deployment and quota use. |
| Make `ai-service` return a canned description | Fabricated success – the success criteria require a real model call. |
| Restart pods | The configuration is unchanged; the same 404 returns. |

## Stretch objective – notes

* Keep **liveness** dependency-free (a model outage must not restart pods).
* Add a **startup/readiness self-test** or a dedicated `/health/dependencies` endpoint that validates the
  configured deployment exists (e.g. one cheap call at startup, cached), surfaced as a readiness gate or alert
  rather than a restart.
* Emit dependency telemetry (OpenTelemetry / Application Insights): deployment name, status code, latency, error
  code – an alert on `DeploymentNotFound` > 0 would have caught this immediately.
* Return a clear error to the UI (`503 AI assistant unavailable: model deployment not found`) instead of a generic 500.
