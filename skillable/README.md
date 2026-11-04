# The hosted lab (Skillable)

The scripts that build the hosted version of this lab on [Skillable](https://www.skillable.com/), and its lab
instructions. You don't need them to try the challenges in your own subscription: see the [main README](../README.md).

| File | What it does |
| --- | --- |
| [`vm-image/kubecon-ctf-vm-image-setup.ps1`](vm-image/kubecon-ctf-vm-image-setup.ps1) | Builds the lab VM image: the Azure CLI with the aks-agent extension, `kubectl`, `kubelogin`, Helm, Inspektor Gadget, `ingress2gateway`, AKS-MCP, Terraform, the GitHub CLI, AKS desktop, VS Code with GitHub Copilot, PowerShell 7, Git, WSL with Ubuntu, and this repository in `C:\LabFiles\kubecon26-pre-day-lab` (a shallow clone, one commit) |
| [`vm-image/kubecon-ctf-vm-image-setup-bootstrap.txt`](vm-image/kubecon-ctf-vm-image-setup-bootstrap.txt) | The same script, compressed, to paste into the VM: it checks the script's SHA-256 hash and runs it |
| [`lca/prepare-lab-environment.ps1`](lca/prepare-lab-environment.ps1) | The prepare life cycle action: moves the repository on the VM to the event's tag, and runs the worker |
| [`lca/Invoke-CtfLabSetup.ps1`](lca/Invoke-CtfLabSetup.ps1) | The worker: deploys every challenge with [`begin-challenge/azure-cli-powershell/deploy.ps1`](../begin-challenge/azure-cli-powershell/deploy.ps1), gives the attendee's account its roles, sets up `kubectl` and the Azure CLI, and runs the readiness checks |
| [`lca/readiness-gate.ps1`](lca/readiness-gate.ps1) | The readiness gate life cycle action: checks the environment again, and removes the deployment's credentials from the VM before an attendee gets it |
| [`lca/manual-test-access.ps1`](lca/manual-test-access.ps1), [`lca/manual-begin-state-bootstrap.txt`](lca/manual-begin-state-bootstrap.txt) | For testing a lab profile: build the environment by hand, as the lab's own user |
| [`make-bootstraps.ps1`](make-bootstraps.ps1) | Regenerates both bootstraps after a change to the scripts |
| [`skillable lab steps.md`](skillable%20lab%20steps.md) | The lab instructions, generated from [`lab-steps-template.md`](lab-steps-template.md) and the challenges' README files by [`build-lab-steps.ps1`](build-lab-steps.ps1) |

After you change a challenge's README, or the template, run `./skillable/build-lab-steps.ps1` to update the lab
instructions. `./skillable/build-lab-steps.ps1 -Check` checks that they're up to date.