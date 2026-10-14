# C4 · Walkthrough to the end state (facilitators)

> Spoilers. Output below was captured on AKS Automatic 1.35 (westus3) with `gpt-6-luna` on 2026-10-14.

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
kubectl logs -n c4-assistant deploy/ai-service --tail=40
```

```text
Error creating completion
Traceback (most recent call last):
  File "/app/routers/description_generator.py", line 47, in _create_completion
  ...
openai.NotFoundError: Error code: 404 - {'error': {'type': 'invalid_request_error', 'code': 'DeploymentNotFound',
  'message': 'The API deployment for this resource does not exist. If you created the deployment within the last
  5 minutes, please wait a moment and try again.'}}
INFO:     10.244.6.68:35056 - "POST /generate/description HTTP/1.1" 500 Internal Server Error
```

Authentication worked (otherwise it would be 401/403); the **deployment** the service asks for doesn't exist. The
log doesn't name it – the configuration does:
`kubectl exec -n c4-assistant deploy/ai-service -- printenv | grep AZURE_OPENAI` →
`AZURE_OPENAI_DEPLOYMENT_NAME=store-assistant-gpt41`.

## 3. Compare configuration with what is provisioned

```bash
kubectl get configmap ai-service-configs -n c4-assistant -o yaml      # AZURE_OPENAI_DEPLOYMENT_NAME: store-assistant-gpt41
#   annotations: kubecon.lab/change-ticket: CHG-1142 - store assistant moves to the new GPT model (platform replaces the GPT-4.1 deployment)
az cognitiveservices account list -g <resource-group> -o table          # the Foundry account (aoai-ctf-xxxxxx)
az cognitiveservices account deployment list -g <resource-group> -n <account> \
  --query "[].{deployment:name, model:properties.model.name, version:properties.model.version}" -o table
```

```text
Deployment       Model       Version
---------------  ----------  ----------
store-assistant  gpt-6-luna  2026-09-22
```

The platform replaced the GPT-4.1 deployment `store-assistant-gpt41` with `store-assistant` (model
`gpt-6-luna`); the application's configuration still names the old deployment.

## 4. Fix the configuration and restart

```bash
kubectl patch configmap ai-service-configs -n c4-assistant --type merge \
  -p '{"data":{"AZURE_OPENAI_DEPLOYMENT_NAME":"store-assistant"}}'
kubectl rollout restart deployment/ai-service -n c4-assistant
kubectl rollout status deployment/ai-service -n c4-assistant
```

## 5. Prove it

Repeat step 1 (HTTP 200 with `{"description": "..."}`), use the UI button, and run
`scoring/verify.sh --challenges c4`. The ai-service log shows `"POST /generate/description HTTP/1.1" 200 OK` with
no traceback.

## End state

Matches [`challenge-end-state/challenges/c4-ai-assistant-up-but-not-working`](../../../challenge-end-state/challenges/c4-ai-assistant-up-but-not-working/README.md):
`AZURE_OPENAI_DEPLOYMENT_NAME: store-assistant`, Entra ID authentication unchanged.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Switch to API keys | Key authentication is disabled on the account (and hard-coding credentials is out of bounds). |
| Set the deployment name to the model name `gpt-6-luna` | It works – Foundry accounts also answer requests addressed to a bare model name, even for models that aren't deployed – but it bypasses the provisioned deployment (capacity, quota, content policies). The scoring checks for the provisioned deployment. |
| Re-create a deployment called `store-assistant-gpt41` | Changes the platform to match stale configuration, adds an unapproved deployment and quota use. |
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
