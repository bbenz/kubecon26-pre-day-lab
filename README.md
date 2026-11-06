# AKS capture-the-flag lab · KubeCon North America 2026

Hands-on troubleshooting challenges for **Azure Kubernetes Service (AKS) Automatic**, from the KubeCon North America
2026 Azure Day pre-day lab (*Capture the Flag AKS Lab*). Each challenge is a realistic fault, deployed into its own
namespace of an AKS Automatic cluster: find it, fix it, and check your work with one command. Try them in your own
Azure subscription with any of three deployment approaches: **Terraform**, the **Azure CLI in bash**, or the
**Azure CLI in PowerShell**.

## The challenges

| ID | Challenge | Topic | Namespace |
|---|---|---|---|
| C1 | [The store won't start](begin-challenge/challenges/c1-the-store-wont-start/README.md) | CrashLoopBackOff, previous logs, ConfigMaps | `c1-store` |
| C2 | [Move the storefront to Gateway API](begin-challenge/challenges/c2-ingress-nginx-to-gateway-api/README.md) | Ingress-NGINX → Gateway API migration (application routing add-on, ingress2gateway, AI-assisted) | `c2-storefront` |
| C3 | [Capacity that never arrives](begin-challenge/challenges/c3-capacity-that-never-arrives/README.md) | Node auto-provisioning (Karpenter) NodePools | `c3-processing` |
| C4 | [The AI assistant is up, but not working](begin-challenge/challenges/c4-ai-assistant-up-but-not-working/README.md) | Microsoft Foundry / Azure OpenAI dependency, workload identity | `c4-assistant` |
| A1 | [Where did DNS go?](begin-challenge/challenges/a1-where-did-dns-go/README.md) | NetworkPolicy egress, DNS | `a1-inventory` |
| A2 | [Fast yesterday, slow today](begin-challenge/challenges/a2-fast-yesterday-slow-today/README.md) | CPU limits and throttling, Managed Prometheus dashboards | `a2-checkout` |
| A3 | [Ready for maintenance?](begin-challenge/challenges/a3-ready-for-maintenance/README.md) | PodDisruptionBudgets, evictions | `a3-maintenance` |
| A4 | [Identity without secrets](begin-challenge/challenges/a4-identity-without-secrets/README.md) | Workload identity federation, Key Vault | `a4-config` |
| A5 | [Running is not ready](begin-challenge/challenges/a5-running-is-not-ready/README.md) | Readiness probes, rollouts | `a5-releases` |
| A6 | [The data survived, the application didn't](begin-challenge/challenges/a6-data-survived-app-didnt/README.md) | PVCs, Azure Disk | `a6-records` |

Each challenge's README has a briefing, the success criteria, and hints that you can expand when you need them.

## Try it in your own subscription

Prerequisites ([details](docs/prerequisites.md)): an Azure subscription where you are **Owner** (or Contributor +
User Access Administrator), Azure CLI ≥ 2.86, `kubectl` + `kubelogin` (`az aks install-cli`), and either bash,
PowerShell 7.4+ or Terraform ≥ 1.9. Sign in with `az login`.

```bash
# 1. Deploy the challenges, each with its fault in place (pick one approach; 15-25 minutes)
./begin-challenge/azure-cli-bash/deploy.sh                    # bash
./begin-challenge/azure-cli-powershell/deploy.ps1             # PowerShell
(cd begin-challenge/terraform && terraform init && terraform apply -var="subscription_id=$(az account show --query id -o tsv)")

# 2. Work through a challenge: begin-challenge/challenges/<id>-*/README.md

# 3. Check your work
scoring/verify.sh --challenges c1                    # or: ./scoring/verify.ps1 -Challenges c1

# 4. Start a challenge over
./begin-challenge/azure-cli-bash/deploy.sh -c c1     # or: ./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c1

# 5. Clean up: deletes the resource group and everything in it
./begin-challenge/azure-cli-bash/cleanup.sh          # or: ./begin-challenge/azure-cli-powershell/cleanup.ps1
```

Options, resets with Terraform, and troubleshooting tips for AKS Automatic: [begin-challenge/README.md](begin-challenge/README.md).
What each check looks at: [scoring/README.md](scoring/README.md).

**Sharing a subscription with others?** The default resource group names are the same for everyone, so pass your
own (`-g` in bash, `-ResourceGroup` in PowerShell, `resource_group_name` in Terraform), for example
`rg-<alias>-ctf`. The globally unique names (Key Vault, Foundry account, storefront DNS label) are derived from the
subscription and resource group, so they follow automatically.

## Try it without Azure

The challenges that need no Azure services (C1, A1, A2, A3, A5, A6) also run on a local **kind** cluster, with the
same bash library, PowerShell module, and Terraform module that the Azure deployment uses:

```bash
kind create cluster --name ctf
tests/kind/apply-local.sh begin                         # or: ./tests/kind/apply-local.ps1
scoring/verify.sh --context kind-ctf --challenges c1    # or: ./scoring/verify.ps1 -Context kind-ctf -Challenges c1
```

A1 behaves differently on AKS Automatic, so try it on Azure too.

## How the environment is built

One **AKS Automatic** cluster per environment (managed system node pool, node auto-provisioning, Azure CNI + Cilium,
Azure RBAC, deployment safeguards, the application routing add-on with managed NGINX **and** Gateway API, Managed
Prometheus). Each challenge lives in its own namespace, so all ten can run side by side and be reset independently.
Azure services are created only for the challenges that need them: a Microsoft Foundry account + model deployment
and a workload identity for **C4**, a Key Vault + workload identity for **A4**; the Azure Monitor workspace that
backs the **A2** dashboards stays in the lab resource group. See [docs/architecture.md](docs/architecture.md).

## Repository layout

```text
begin-challenge/          deploy the challenges with their faults, and each challenge's instructions
  azure-cli-bash/         deploy.sh, cleanup.sh
  azure-cli-powershell/   deploy.ps1, cleanup.ps1
  terraform/              Terraform root module
  challenges/<id>-*/      README.md (briefing, success criteria, hints) and manifests/
scoring/                  verify.sh / verify.ps1 - check a challenge against its success criteria;
                          join-leaderboard.sh / .ps1 - join an event's leaderboard
shared/                   code the three approaches share (bash library, PowerShell module, Terraform modules)
skillable/                the hosted lab: lab VM image setup, life cycle actions, and the lab instructions
tests/                    run the Kubernetes-only challenges on a local kind cluster
docs/                     prerequisites and architecture
```

## The hosted lab

The hosted version of this lab runs on Skillable: each attendee gets a lab VM with the tools installed and this
repository in `C:\LabFiles\kubecon26-pre-day-lab`, and an AKS Automatic cluster with every challenge deployed.
[skillable/](skillable/README.md) has the scripts that build it, and the lab instructions.