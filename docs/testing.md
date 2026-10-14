# Testing

## 1. Static checks (no cluster, no Azure)

Run from the repository root; each tool is optional – install what you have.

```bash
# bash scripts
shellcheck -x -P SCRIPTDIR $(git ls-files '*.sh')
for f in $(git ls-files '*.sh'); do bash -n "$f"; done

# Kubernetes manifests (placeholders are expected to fail the hostname pattern in C2's HTTPRoute)
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

**Not covered locally** (need Azure): C2 (AKS Gateway API implementation), C3 (node auto-provisioning), C4 (Foundry),
A4 (Entra workload identity), and AKS-specific behaviour of A1 (LocalDNS + Cilium), A2 (VM CPU speed) and A6 (Azure
Disk attach).

## 3. Azure pilot

1. Deploy the begin state with one approach and run `scoring/verify.*` → every challenge NOT PASSED.
2. Solve each challenge with its `SOLUTION.md` (timing it) → PASSED.
3. Deploy the end state with another approach → every challenge PASSED.
4. Work through the pilot gates in [FEASIBILITY.md](../FEASIBILITY.md#pilot-gates--confirm-on-the-first-azure-deployment).
5. Clean up with the matching `cleanup` script or `terraform destroy`.
