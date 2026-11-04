# KubeCon CTF lab: VM image build runbook

How to build and commit the lab VM image in the Skillable lab profile. Modeled on the LAB723 (Ignite 2026)
image build. The [LCA runbook](../lca/LCA-RUNBOOK.md) covers what happens at each launch.

## Files

| File | Purpose |
| --- | --- |
| [`kubecon-ctf-vm-image-setup.ps1`](kubecon-ctf-vm-image-setup.ps1) | The setup script that runs in the VM. Review it here. |
| [`kubecon-ctf-vm-image-setup-bootstrap.txt`](kubecon-ctf-vm-image-setup-bootstrap.txt) | The same script, compressed for pasting. Pasted into an elevated PowerShell window in the VM, it recreates the script as `C:\LabSetup\kubecon-ctf-vm-image-setup.ps1`, checks its SHA-256 hash, and runs it. If a character is mistyped, the check fails and nothing runs. |
| [`../make-bootstraps.ps1`](../make-bootstraps.ps1) | Regenerates the bootstrap after any change to the setup script. |

Current setup script SHA-256: `FF33558E7C1E17229648F00122708B765C9F0BA59720E39F80C95EB50146CB7D`

## What the image gets

The lab design's VM prerequisites, plus what the lab repository's scripts need:

| # | Item | Installed and configured |
| ---: | --- | --- |
| 1 | Windows settings | Notifications, tips, "finish setup" prompts, OneDrive, Teams (free), Chat, widgets, and Windows Copilot suppressed. No automatic Windows Update or Microsoft Store downloads, and no forced restarts. Never sleeps, hibernates, or locks. English (US) keyboard. |
| 2 | Git | Git for Windows, the latest release if Git is missing, signature-verified. Git Bash runs the lab's bash scripts (`deploy.sh`, `verify.sh`) on Windows. |
| 3 | PowerShell 7 | The latest release (7.6.9 today), checked against its published SHA-256. The lab's PowerShell scripts need 7.4 or later; the LCA worker runs in it. Update checks and telemetry off. |
| 4 | Azure CLI and extensions | The current Azure CLI (2.92.0 today; the lab needs 2.86 or later), signature-verified, with the **aks-agent** extension (`az aks agent`, the agentic CLI for AKS) and **k8s-extension** (manages the Inspektor Gadget cluster extension). Browser sign-in (`core.enable_broker_on_windows=false`), so `az login` reuses the Azure portal session in Edge. Login experience v2, telemetry, survey prompts, and automatic upgrade off. |
| 5 | Kubernetes tools | In `C:\Program Files\Kubernetes`, on the system PATH, each checked against its published checksum: the latest **kubectl** 1.36 patch, **kubelogin**, **Helm**, **Inspektor Gadget**'s `kubectl gadget` plugin, **ingress2gateway** 1.2.0 (challenge C2), and the **AKS-MCP** server 0.0.22 (pinned by its SHA-256, because it publishes no checksums file). |
| 6 | Terraform | The latest release, checksum-verified, with update checks off (`CHECKPOINT_DISABLE=1`), for the repository's Terraform approach. No lab step depends on it. |
| 7 | GitHub CLI | The latest release, checksum-verified, with update notices off. |
| 8 | AKS desktop | The latest release (0.10.0 today), signature-verified (Microsoft), installed for all users in `C:\Program Files\AKS desktop`. |
| 9 | Visual Studio Code | System-wide, with **GitHub Copilot Chat** (and GitHub Copilot, where the gallery still has it), **Kubernetes**, **Azure Kubernetes Service**, **YAML**, **PowerShell**, **WSL**, and **HashiCorp Terraform** extensions. **AKS-MCP** is a user MCP server in `%APPDATA%\Code\User\mcp.json` (`--access-level readwrite`), so Copilot's agent mode can use it in any folder. No welcome page, update, telemetry, recommendation, or workspace trust prompts; PowerShell 7 terminal; larger fonts; auto save. |
| 10 | Microsoft Edge | Policies: no first-run, sync, default-browser, password, or shopping prompts; starts on the Azure portal; a **KubeCon CTF** favorites folder with the Azure portal, AKS documentation, and the Gateway API site. |
| 11 | WSL | The Virtual Machine Platform and Windows Subsystem for Linux features, the current WSL release (checked against GitHub's published digest), and Ubuntu 24.04 from the official WSL distribution list (checked against its SHA-256). The default Linux user, named after the Windows user, has passwordless sudo and no first-run prompts. Inside Ubuntu: the Azure CLI (Microsoft's package repository), kubectl, kubelogin, and Helm (checksum-verified), and jq, so the bash scripts run in WSL too. WSL 2 when the VM exposes virtualization, WSL 1 otherwise. Needs one restart (step 7). |
| 12 | Lab folder and startup | `C:\lab-resources`, with a placeholder `README.md`: at each launch, the prepare LCA fills it with the challenges' instructions and the scripts that check and reset them, without the solutions. The image has no copy of the lab repository, because the repository has the solutions: the script removes a clone that an earlier version of it made in `C:\LabFiles\kubecon26-pre-day-lab`, and its verification fails if a clone, `SOLUTION.md`, or the end state is in `C:\lab-resources` or `C:\LabFiles`. VS Code's startup shortcut and Start menu shortcut open the folder, and Edge opens the Azure portal at sign-in. |

The script also writes `C:\ProgramData\kubecon-ctf-image\image-manifest.json` (installed versions) and setup
logs to the same folder.

## What the image doesn't get

- **Per-launch state:** the cluster, the challenges, the kubeconfig, the attendee's roles, and Azure sign-ins.
  The prepare LCA sets them up at each launch. The image's Azure CLI stays signed out.
- **The lab repository:** it has the solutions. The prepare LCA clones it at launch, builds `C:\lab-resources`
  from it, and deletes it. Don't clone the repository in the image VM, or test the LCAs there without
  `-Finalize` afterward.
- **GitHub sign-ins:** attendees sign in to GitHub Copilot in VS Code with their own account (a Copilot seat).
  Don't sign in to GitHub in VS Code, the GitHub CLI, or Git while you build the image. `-Finalize` removes
  GitHub CLI and Git credentials, but VS Code keeps its own sign-ins in its encrypted storage: if you signed in,
  sign out from VS Code's **Accounts** menu before you finalize.
- **A model for `az aks agent`:** the extension is installed, but the agent needs a model endpoint and key
  (see the LCA runbook's [GitHub Copilot, AKS-MCP, and az aks agent](../lca/LCA-RUNBOOK.md#github-copilot-aks-mcp-and-az-aks-agent)).
- **Automatic sign-in and the Skillable integration service:** you set these in steps 8 and 9.

## Steps

1. Launch a lab from the profile. Use a Windows 11 VM with 4 vCPUs and 16 GiB (D4s_v5 class), the lab design's
   VM. Skillable recommends starting from a VM with no differencing disks, keeping the disk chain to three disks
   or fewer, and committing soon after setup.
   - For WSL 2, the VM must expose virtualization (nested virtualization) in the profile's VM settings. Without
     it, the script installs WSL 1, which runs the same Ubuntu commands.
2. If Windows shows a sign-in screen, select **Commands** > **Type Text** > **Type Password**.
3. In the VM, select **Start**, type `powershell`, select **Run as administrator**, and approve the prompt.
4. On your computer, open `kubecon-ctf-vm-image-setup-bootstrap.txt`, select all of its text, and copy it.
5. Right-click inside the PowerShell window in the VM to paste the text. If right-click doesn't paste, select
   inside the window, and then select **Commands** > **Type Text** > **Type Clipboard Text** in the lab client.
   Don't click or type in the VM until typing finishes.
   - If the dialog doesn't accept the whole file, paste it one part at a time, in order, in the same window. Each
     part starts with a `part N of 9` comment line.
6. The script starts after the last line. It prints `READY:` as each of the 12 items finishes, and then a
   verification table. The first run takes about 15 minutes (12 on a D4s_v5 in testing).
7. The first run ends with **RESTART REQUIRED to finish: WSL**, because Windows must restart to turn on its WSL
   features. Restart the VM (**Start** > **Power** > **Restart**). When Windows is back, open an elevated
   PowerShell window again, and run:

    ```powershell
    powershell -ExecutionPolicy Bypass -File C:\LabSetup\kubecon-ctf-vm-image-setup.ps1
    ```

    Finished items are skipped or reapplied, WSL installs Ubuntu and the Linux tools (about 5 to 10
    minutes), and the run ends with the verification table and **ALL ITEMS READY**. If **WSL 2** shows **WARN**,
    the VM has no nested virtualization, and Ubuntu runs on WSL 1, which is fine for this lab.
8. If **Automatic sign-in** shows **WARN**, run `netplwiz`, select the lab user, clear **Users must enter a user
   name and password to use this computer**, select **Apply**, and enter the lab user's password twice with
   **Type Password**. The script turns off the Windows Hello-only setting that hides that checkbox.
9. If **Skillable integration service** shows **WARN**, select **Settings** > **Install Integration Tools** in the
   lab client, and then restart the VM. Life cycle actions that run in the VM need the service. To confirm that
   it's running, open `http://localhost:2724` in Edge in the VM.
10. Optional: restart the VM to check the startup experience. Windows signs in automatically, VS Code opens on
    `C:\lab-resources` (only its placeholder `README.md` until a launch), Edge opens the Azure portal with the
    **KubeCon CTF** favorites folder, and no pop-ups appear. Don't sign in to GitHub in VS Code.
11. In a new elevated PowerShell window, run the following command. It verifies the image again; removes
    credentials, caches, history (including Linux shell history), deployment state, the state of any LCA test
    run (`C:\ProgramData\kubecon-ctf-lca`, and `C:\lab-resources` back to its placeholder), and setup files,
    including `C:\LabSetup`; shuts down WSL; and shuts down the VM. Automatic sign-in and the integration service
    must pass now, so their rows show **FAIL** instead of **WARN** if they're missing, and nothing is removed.
    After the cleanup, it confirms that no Azure CLI sign-in, kubeconfig, GitHub CLI or Git credential, LCA state,
    lab repository or solution, setup file, or Linux shell history is left.

    ```powershell
    powershell -ExecutionPolicy Bypass -File C:\LabSetup\kubecon-ctf-vm-image-setup.ps1 -Finalize
    ```

12. In the lab client, select **Settings** > **Commit changes** > **Commit my changes to this lab profile**. Enter
    a note such as `KubeCon CTF image: tools, AKS desktop, VS Code + AKS-MCP, WSL (setup script <first 8 of the hash>)`,
    select the VM's disk, and confirm. Wait for the confirmation; Skillable restarts the VM afterward.
13. End the lab, launch the profile again, and verify:
    - Windows signs in automatically, VS Code and Edge open as in step 10, and no pop-ups appear.
    - In the VS Code terminal: `git --version`, `pwsh --version`, `az version` (lists `aks-agent` and
      `k8s-extension`), `az aks agent --help`, `kubectl version --client`, `kubelogin --version`, `helm version`,
      `kubectl gadget --help`, `ingress2gateway version`, `aks-mcp --version`, `gh --version`, `terraform version`,
      and `wsl -l -v` all work, and `wsl az version` and `wsl kubectl version --client` work without a prompt.
    - VS Code: **MCP: List Servers** shows **aks-mcp**. AKS desktop starts from the Start menu.
    - `C:\ProgramData\kubecon-ctf-image\image-manifest.json` lists the installed versions.

## Update the committed image

Launch the profile (it starts from the committed image), and follow steps 2 to 7 with the new bootstrap: the
script skips or reapplies finished items, upgrades tools that have newer releases, and installs new items. Skip
steps 8 and 9 unless their rows show **WARN**. Finish with steps 11 to 13. Each commit adds a differencing disk;
keep the chain to three disks or fewer.

The image has no copy of the lab repository, so a change to a challenge or a script doesn't need a new image: the
prepare LCA clones the event's tag at launch.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| **Decode failed** or **Hash mismatch** | A character was mistyped. Make sure the VM keyboard is English (US) (Windows+Space), open a new elevated PowerShell window, and paste the bootstrap again. |
| "Run this script in an elevated Windows PowerShell window" | Open PowerShell with **Run as administrator**. |
| "Windows is signed in as *user*, but this script runs as *other user*" | Sign in to Windows as the lab user, and run PowerShell elevated as that user, so that per-user settings (VS Code, the Azure CLI extensions, WSL) land in the lab user's profile. |
| **FAILED:** *item* | Read the message, fix the cause (usually a blocked or slow download), and run `powershell -ExecutionPolicy Bypass -File C:\LabSetup\kubecon-ctf-vm-image-setup.ps1` again. |
| **Checksum mismatch** or a signature that isn't valid | The download was corrupted or intercepted. Run the script again; if it keeps failing, check the VM's internet connection (**Commands** > **Reset Internet Gateway**). For aks-mcp, a mismatch after you change `$AksMcpTag` means `$AksMcpSha256` must change too: take it from the release's asset digest on GitHub. |
| **Azure CLI and extensions** fails at `az extension add --name aks-agent` | The extension downloads Python packages, which takes 5 to 10 minutes and needs `pypi.org`. Run the script again. |
| **Kubernetes tools** fails because another kubectl comes first on the PATH | Remove the other kubectl, or move `C:\Program Files\Kubernetes` earlier in the system PATH. |
| **AKS desktop** fails with a timeout | The installer ran longer than 15 minutes. Close any AKS desktop window, and run the script again. |
| **RESTART REQUIRED** appears again after a restart | Windows didn't finish turning on the WSL features. Restart once more, and run the script again. The script asks for a restart for WSL at most twice. |
| **WSL** fails with "Couldn't install ... with WSL 2 (...) or WSL 1" | Read the error codes. `WSL_E_WSL1_NOT_SUPPORTED` after two restarts means that Windows couldn't activate the feature: check `C:\Windows\Logs\CBS\CBS.log`. To start over, run `wsl --unregister Ubuntu-24.04`, and run the script again. |
| **WSL** fails at "Installing the Linux tools" | The message ends with the last lines of the Linux output. Usually `apt-get` or a download failed: run the script again. |
| `-Finalize` reports **FAILED: The cleanup left** *items* | Something kept a file open or signed back in. Remove what it lists, or restart the VM, and run `-Finalize` again. `-Force` doesn't skip this check. |
| VS Code or Edge doesn't open at sign-in | Windows starts the Startup folder's shortcuts (`KubeCon CTF - Visual Studio Code`, `KubeCon CTF - Microsoft Edge`) once the desktop is shown. On a test VM in Azure with no console viewer, Windows didn't start them; in Skillable, the lab client shows the console. Check step 10 after a restart. VS Code's Start menu shortcut opens the lab folder too. |
| **FAIL** No lab repository or solutions | Something copied the lab repository or a solution into `C:\lab-resources` or `C:\LabFiles`. Delete what the row lists, and run the script again. |
| The commit takes a long time or fails | Make sure the VM is shut down before you commit; `-Finalize` stops Windows Update so that it can't block the shutdown. |

## After you change the setup script

1. Run `../make-bootstraps.ps1` (Windows PowerShell 5.1 or PowerShell 7). It prints the new SHA-256 hash.
2. Update the hash in this runbook and in your commit note.
