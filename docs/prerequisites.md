# Prerequisites

## Azure

| Requirement | Why | Check |
|---|---|---|
| Subscription where you are **Owner** (or Contributor + User Access Administrator / Role Based Access Control Administrator) | The deployment creates role assignments (AKS RBAC Cluster Admin for you; roles for the C4/A4 managed identities). | `az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --scope /subscriptions/<id> -o table` |
| Resource providers registered: `Microsoft.ContainerService`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.ManagedIdentity`, `Microsoft.PolicyInsights`, `Microsoft.CognitiveServices` (C4), `Microsoft.KeyVault` (A4), `Microsoft.Monitor`, `Microsoft.OperationalInsights`, `Microsoft.AlertsManagement`, `Microsoft.Dashboard` | AKS Automatic enables Azure Policy (deployment safeguards) and monitoring. | `az provider show -n Microsoft.PolicyInsights --query registrationState` / `az provider register -n <namespace>` |
| A region where **AKS Automatic** is GA (see the [quickstart's list](https://learn.microsoft.com/azure/aks/automatic/quick-automatic-managed-network)) | Default: `westus3`. | |
| vCPU quota for general-purpose **D-family** VMs in that region (≈ 16–24 vCPUs for all ten challenges) | Node auto-provisioning creates workload nodes on demand. System components run on AKS-managed nodes and need no quota. | `az vm list-usage -l <region> -o table` |
| **D-series sizes not restricted** for your subscription in the region (all zones) | Some subscriptions can't use certain series in certain zones; NAP skips restricted sizes, C3's fix must name allowed ones. | `az vm list-skus -l <region> --size Standard_D2s --query "[].{name:name, restrictions:restrictions[].reasonCode}" -o table` |
| **C4 only:** model `gpt-6-luna` (version `2026-09-22`) available as **GlobalStandard** in `AOAI_LOCATION` (default = region), with ≥ 50K TPM quota | The store assistant's model deployment. Change with `AOAI_MODEL_NAME` / `AOAI_MODEL_VERSION` / `AOAI_CAPACITY`. | `az cognitiveservices model list -l <region> --query "[?model.name=='gpt-6-luna'].model.version"` and `az cognitiveservices usage list -l <region> -o table` |

No preview feature registrations are needed: AKS Automatic, managed system node pools, the managed Gateway API CRDs,
the application routing Istio implementation and LocalDNS are all GA (Azure CLI ≥ 2.86).

## Tools

| Tool | Version | Used by |
|---|---|---|
| Azure CLI (`az`) | ≥ 2.86 | all approaches (Terraform authenticates with it too) |
| `kubectl` and `kubelogin` | current (`az aks install-cli`) | all approaches, scoring |
| bash | 3.2+ (macOS) / 4+ — Linux, WSL, Git Bash for Windows, Azure Cloud Shell | `azure-cli-bash/`, `scoring/verify.sh` |
| PowerShell | **7.4+** (`pwsh`) on Windows, Linux or macOS | `azure-cli-powershell/`, `scoring/verify.ps1` |
| Terraform | ≥ 1.9 (tested with 1.16) — providers azurerm 5.9, azapi 2.13, alekc/kubectl 2.4, time 0.14 | `terraform/` |
| `curl` | any | `scoring/verify.sh` (C2) |

Azure Cloud Shell includes the Azure CLI, `kubectl`, PowerShell 7 and Terraform; run `az aks install-cli` if
`kubelogin` is missing.

### The `aks-preview` extension

If the `aks-preview` Azure CLI extension is installed it replaces `az aks` commands with preview versions. The
scripts detect it and run `az aks create/update` with the core (GA) implementation for that one command (via an
empty `AZURE_EXTENSION_DIR`); your installation is not changed.

## Kubernetes access on AKS Automatic

AKS Automatic disables local accounts and uses Azure RBAC for Kubernetes authorization. You need
**Azure Kubernetes Service RBAC Cluster Admin** on the cluster (subscription Owner is *not* enough). All three
deployment approaches assign it to the signed-in user on the lab resource group before the cluster is created. To
give someone else access:

```bash
az role assignment create --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --assignee <user-or-object-id> --scope $(az group show -n <resource-group> --query id -o tsv)
az aks get-credentials -g <resource-group> -n <cluster>
kubelogin convert-kubeconfig -l azurecli --context <cluster>
```

## Participant permissions (for later Skillable planning)

| Challenge | Kubernetes | Azure |
|---|---|---|
| All | RBAC Cluster Admin (or Admin on the challenge namespaces + read on nodes/NodePools) | Reader on the resource group |
| C3 | edit `nodepools.karpenter.sh` (cluster-scoped) | – |
| C4 | – | read Foundry deployments (`az cognitiveservices account deployment list`) |
| A4 | – | update federated credentials on `id-ctf-config-reader` (Managed Identity Contributor on the identity, or resource-group Contributor) |
