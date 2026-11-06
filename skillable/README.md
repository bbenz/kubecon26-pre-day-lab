# The hosted lab (Skillable)

The scripts that build the hosted version of this lab on [Skillable](https://www.skillable.com/), and its lab
instructions. You don't need them to try the challenges in your own subscription: see the [main README](../README.md).

| File | What it does |
| --- | --- |
| [`vm-image/kubecon-ctf-vm-image-setup.ps1`](vm-image/kubecon-ctf-vm-image-setup.ps1) | Builds the lab VM image: the Azure CLI with the aks-agent extension, `kubectl`, `kubelogin`, Helm, Inspektor Gadget, `ingress2gateway`, AKS-MCP, Terraform, the GitHub CLI, AKS desktop, VS Code with GitHub Copilot, PowerShell 7, Git, WSL with Ubuntu, and this repository in `C:\LabFiles\kubecon26-pre-day-lab` (a shallow clone, one commit) |
| [`vm-image/kubecon-ctf-vm-image-setup-bootstrap.txt`](vm-image/kubecon-ctf-vm-image-setup-bootstrap.txt) | The same script, compressed, to paste into the VM: it checks the script's SHA-256 hash and runs it |
| [`lca/prepare-lab-environment.ps1`](lca/prepare-lab-environment.ps1) | The life cycle action, the lab's only one: moves the repository on the VM to the event's tag, runs the worker, and then starts the cleanup |
| [`lca/Invoke-CtfLabSetup.ps1`](lca/Invoke-CtfLabSetup.ps1) | The worker: deploys every challenge with [`begin-challenge/azure-cli-powershell/deploy.ps1`](../begin-challenge/azure-cli-powershell/deploy.ps1), gives the attendee's account its roles, sets up `kubectl` and the Azure CLI, runs the readiness checks, and removes the deployment's credentials from the VM. Its log, with the results, is in `.lab\skillable\begin-state-<time>.log` in the repository on the VM |
| [`lca/Invoke-CtfLabCleanup.ps1`](lca/Invoke-CtfLabCleanup.ps1) | After the life cycle action ends: clears the PowerShell event logs, and checks that the deployment's credentials are gone before an attendee gets the VM |
| [`lca/manual-test-access.ps1`](lca/manual-test-access.ps1), [`lca/manual-begin-state-bootstrap.txt`](lca/manual-begin-state-bootstrap.txt) | For testing a lab profile: build the environment by hand, as the lab's own user |
| [`make-bootstraps.ps1`](make-bootstraps.ps1) | Regenerates both bootstraps after a change to the scripts |
| [`skillable lab steps.md`](skillable%20lab%20steps.md) | The lab instructions, generated from [`lab-steps-template.md`](lab-steps-template.md) and the challenges' README files by [`build-lab-steps.ps1`](build-lab-steps.ps1) |

After you change a challenge's README, or the template, run `./skillable/build-lab-steps.ps1` to update the lab
instructions. `./skillable/build-lab-steps.ps1 -Check` checks that they're up to date.