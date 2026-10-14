# Challenge end state – deploy the challenges solved

Everything in this folder deploys the **END state** of the KubeCon AKS capture-the-flag challenges: the same
AKS Automatic environment as [`begin-challenge`](../begin-challenge), with every challenge in the state a participant
reaches after the expected repair.

Use it to:

* **validate the reference solutions** – every challenge should pass `scoring/verify.*`;
* **demo the fixed system** in the debrief, or compare broken vs. fixed side by side;
* **solve a begin-state environment in place** (apply on top of it) to check that the documented fix converges.

| Folder | What it is |
|---|---|
| [`azure-cli-bash/`](azure-cli-bash) | `deploy.sh`, `cleanup.sh` |
| [`azure-cli-powershell/`](azure-cli-powershell) | `deploy.ps1`, `cleanup.ps1` |
| [`terraform/`](terraform) | Terraform root module |
| [`challenges/`](challenges) | Per challenge: **README** (what changed vs. the begin state) and the solved **manifests** (plus `azure.env` for A4) |

Prerequisites: [docs/prerequisites.md](../docs/prerequisites.md). Options are identical to the begin state
([begin-challenge/README.md](../begin-challenge/README.md#defaults-and-options)); the default resource groups are
`rg-kubecon-ctf-end-bash` / `-pwsh` / `-tf`.

## Deploy

```bash
./challenge-end-state/azure-cli-bash/deploy.sh                      # all challenges, westus3
./challenge-end-state/azure-cli-bash/deploy.sh -c c1,c3
```

```powershell
./challenge-end-state/azure-cli-powershell/deploy.ps1
./challenge-end-state/azure-cli-powershell/deploy.ps1 -Challenges c1,c3
```

```bash
cd challenge-end-state/terraform
cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply
```

If several people deploy into the same subscription, give each environment its own resource group
(`-g` / `-ResourceGroup` / `resource_group_name`, for example `rg-<alias>-ctf-end`).

### Solve an existing begin-state environment in place (scripts only)

```bash
./challenge-end-state/azure-cli-bash/deploy.sh -g rg-kubecon-ctf-begin-bash -c c1
./challenge-end-state/azure-cli-powershell/deploy.ps1 -ResourceGroup rg-kubecon-ctf-begin-pwsh -Challenges c1
```

The end-state scripts apply on top of what is there (no reset unless `--reset` / `-Reset`). Re-running the
begin-state deploy afterwards breaks the challenge again. With Terraform, keep begin and end in separate resource
groups (each folder has its own state).

## Verify

```bash
scoring/verify.sh --context aks-kubecon-ctf-end-bash          # every challenge should be PASSED
./scoring/verify.ps1 -Context aks-kubecon-ctf-end-pwsh
```

Notes for a **fresh** end-state deployment: C3 needs a few minutes for node auto-provisioning before its Job
completes, and C4/A4 may need 1–5 minutes for new role assignments to propagate (the checks wait and retry).

## Per-challenge end states

| ID | What changes from the begin state | Details |
|---|---|---|
| C1 | ConfigMap `FASTIFY_ADDRESS` → `0.0.0.0` (+ `FASTIFY_PORT: 3000`), new rollout | [README](challenges/c1-the-store-wont-start/README.md) |
| C2 | HTTPRoute `backendRefs[0].port` 8080 → 80 | [README](challenges/c2-healthy-pods-broken-storefront/README.md) |
| C3 | NodePool approved SKUs: Arm64 → amd64 (v5/v6/v7) | [README](challenges/c3-capacity-that-never-arrives/README.md) |
| C4 | `AZURE_OPENAI_DEPLOYMENT_NAME`: retired deployment → provisioned deployment | [README](challenges/c4-ai-assistant-up-but-not-working/README.md) |
| A1 | NetworkPolicy: + DNS (UDP/TCP 53) to LocalDNS / kube-dns only | [README](challenges/a1-where-did-dns-go/README.md) |
| A2 | `checkout-api` CPU limit 100m → 1 (request 500m) | [README](challenges/a2-fast-yesterday-slow-today/README.md) |
| A3 | `inventory-api` replicas 1 → 2 (PDB unchanged) | [README](challenges/a3-ready-for-maintenance/README.md) |
| A4 | Federated credential subject → `system:serviceaccount:a4-config:config-reader` | [README](challenges/a4-identity-without-secrets/README.md) |
| A5 | Readiness `/healthz` → `/ready`, `maxUnavailable` 1 → 0 | [README](challenges/a5-running-is-not-ready/README.md) |
| A6 | `claimName` `records-data-v2` → `records-data` | [README](challenges/a6-data-survived-app-didnt/README.md) |

Tip: `git diff --no-index begin-challenge/challenges/c1-the-store-wont-start/manifests challenge-end-state/challenges/c1-the-store-wont-start/manifests`
shows a fix exactly.

## Clean up

```bash
./challenge-end-state/azure-cli-bash/cleanup.sh
./challenge-end-state/azure-cli-powershell/cleanup.ps1
cd challenge-end-state/terraform && terraform destroy
```

The Azure CLI deployments also create (or reuse) `DefaultResourceGroup-<region>` with a Log Analytics workspace
for Container Insights (`az aks create` monitoring defaults). It is shared by every CLI-created cluster in the
subscription and is not deleted by the cleanup scripts – remove it yourself when nothing else uses it.
