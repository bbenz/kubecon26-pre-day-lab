# Testing

## 1. Static checks (no cluster, no Azure)

Run from the repository root; each tool is optional – install what you have.

```bash
# bash scripts
shellcheck -x -P SCRIPTDIR $(git ls-files '*.sh')
for f in $(git ls-files '*.sh'); do bash -n "$f"; done

# Kubernetes manifests (placeholders are expected to fail the hostname pattern in C2's Ingress, Gateway and HTTPRoute)
kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.35.0 \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  $(git ls-files '*/manifests/*.yaml')

# Terraform
terraform fmt -recursive -check
(cd begin-challenge/terraform && terraform init -backend=false && terraform validate)
(cd challenge-end-state/terraform && terraform init -backend=false && terraform validate)
```

```powershell
# PowerShell syntax
Get-ChildItem -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
  $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
  if ($e) { "$($_.Name): $($e[0].Message)" } }
```

A read-only `terraform plan -var subscription_id=<id>` additionally validates the AKS request body against the
azapi schema and the challenge documents (≈ 118 resources for all ten challenges).

## 2. Local behaviour tests on kind (no Azure)

The Kubernetes-only challenges – **C1, A1, A2, A3, A5, A6** – run on a local [kind](https://kind.sigs.k8s.io/)
cluster (kind's default CNI enforces NetworkPolicy). The harnesses use the *same* code as the Azure deployments.

```bash
kind create cluster --name ctf

# bash library
tests/kind/apply-local.sh begin          && scoring/verify.sh --context kind-ctf --quick   # expect NOT PASSED
tests/kind/apply-local.sh end            && scoring/verify.sh --context kind-ctf --quick   # expect PASSED
```

```powershell
./tests/kind/apply-local.ps1 -State begin ; ./scoring/verify.ps1 -Context kind-ctf -Quick
./tests/kind/apply-local.ps1 -State end   ; ./scoring/verify.ps1 -Context kind-ctf -Quick
```

```bash
# Terraform challenge module (switching state in place = exactly the fault objects change)
cd tests/terraform-kind && terraform init
terraform apply -var state=begin && terraform apply -var state=end && terraform destroy
```

Allow ~60 s after applying for images to pull before verifying.

Results recorded on 2026-10-13 (kind v0.33, Kubernetes 1.37): begin state → all six NOT PASSED with the intended
symptoms; end state → all six PASSED with each approach; the commands in every `SOLUTION.md` converge to PASS.

**Not covered locally** (need Azure): C2 (application routing add-on: managed NGINX and Gateway API, Azure DNS
labels), C3 (node auto-provisioning), C4 (Foundry), A4 (Entra workload identity), and AKS-specific behaviour of A1
(LocalDNS + Cilium), A2 (VM CPU speed, Managed Prometheus dashboards) and A6 (Azure Disk attach). On kind, A2's
`loadgen` sends the same background traffic; only the dashboards are missing.

## 3. Azure pilot

1. Deploy the begin state with one approach and run `scoring/verify.*` → every challenge NOT PASSED.
2. Solve each challenge with its `SOLUTION.md` (timing it) → PASSED.
3. Deploy the end state with another approach → every challenge PASSED.
4. Work through the pilot gates in [FEASIBILITY.md](../FEASIBILITY.md#pilot-gates--results-of-the-first-azure-deployment-2026-10-14-westus3-aks-automatic-1358).
5. Clean up with the matching `cleanup` script or `terraform destroy`.

First pilot (2026-10-14, westus3, AKS Automatic 1.35.8): begin state deployed with PowerShell and re-run with bash
(idempotent, resets C1/C2/C4), end state with Terraform. Final results: begin – all ten NOT PASSED with the intended
symptoms; end – all ten PASSED (bash and PowerShell verifiers). Findings and fixes are listed in FEASIBILITY.md.

Second round (2026-11-03, westus3, AKS Automatic 1.36.4) – C2 redesign and A2 dashboards:

* **Begin environment (CLI-created in October):** bash deploy `-c c2,a2` enabled the add-on's NGINX on the
  existing cluster and reset both challenges; the C2 migration was walked through as a participant
  (ingress2gateway 1.2.0 live and offline, AI-style adaptation, side-by-side tests, DNS cutover, decommissioning) and
  A2 was fixed by hand – both PASSED with the bash and PowerShell verifiers. PowerShell begin deploy → NOT PASSED;
  PowerShell end-state deploy in place (prune) → PASSED; bash begin deploy again to leave the environment in its
  begin state.
* **End environment (Terraform):** `terraform apply` added the Managed Prometheus resources and updated the cluster
  in place (2.5 min; Automatic add-ons, OIDC and workload identity unchanged); a second plan showed no changes.
  All ten challenges PASSED (C1 after restarting an `order-service` whose RabbitMQ had moved – see FEASIBILITY.md).
* **Fresh create** (temporary resource group, PowerShell): the new `az aks create` flags work; all monitoring
  resources landed in the lab resource group; removed with the bash cleanup script.
* Managed Prometheus data (throttling ratio, CPU usage and the recording rules the dashboards use) was checked with
  PromQL against each workspace. **Still to do by a reviewer:** open *Dashboards with Grafana* in the portal and
  confirm the dashboard names and panels the A2 README refers to.

Event leaderboard (2026-11-03, [leaderboard/README.md](../leaderboard/README.md)):

* **Static:** shellcheck, `bash -n`, PowerShell parser, `node --check` of the page's script; the page rendered in
  headless Edge with hostile input (an HTML-injection name shown as plain text, an over-long Unicode name truncated,
  path-trick / unknown-challenge / invalid-time records ignored).
* **Azure:** `setup.sh` + `cleanup.sh -y` on a throwaway leaderboard (created, token tested, resource group and local
  files deleted); `cleanup.ps1` refused an untagged resource group; `setup.ps1` created the pilot leaderboard
  (`bbenz-ctf-leaderboard`, container `pilot`) and `setup.sh` re-ran idempotently. Kill switch: a revoked token got
  403 `AuthenticationFailed`, the reissued token worked, the old one stayed revoked.
* **Reporting:** `verify.sh` (environment variables) recorded ten flags from the end environment; `verify.ps1`
  (`join.ps1` registration) recorded progress from the begin environment; the Skillable life cycle actions were
  simulated with replaced tokens – Windows under Windows PowerShell 5.1 (machine-wide file, "Ada Ö." intact) and Linux
  through bash (home-directory fallback) – and both verify scripts reported with them. `--quick` and `--no-report` runs
  were not recorded; a tampered token printed "not recorded (HTTP 403 AuthenticationFailed)" with the exit code
  unchanged. `tests/leaderboard/simulate-players.ps1` posted 12 demo players (65 records, no failures);
  `board.ps1` and `board.sh` produced identical data (79 records, 16 players) and the board ranked them correctly;
  demo records were then removed with `az storage blob delete-batch --auth-mode login`.
