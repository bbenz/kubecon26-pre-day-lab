# KubeCon 2026 · AKS capture-the-flag lab (pre-day) – evaluation code

Working code to deploy and evaluate the **AKS Automatic troubleshooting challenges** proposed for the KubeCon North
America 2026 Azure Day pre-day lab (*"Capture the Flag AKS Lab"*). Every challenge can be deployed to Microsoft Azure
in its **begin state** (seeded fault) or its **end state** (solved) with three interchangeable approaches:
**Terraform**, the **Azure CLI in bash**, and the **Azure CLI in PowerShell**.

> This repository is for **evaluating the challenges** (feasibility, timing, participant experience) before the
> final selection. It contains the solutions. A participant-facing version (Skillable lab, LCA/scoring scripts)
> comes later.

## Repository layout

```text
begin-challenge/          deploy the challenges WITH their faults + participant instructions and walkthroughs
  azure-cli-bash/         deploy.sh, cleanup.sh
  azure-cli-powershell/   deploy.ps1, cleanup.ps1
  terraform/              Terraform root module
  challenges/<id>-*/      README.md (briefing, success criteria, hints, feasibility), SOLUTION.md, manifests/
challenge-end-state/      deploy the challenges SOLVED (same structure; README per challenge = what changed)
scoring/                  verify.sh / verify.ps1 - checks each challenge against its success criteria
shared/                   code shared by both states (bash library, PowerShell module, Terraform modules)
tests/                    local smoke tests on kind (no Azure needed)
docs/                     prerequisites, architecture, testing
FEASIBILITY.md            feasibility summary and recommended line-up
```

## The challenges

| ID | Challenge | Topic | Namespace |
|---|---|---|---|
| C1 | [The store won't start](begin-challenge/challenges/c1-the-store-wont-start/README.md) | CrashLoopBackOff, previous logs, ConfigMaps | `c1-store` |
| C2 | [Healthy pods, broken storefront](begin-challenge/challenges/c2-healthy-pods-broken-storefront/README.md) | Gateway API (app routing, Istio), Service ports | `c2-storefront` |
| C3 | [Capacity that never arrives](begin-challenge/challenges/c3-capacity-that-never-arrives/README.md) | Node auto-provisioning (Karpenter) NodePools | `c3-processing` |
| C4 | [The AI assistant is up, but not working](begin-challenge/challenges/c4-ai-assistant-up-but-not-working/README.md) | Microsoft Foundry / Azure OpenAI dependency, workload identity | `c4-assistant` |
| A1 | [Where did DNS go?](begin-challenge/challenges/a1-where-did-dns-go/README.md) | NetworkPolicy egress, DNS | `a1-inventory` |
| A2 | [Fast yesterday, slow today](begin-challenge/challenges/a2-fast-yesterday-slow-today/README.md) | CPU limits and throttling | `a2-checkout` |
| A3 | [Ready for maintenance?](begin-challenge/challenges/a3-ready-for-maintenance/README.md) | PodDisruptionBudgets, evictions | `a3-maintenance` |
| A4 | [Identity without secrets](begin-challenge/challenges/a4-identity-without-secrets/README.md) | Workload identity federation, Key Vault | `a4-config` |
| A5 | [Running is not ready](begin-challenge/challenges/a5-running-is-not-ready/README.md) | Readiness probes, rollouts | `a5-releases` |
| A6 | [The data survived, the application didn't](begin-challenge/challenges/a6-data-survived-app-didnt/README.md) | PVCs, Azure Disk | `a6-records` |

**Feasibility and recommended line-up:** [FEASIBILITY.md](FEASIBILITY.md)

## Quick start

Prerequisites ([details](docs/prerequisites.md)): an Azure subscription where you are **Owner** (or Contributor +
User Access Administrator), Azure CLI ≥ 2.86, `kubectl` + `kubelogin` (`az aks install-cli`), and either bash,
PowerShell 7.4+ or Terraform ≥ 1.9. Sign in with `az login`.

```bash
# 1. Deploy the begin state (pick one approach)
./begin-challenge/azure-cli-bash/deploy.sh                    # bash
./begin-challenge/azure-cli-powershell/deploy.ps1             # PowerShell
(cd begin-challenge/terraform && terraform init && terraform apply -var="subscription_id=$(az account show --query id -o tsv)")

# 2. Work through a challenge
#    begin-challenge/challenges/<id>-*/README.md  (briefing, hints)  ->  SOLUTION.md (walkthrough)

# 3. Score it
scoring/verify.sh --challenges c1           # or: ./scoring/verify.ps1 -Challenges c1

# 4. Clean up
./begin-challenge/azure-cli-bash/cleanup.sh
```

To see the solved configuration, deploy [`challenge-end-state`](challenge-end-state) the same way (its own resource
group by default) – every challenge should then pass `scoring/verify`.

**Sharing a subscription with others?** The default resource group names are the same for everyone, so pass your
own (`-g` in bash, `-ResourceGroup` in PowerShell, `resource_group_name` in Terraform), for example
`rg-<alias>-ctf-begin` and `rg-<alias>-ctf-end`. The globally unique names (Key Vault, Foundry account, storefront
DNS label) are derived from the subscription and resource group, so they follow automatically.

## How the environment is built

One **AKS Automatic** cluster per environment (managed system node pool, node auto-provisioning, Azure CNI + Cilium,
Azure RBAC, deployment safeguards, Gateway API via the application routing add-on). Each challenge lives in its own
namespace, so all ten can run side by side and be reset independently. Azure services are created only for the
challenges that need them: a Microsoft Foundry account + model deployment and a workload identity for **C4**, a
Key Vault + workload identity for **A4**. See [docs/architecture.md](docs/architecture.md).

## Testing without Azure

The Kubernetes-only challenges (C1, A1, A2, A3, A5, A6) can be exercised on a local **kind** cluster with the same
bash library, PowerShell module and Terraform module the Azure deployment uses – see [docs/testing.md](docs/testing.md).

## Status

Code complete, validated locally (kind) and **piloted on Azure** on 2026-10-14 (AKS Automatic 1.35, westus3): the
begin state was deployed with the PowerShell and bash scripts and the end state with Terraform. In the final run every
challenge failed as designed in the begin state and passed in the end state. Pilot results and the changes they
led to are in [FEASIBILITY.md](FEASIBILITY.md#pilot-gates--results-of-the-first-azure-deployment-2026-10-14-westus3-aks-automatic-1358).
