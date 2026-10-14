# Begin challenge – deploy the challenges with their seeded faults

Everything in this folder deploys the **BEGIN state** of the KubeCon AKS capture-the-flag challenges: an
[AKS Automatic](https://learn.microsoft.com/azure/aks/intro-aks-automatic) cluster plus the Azure services the
selected challenges need, with each challenge's fault in place. Participants (or you, while evaluating) then work
from here to the end state.

| Folder | What it is |
|---|---|
| [`azure-cli-bash/`](azure-cli-bash) | `deploy.sh`, `cleanup.sh` – Azure CLI in bash (Linux, macOS, WSL, Git Bash, Cloud Shell) |
| [`azure-cli-powershell/`](azure-cli-powershell) | `deploy.ps1`, `cleanup.ps1` – Azure CLI in PowerShell 7.4+ (Windows, Linux, macOS, Cloud Shell) |
| [`terraform/`](terraform) | Terraform root module (azurerm 5.x, azapi 2.x, alekc/kubectl) |
| [`challenges/`](challenges) | One folder per challenge: participant **README** (briefing, success criteria, hints, feasibility), **SOLUTION** walkthrough to the end state, and the Kubernetes **manifests** |

All three approaches create the same environment. Prerequisites: [docs/prerequisites.md](../docs/prerequisites.md).

## The challenges

| ID | Challenge | Namespace | Instructions | How to reach the end state |
|---|---|---|---|---|
| C1 | The store won't start | `c1-store` | [README](challenges/c1-the-store-wont-start/README.md) | [SOLUTION](challenges/c1-the-store-wont-start/SOLUTION.md) |
| C2 | Healthy pods, broken storefront | `c2-storefront` | [README](challenges/c2-healthy-pods-broken-storefront/README.md) | [SOLUTION](challenges/c2-healthy-pods-broken-storefront/SOLUTION.md) |
| C3 | Capacity that never arrives | `c3-processing` | [README](challenges/c3-capacity-that-never-arrives/README.md) | [SOLUTION](challenges/c3-capacity-that-never-arrives/SOLUTION.md) |
| C4 | The AI assistant is up, but not working | `c4-assistant` | [README](challenges/c4-ai-assistant-up-but-not-working/README.md) | [SOLUTION](challenges/c4-ai-assistant-up-but-not-working/SOLUTION.md) |
| A1 | Where did DNS go? | `a1-inventory` | [README](challenges/a1-where-did-dns-go/README.md) | [SOLUTION](challenges/a1-where-did-dns-go/SOLUTION.md) |
| A2 | Fast yesterday, slow today | `a2-checkout` | [README](challenges/a2-fast-yesterday-slow-today/README.md) | [SOLUTION](challenges/a2-fast-yesterday-slow-today/SOLUTION.md) |
| A3 | Ready for maintenance? | `a3-maintenance` | [README](challenges/a3-ready-for-maintenance/README.md) | [SOLUTION](challenges/a3-ready-for-maintenance/SOLUTION.md) |
| A4 | Identity without secrets | `a4-config` | [README](challenges/a4-identity-without-secrets/README.md) | [SOLUTION](challenges/a4-identity-without-secrets/SOLUTION.md) |
| A5 | Running is not ready | `a5-releases` | [README](challenges/a5-running-is-not-ready/README.md) | [SOLUTION](challenges/a5-running-is-not-ready/SOLUTION.md) |
| A6 | The data survived, the application didn't | `a6-records` | [README](challenges/a6-data-survived-app-didnt/README.md) | [SOLUTION](challenges/a6-data-survived-app-didnt/SOLUTION.md) |

Feasibility summary and recommended line-up: [FEASIBILITY.md](../FEASIBILITY.md).

## Deploy

Sign in first: `az login` (and `az account set -s <subscription>`). A fresh environment takes about
**15–25 minutes** (AKS Automatic cluster ≈ 10 min, then the Azure services and the challenges; measured in the
pilot: 15–20 min). Run the commands from the repository root.

### Azure CLI – bash

```bash
./begin-challenge/azure-cli-bash/deploy.sh                       # all challenges, westus3
./begin-challenge/azure-cli-bash/deploy.sh -c c1,c2,c3,c4        # only the core challenges
./begin-challenge/azure-cli-bash/deploy.sh -c a5 -l centralus -g rg-my-ctf
./begin-challenge/azure-cli-bash/deploy.sh --help
```

### Azure CLI – PowerShell

```powershell
./begin-challenge/azure-cli-powershell/deploy.ps1
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c1,c2,c3,c4
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a5 -Location centralus -ResourceGroup rg-my-ctf
Get-Help ./begin-challenge/azure-cli-powershell/deploy.ps1 -Detailed
```

### Terraform

```bash
cd begin-challenge/terraform
cp terraform.tfvars.example terraform.tfvars        # set subscription_id, location, challenges
terraform init
terraform apply
$(terraform output -raw connect)                    # az aks get-credentials + kubelogin
```

Terraform also needs `kubelogin` on `PATH` (it authenticates the kubectl provider with your Azure CLI sign-in).

### Defaults and options

| Setting | bash / env var | PowerShell | Terraform variable | Default |
|---|---|---|---|---|
| Challenges | `-c` / `CHALLENGES` | `-Challenges` | `challenges` | all |
| Region | `-l` / `LOCATION` | `-Location` | `location` | `westus3` |
| Resource group | `-g` / `RESOURCE_GROUP` | `-ResourceGroup` | `resource_group_name` | `rg-kubecon-ctf-begin-bash` / `-pwsh` / `-tf` |
| Cluster (= kubectl context) | `-n` / `CLUSTER_NAME` | `-ClusterName` | `cluster_name` | `aks-` + resource group without `rg-` |
| C4 model | `AOAI_MODEL_NAME`, `AOAI_MODEL_VERSION`, `AOAI_CAPACITY`, `AOAI_DEPLOYMENT_NAME`, `AOAI_LOCATION` | `-ModelName` … | `aoai_*` | `gpt-6-luna` `2026-09-22`, 50K TPM, deployment `store-assistant` |
| Re-create challenges | `--reset` (default) / `--no-reset` | default / `-NoReset` | n/a | reset |
| Only (re)apply challenges | `--skip-infra` | `-SkipInfra` | n/a | off |

Each approach uses its own default resource group, so they can run side by side. Don't point two Terraform
states (or Terraform and a script) at the same resource group. If several people deploy into the same subscription,
give each environment its own resource group (for example `-g rg-<alias>-ctf-begin`); otherwise a second deployment
reuses – and, in the begin state, resets – the first person's challenges.

### If a deployment stops with an error

Every approach is safe to run again: the scripts reuse what already exists, and Terraform continues from its
state. Transient errors seen in the pilot – `HTTP response was nil; connection may have been reset` (Terraform),
an `az rest` call timing out (the scripts retry it three times), or `TLS handshake timeout` from kubectl – are
fixed by simply re-running the same command. If you deployed only part of the challenges with `-c` /
`-Challenges`, re-run with the same selection (the begin-state scripts reset the selected challenges).

## After deployment

```bash
kubectl config use-context aks-kubecon-ctf-begin-bash    # the cluster name; printed by the deploy script
kubectl get namespaces -l kubecon.lab/challenge
```

* Work through a challenge with its **README** (briefing, success criteria, hints). The **SOLUTION** walks from the
  begin state to the end state with exact commands.
* Check progress against the success criteria at any time (only needs `kubectl` and `curl`):
  `scoring/verify.sh --challenges c1` or `./scoring/verify.ps1 -Challenges c1`
  ([scoring/README.md](../scoring/README.md)). In the begin state every challenge reports **NOT PASSED**.
* To compare with the solved configuration, see [`../challenge-end-state`](../challenge-end-state) – the diff between
  a challenge's `manifests/` folders here and there *is* the fix.

### Troubleshooting tips for AKS Automatic

AKS Automatic enforces [deployment safeguards](https://aka.ms/aks/deployment-safeguards) and a baseline pod security
policy, which changes a few familiar debugging habits:

* **Prefer `kubectl exec` into the application's own pods** – every challenge image includes the tools its
  walkthrough needs (`curl`/`wget`, `getent`/`nslookup`).
* A throw-away `kubectl run` pod is **denied** unless it sets resource requests:
  `kubectl run dbg -n <ns> --image=mcr.microsoft.com/azurelinux/busybox:1.36 --restart=Never --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"dbg","image":"mcr.microsoft.com/azurelinux/busybox:1.36","command":["sleep","600"],"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}]}}'`
  (missing probes only produce warnings).
* `kubectl debug` works with the **baseline** or **restricted** profile:
  `kubectl debug -n <ns> <pod> -it --image=mcr.microsoft.com/azurelinux/busybox:1.36 --profile=baseline -- sh`.
  The default/`general` profile adds `SYS_PTRACE` and is rejected.
* `kubectl apply` prints `Warning: <name> had anti-affinity and topology spread constraints added ...` for most
  Deployments – that is the safeguards mutating policy, not an error.
* Pods resolve DNS through **LocalDNS**, a cache on every node (`nameserver 169.254.10.11` in `/etc/resolv.conf`).

## Reset a challenge

Re-run the deploy for that challenge – by default it deletes the challenge's namespace (and, for C3, its NodePool and
nodes; for A4 it resets the federated credential) and re-creates it broken:

```bash
./begin-challenge/azure-cli-bash/deploy.sh -c c3
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c3
```

With Terraform, destroy that challenge's Kubernetes objects, wait until its namespace is gone, and apply again
(pass the same `-var` values you deployed with):

```bash
terraform destroy -target='module.challenge["c3"]'
kubectl wait --for=delete namespace/c3-processing --timeout=5m
terraform apply
```

(A4's federated credential subject is Azure-side: a plain `terraform apply` restores the seeded subject.)

## Clean up

```bash
./begin-challenge/azure-cli-bash/cleanup.sh                 # deletes the resource group, purges Key Vault/Foundry, removes the context
./begin-challenge/azure-cli-powershell/cleanup.ps1
cd begin-challenge/terraform && terraform destroy
```

The Azure CLI deployments also create (or reuse) `DefaultResourceGroup-<region>` with a Log Analytics workspace
for Container Insights (`az aks create` monitoring defaults). It is shared by every CLI-created cluster in the
subscription and is not deleted by the cleanup scripts – remove it yourself when nothing else uses it.
