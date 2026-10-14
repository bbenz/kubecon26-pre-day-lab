# A4 · Identity without secrets

| | |
|---|---|
| **Round** | Additional candidate (swap-in for C4) · Intermediate–advanced |
| **Namespace** | `a4-config` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | Azure Key Vault (RBAC) with a harmless lab value, user-assigned managed identity `id-ctf-config-reader` with a federated identity credential, AKS workload identity (OIDC issuer) |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> `config-reader` cannot read its lab configuration value from Key Vault since it was moved to a new namespace.
> Restore identity-based access **without adding a client secret or any stored credential**.
> `report-generator` (same namespace) is **not** supposed to have access – keep it that way.

## Learning objective

Trace Kubernetes service-account identity to Azure authorization without introducing stored credentials.

## What's running

* `config-reader` and `report-generator` – every 20–60 s they exchange their pod's service-account token for a
  Microsoft Entra token (workload identity federation) and try to read the secret `lab-config` from Key Vault.
  Results: container logs and `GET /status`. Tokens are never logged.
* Azure: Key Vault `kv-ctf-<id>`, managed identity `id-ctf-config-reader` (Key Vault Secrets User on that one
  secret), and its federated identity credential `config-reader`.

```bash
kubectl get deploy,sa,pods -n a4-config
kubectl logs -n a4-config deploy/config-reader --tail=3
kubectl get --raw /api/v1/namespaces/a4-config/services/config-reader:http/proxy/status
```

You need Azure CLI (or portal) access to the lab resource group, e.g.
`az identity federated-credential list -g <resource-group> --identity-name id-ctf-config-reader -o table`.

## Success criteria

1. `config-reader` retrieves the lab value through workload identity.
2. `report-generator` remains **unauthorized**.
3. No new credentials (no client secrets, no Kubernetes Secrets) and no broad role grants; the existing
   least-privilege access (one secret) is preserved.

```bash
scoring/verify.sh --challenges a4          # bash
./scoring/verify.ps1 -Challenges a4        # PowerShell
```

## Hints

<details><summary>Hint 1 – Separate token exchange from resource authorization</summary>

Read the `stage` in `/status` or the log line: does the failure happen when exchanging the Kubernetes token for an
Entra token, or when calling Key Vault?
</details>

<details><summary>Hint 2 – Identify the actual namespace and service account</summary>

`kubectl get pod -n a4-config -l app=config-reader -o jsonpath='{.items[0].spec.serviceAccountName}'` – the token
subject is `system:serviceaccount:<namespace>:<service-account>`.
</details>

<details><summary>Hint 3 – Compare the exact federation subject with that identity</summary>

`az identity federated-credential list -g <rg> --identity-name id-ctf-config-reader -o table` – issuer, subject and
audience must match the token exactly.
</details>

## What doesn't count

* Client secrets, API keys or certificates; storing a token in a Kubernetes Secret.
* Granting the identity (or the namespace's workloads) broader roles, e.g. Key Vault Administrator / Owner.
* A wildcard / claims-matching federation that also authorizes `report-generator`.

## Stretch objective

Explain why a successful sign-in does not, by itself, grant permission to read a Key Vault secret.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a4      # also resets the federated credential subject
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a4
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **Medium–high.** Workload identity and the OIDC issuer are preconfigured on AKS Automatic. The seeded fault is one Azure-side value: the federated credential subject still names the old namespace (`system:serviceaccount:config-legacy:config-reader`). Entra rejects the exchange with `AADSTS700213`/`AADSTS70021` ("No matching federated identity record found for presented assertion subject ...") and the app logs it verbatim. Federated-credential changes propagate in seconds, and the Key Vault role is already in place, so there is a single fault. The secret is written through ARM, so no data-plane role is needed for the deployer. |
| **Validation status** | Validated **on AKS Automatic 1.35 (westus3, 2026-10-14)**: begin – `FAILED at stage 'token-exchange': invalid_client: AADSTS700213: No matching federated identity record found for presented assertion subject 'system:serviceaccount:a4-config:config-reader'`; end (subject `system:serviceaccount:a4-config:config-reader`) – the secret is read with workload identity while `report-generator` stays unauthorized. Terraform plans show the begin vs. end subject. |
| **Fit for 200-level users** | Medium. Workload identity federation is an advanced concept, but the error message contains the presented subject, so comparing it with the credential is straightforward. Participants need Azure permissions to edit the identity (resource-group Contributor or Managed Identity Contributor) – plan this for Skillable. |
| **Expected time** | 15–20 min. |
| **Risks** | Azure-side permission model for students; occasional RBAC propagation delay on a fresh environment (the app retries every 20 s). |
| **Opinion** | **Good swap-in for C4** (same "Azure dependency" learning without model quota), or a strong alternate for security-focused audiences. |
