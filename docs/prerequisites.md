# Prerequisites

## Azure

| Requirement | Why | Check |
|---|---|---|
| Subscription where you are **Owner** (or Contributor + User Access Administrator / Role Based Access Control Administrator) | The deployment creates role assignments (AKS RBAC Cluster Admin for you; roles for the C4/A4 managed identities). | `az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --scope /subscriptions/<id> -o table` |
| Resource providers registered: `Microsoft.ContainerService`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.ManagedIdentity`, `Microsoft.PolicyInsights`, `Microsoft.CognitiveServices` (C4), `Microsoft.KeyVault` (A4), `Microsoft.Monitor`, `Microsoft.Insights`, `Microsoft.OperationalInsights`, `Microsoft.AlertsManagement`, `Microsoft.Dashboard`, `Microsoft.Storage` (leaderboard) | AKS Automatic enables Azure Policy (deployment safeguards) and monitoring (Managed Prometheus data collection rules are `Microsoft.Insights` resources). | `az provider show -n Microsoft.PolicyInsights --query registrationState` / `az provider register -n <namespace>` |
| A region where **AKS Automatic** is GA (see the [quickstart's list](https://learn.microsoft.com/azure/aks/automatic/quick-automatic-managed-network)) and that your organization's Azure Policy allows | Default: `westus3`. Check for location restrictions with `az policy assignment list --disable-scope-strict-match -o table`. | |
| vCPU quota for general-purpose **D-family** VMs in that region (≈ 16–24 vCPUs for all ten challenges) | Node auto-provisioning creates workload nodes on demand. System components run on AKS-managed nodes and need no quota. | `az vm list-usage -l <region> -o table` |
| **D-series sizes not restricted** for your subscription in the region (all zones) | Some subscriptions can't use certain series in certain zones; NAP skips restricted sizes, C3's fix must name allowed ones. | `az vm list-skus -l <region> --size Standard_D2s --query "[].{name:name, restrictions:restrictions[].reasonCode}" -o table` |
| **C4 only:** model `gpt-6-luna` (version `2026-09-22`) available as **GlobalStandard** in `AOAI_LOCATION` (default = region), with ≥ 50K TPM quota | The store assistant's model deployment. Change with `AOAI_MODEL_NAME` / `AOAI_MODEL_VERSION` / `AOAI_CAPACITY`. | `az cognitiveservices model list -l <region> --query "[?model.name=='gpt-6-luna'].model.version"` and `az cognitiveservices usage list -l <region> -o table` |

No preview feature registrations are needed: AKS Automatic, managed system node pools, the managed Gateway API CRDs,
the application routing add-on (managed NGINX and the Istio implementation), Managed Prometheus and LocalDNS are
all GA (Azure CLI ≥ 2.86).

> **Application routing NGINX support window.** Microsoft-supported security patches for the add-on's managed
> NGINX end in **November 2026**; enabling it is still allowed at the time of writing. Challenge C2 starts on it
> on purpose (it is the migration source). Re-check before the event that `az aks create --enable-app-routing` /
> `az aks approuting enable` still deploy NGINX on new clusters.

## Tools

| Tool | Version | Used by |
|---|---|---|
| Azure CLI (`az`) | ≥ 2.86 | all approaches (Terraform authenticates with it too) |
| `kubectl` and `kubelogin` | current (`az aks install-cli`) | all approaches, scoring |
| bash | 3.2+ (macOS) / 4+ — Linux, WSL, Git Bash for Windows, Azure Cloud Shell | `azure-cli-bash/`, `scoring/verify.sh` |
| PowerShell | **7.4+** (`pwsh`) on Windows, Linux or macOS | `azure-cli-powershell/`, `scoring/verify.ps1` |
| Terraform | ≥ 1.9 (tested with 1.16) — providers azurerm 5.9, azapi 2.13, alekc/kubectl 2.4, time 0.14 | `terraform/` |
| `curl` | any | `scoring/verify.sh` (C2), C2 side-by-side tests (`curl.exe` on Windows) |
| [`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway/releases) | 1.2.0 | **participants**, C2 (translates the Ingress to Gateway API; install commands in the C2 README) |
| An AI assistant (GitHub Copilot, Copilot in Azure, …) | – | **participants**, C2 (adapts the ingress2gateway draft – optional but intended) |
| A browser signed in to the Azure portal | – | **participants**, A2 (Managed Prometheus **Dashboards with Grafana**) and the C2 cutover check |

Azure Cloud Shell includes the Azure CLI, `kubectl`, PowerShell 7 and Terraform; run `az aks install-cli` if
`kubelogin` is missing. `ingress2gateway` is not included – download the Linux release (see the C2 README).

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
kubelogin convert-kubeconfig -l azurecli --tenant-id $(az account show --query tenantId -o tsv) --context <cluster>
```

`--tenant-id` pins the context to the cluster's Microsoft Entra tenant, so `kubectl` keeps working when your Azure
CLI's current subscription is in another tenant (the deploy scripts and Terraform's `connect` output do the same).

## Participant permissions (for later Skillable planning)

| Challenge | Kubernetes | Azure |
|---|---|---|
| All | RBAC Cluster Admin (or Admin on the challenge namespaces + read on nodes/NodePools) | Reader on the resource group |
| C2 | create Gateways/HTTPRoutes and delete Ingresses in `c2-storefront`; read IngressClasses, GatewayClasses and `nginxingresscontrollers` (cluster-scoped) | – (the cutover is a Kubernetes annotation; Azure creates the DNS name). The optional production step `az aks approuting update --nginx None` would need write access to the cluster – not part of the lab |
| C3 | edit `nodepools.karpenter.sh` (cluster-scoped) | – |
| C4 | – | read Foundry deployments (`az cognitiveservices account deployment list`) |
| A2 | – | open **Dashboards with Grafana** on the cluster: read access to the Azure Monitor workspace's data. Owner worked in testing (no extra role); with a narrower role add **Monitoring Data Reader** on the workspace (`amw-ctf-<id>` in the lab resource group). `kubectl top` and `/stats` work without it |
| A4 | – | update federated credentials on `id-ctf-config-reader` (Managed Identity Contributor on the identity, or resource-group Contributor) |
| Leaderboard (optional) | – | none: lab VMs only need outbound HTTPS to the leaderboard's storage account (`<account>.blob.core.windows.net`) and `curl` for `verify.sh`; the token comes from a Skillable life cycle action. The **instructor** needs Storage Blob Data Reader on that account to show the board ([leaderboard/README.md](../leaderboard/README.md)) |
