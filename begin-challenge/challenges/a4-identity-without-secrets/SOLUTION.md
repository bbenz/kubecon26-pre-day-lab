# A4 · Walkthrough to the end state (facilitators)

> Spoilers. Messages below were captured on AKS Automatic 1.35 (westus3) on 2026-10-14.

## 1. Read the failure

```bash
kubectl logs -n a4-config deploy/config-reader --tail=2
# [06:47:55] FAILED at stage 'token-exchange': invalid_client: AADSTS700213: No matching federated identity record
#   found for presented assertion subject 'system:serviceaccount:a4-config:config-reader'. Check your federated
#   identity credential Subject, Audience and Issuer against the presented assertion. https://learn.microsoft.com/entra/workload-id/workload-identity-federation
kubectl get --raw /api/v1/namespaces/a4-config/services/config-reader:http/proxy/status
#   {"app": "config-reader", "ok": false, "stage": "token-exchange", "detail": "invalid_client: AADSTS700213: ...", ...}
```

The failure is in the **token exchange** (Entra), before Key Vault is even called.

## 2. Identify the workload's identity

```bash
kubectl get deploy config-reader -n a4-config -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'   # config-reader
kubectl get sa config-reader -n a4-config -o jsonpath='{.metadata.annotations}{"\n"}'   # azure.workload.identity/client-id
# presented subject = system:serviceaccount:a4-config:config-reader
```

## 3. Compare with the federated identity credential

```bash
RG=<lab resource group>
az identity federated-credential list -g $RG --identity-name id-ctf-config-reader \
  --query "[].{name:name, subject:subject, issuer:issuer, audiences:join(',', audiences)}" -o table
#   config-reader   system:serviceaccount:config-legacy:config-reader   https://<oidc issuer>/   api://AzureADTokenExchange
az aks show -g $RG -n <cluster> --query oidcIssuerProfile.issuerUrl -o tsv          # issuer matches
```

The subject still names the namespace the app was moved **out of** (`config-legacy`).

## 4. Fix the binding (Azure side)

```bash
az identity federated-credential update -g $RG --identity-name id-ctf-config-reader -n config-reader \
  --subject system:serviceaccount:a4-config:config-reader
```

(Portal: Managed Identities → `id-ctf-config-reader` → Federated credentials → `config-reader` → edit
*Namespace*.) The app retries every 20 seconds; no restart is needed.

## 5. Prove it

```bash
kubectl logs -n a4-config deploy/config-reader --tail=1          # OK - read secret 'lab-config' ...
kubectl get --raw /api/v1/namespaces/a4-config/services/config-reader:http/proxy/status      # "ok": true
kubectl get --raw /api/v1/namespaces/a4-config/services/report-generator:http/proxy/status   # still "ok": false
scoring/verify.sh --challenges a4
```

## End state

Matches [`challenge-end-state/challenges/a4-identity-without-secrets`](../../../challenge-end-state/challenges/a4-identity-without-secrets/README.md):
federated subject `system:serviceaccount:a4-config:config-reader`; Kubernetes objects unchanged.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Create a client secret / store credentials in a Secret | The requirement is secretless access; scoring checks for Secrets in the namespace. |
| Add a federated credential for `report-generator` too, or a wildcard claims-matching expression | Authorizes an unrelated workload – the negative test fails. |
| Grant Key Vault Administrator / Owner | Doesn't fix the token exchange, and breaks least privilege. |
| Move the app back to `config-legacy` | Changes the platform to match a stale credential instead of fixing the binding. |

## Stretch objective – notes

Authentication and authorization are separate: the token exchange proves *who* the workload is (a valid Entra
token for the managed identity). Reading a secret additionally requires an Azure RBAC role assignment (here
**Key Vault Secrets User** scoped to the one secret) – a valid token without a role gets `403 Forbidden` from Key
Vault (the app reports `stage: key-vault`).
