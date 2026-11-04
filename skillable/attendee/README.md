<!-- TEMPLATE: C:\lab-resources\README.md on the Skillable lab VM. skillable/build-attendee-content.ps1 fills in the
     generated parts, and removes this comment. Attendees read it: no solutions, and nothing only proctors may know. -->
# KubeCon AKS capture-the-flag lab

Everything you need for the challenges is in this folder. Your lab instructions have the same challenge text.

| What | Where |
| --- | --- |
| Challenge instructions: the briefing, success criteria, and hints | `begin-challenge\challenges\<challenge>\README.md` |
| Check your work | `check.ps1` |
| Start a challenge over | `reset.ps1` |
| The scripts that `check.ps1` and `reset.ps1` run, and each challenge's manifests | `scoring\`, `begin-challenge\`, `shared\` |
| Your lab's settings: resource group, region, and cluster | `lab-settings.json` |
| How your lab was set up, for proctors | `setup-logs\` |

## The challenges

<!-- @challenge-table -->

## Get started

In the VS Code terminal (PowerShell 7), sign in to the Azure CLI with your lab account. `kubectl`, the scripts in
this folder, and the AKS-MCP server in GitHub Copilot use this sign-in.

```powershell
az login
kubectl get namespaces -l kubecon.lab/challenge
```

## Check your work

```powershell
C:\lab-resources\check.ps1 c1            # one challenge
C:\lab-resources\check.ps1 c1 -Quick     # a quicker, less strict look while you work
C:\lab-resources\check.ps1               # every challenge in your cluster
```

The check shows **PASS** or **FAIL** for each success criterion, and **PASSED** or **NOT PASSED** for the
challenge. **PASSED** is a captured flag. If your event has a leaderboard, each check records your result there,
with your first name and last initial; add `-NoReport` to keep a run off it.

## Start a challenge over

```powershell
C:\lab-resources\reset.ps1 c1
```

The reset asks you to confirm, deletes the challenge's namespace, and deploys the challenge again with its fault,
in 2 to 5 minutes. Your changes to that challenge are lost, and other challenges aren't touched. Some resets also
reset Azure resources: C2 deletes your gateway and its public IP address, C3 deletes its node pool and nodes, A4
resets its federated identity credential, and A6 re-creates its disk and data.

## Tips for AKS Automatic

<!-- @aks-automatic-tips -->
* The challenges' commands are written for bash, and most `kubectl` commands work unchanged in PowerShell. For
  the bash ones, such as `VAR=$(...)` or `grep`, open a **Git Bash** terminal: select the dropdown next to **+**
  in VS Code's terminal panel.
