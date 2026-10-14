# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - applying challenge manifests and cleanup
# (PowerShell). Dot-sourced by CtfLab.psm1.
# -----------------------------------------------------------------------------

$script:TokenPattern = '__(AZURE_OPENAI_ENDPOINT|AZURE_OPENAI_DEPLOYMENT|AZURE_OPENAI_MODEL_NAME|AI_SERVICE_CLIENT_ID|KEY_VAULT_URI|CONFIG_READER_CLIENT_ID|STOREFRONT_DNS_LABEL|STOREFRONT_HOSTNAME)__'

# Writes the challenge manifests with placeholders replaced; returns the output folder.
function Get-CtfRenderedChallenge([string]$Id) {
    $c = $script:Ctf
    $v = $c.Values
    if ($Id -eq 'c4' -and (-not $v['AZURE_OPENAI_ENDPOINT'] -or -not $v['AI_SERVICE_CLIENT_ID'])) { throw 'C4 Azure values are missing' }
    if ($Id -eq 'a4' -and (-not $v['KEY_VAULT_URI'] -or -not $v['CONFIG_READER_CLIENT_ID'])) { throw 'A4 Azure values are missing' }
    $tokens = [ordered]@{
        '__AZURE_OPENAI_ENDPOINT__'   = [string]$v['AZURE_OPENAI_ENDPOINT']
        '__AZURE_OPENAI_DEPLOYMENT__' = $c.DeploymentName
        '__AZURE_OPENAI_MODEL_NAME__' = $c.ModelName
        '__AI_SERVICE_CLIENT_ID__'    = [string]$v['AI_SERVICE_CLIENT_ID']
        '__KEY_VAULT_URI__'           = [string]$v['KEY_VAULT_URI']
        '__CONFIG_READER_CLIENT_ID__' = [string]$v['CONFIG_READER_CLIENT_ID']
        '__STOREFRONT_DNS_LABEL__'    = $c.StorefrontDnsLabel
        '__STOREFRONT_HOSTNAME__'     = $c.StorefrontHostname
    }
    $src = Join-Path (Get-CtfChallengeDir $Id) 'manifests'
    $out = Join-Path $c.RenderDir $Id
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    foreach ($file in Get-ChildItem -Path $src -Filter '*.yaml' | Sort-Object Name) {
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($t in $tokens.GetEnumerator()) { $text = $text.Replace($t.Key, $t.Value) }
        if ($text -match $script:TokenPattern) { throw "Unresolved placeholder $($Matches[0]) in $($file.Name)" }
        [IO.File]::WriteAllText((Join-Path $out $file.Name), $text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    }
    return $out
}

function Reset-CtfChallenge([string]$Id) {
    Write-CtfInfo "Reset: deleting existing objects for $Id (namespace $($script:Namespaces[$Id]))"
    if ($Id -eq 'c3') {
        # Deleting the NodePool also removes any nodes it provisioned in an earlier run.
        Invoke-Kubectl delete nodepools.karpenter.sh -l kubecon.lab/challenge=c3 --ignore-not-found --wait=true --timeout=10m 2>$null | Out-Null
    }
    Invoke-Kubectl delete namespace -l "kubecon.lab/challenge=$Id" --ignore-not-found --wait=true --timeout=10m | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Timed out deleting the $Id namespace" }
}

function Wait-CtfSetupJobs([string]$Namespace) {
    $jobs = @(Invoke-Kubectl get jobs -n $Namespace -l kubecon.lab/phase=setup -o name 2>$null | Where-Object { $_ })
    foreach ($job in $jobs) {
        Write-CtfInfo "Waiting for $job (setup phase; includes disk provisioning) ..."
        for ($i = 0; ; $i++) {
            $status = (Invoke-Kubectl get $job -n $Namespace -o 'jsonpath={.status.succeeded}|{.status.conditions[?(@.type=="Failed")].status}' | Out-String).Trim()
            if ($status -like '1|*') { Write-CtfOk "$job completed"; break }
            if ($status -like '*|True') { throw "$job failed - see: kubectl --context $($script:Ctf.KubeContext) logs -n $Namespace $job" }
            if ($i -ge 80) { throw "$job did not complete within 20 minutes" }
            Start-Sleep -Seconds 15
        }
    }
}

function Install-CtfChallenge([string]$Id) {
    $c = $script:Ctf
    $ns = $script:Namespaces[$Id]
    Write-CtfStep "Challenge $Id -> namespace $ns ($($c.State) state)"
    $rendered = Get-CtfRenderedChallenge $Id
    if ($c.Reset) { Reset-CtfChallenge $Id }
    Invoke-Kubectl apply -f (Join-Path $rendered '00-namespace.yaml') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create namespace $ns" }
    # Phase 1: objects labelled kubecon.lab/phase=setup (for example seeding data
    # onto a disk) must finish before the rest of the challenge is applied.
    if (Select-String -Path (Join-Path $rendered '*.yaml') -Pattern 'kubecon.lab/phase: setup' -Quiet) {
        Invoke-Kubectl apply -f $rendered -l kubecon.lab/phase=setup
        if ($LASTEXITCODE -ne 0) { throw "kubectl apply (setup phase) failed for $Id" }
        Wait-CtfSetupJobs $ns
    }
    # Phase 2: everything.
    Invoke-Kubectl apply -f $rendered
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed for $Id" }
    $relative = [IO.Path]::GetRelativePath($c.RepoRoot, (Get-CtfChallengeDir $Id))
    Write-CtfOk "applied $relative/manifests"
}

function Write-CtfSummary {
    $c = $script:Ctf
    Write-CtfStep "Done - $($c.StateTitle) deployed"
    Write-CtfInfo "kubectl context : $($c.KubeContext)   (kubectl config use-context $($c.KubeContext))"
    Write-CtfInfo "Resource group  : $($c.ResourceGroup) ($($c.Location))"
    Write-Host ''
    Write-Host ('    {0,-4} {1,-16} {2}' -f 'ID', 'NAMESPACE', 'INSTRUCTIONS')
    foreach ($id in $c.Challenges) {
        $relative = [IO.Path]::GetRelativePath($c.RepoRoot, (Get-CtfChallengeDir $id)) -replace '\\', '/'
        Write-Host ('    {0,-4} {1,-16} {2}' -f $id, $script:Namespaces[$id], "$relative/README.md")
    }
    if (Test-CtfSelected 'c2') {
        Write-CtfInfo ''
        Write-CtfInfo "C2 storefront: waiting up to 5 minutes for the gateway's public IP ..."
        Invoke-Kubectl wait --for=condition=Programmed gateway/store-gateway -n c2-storefront --timeout=300s 2>$null | Out-Null
        $ip = (Invoke-Kubectl get gateway store-gateway -n c2-storefront -o 'jsonpath={.status.addresses[0].value}' 2>$null | Out-String).Trim()
        Write-CtfInfo "C2 storefront URL: http://$($c.StorefrontHostname)/  (gateway IP: $(if ($ip) { $ip } else { 'pending' }))"
    }
    if (Test-CtfSelected 'c4') {
        Write-CtfInfo "C4 store admin  : kubectl --context $($c.KubeContext) port-forward -n c4-assistant svc/store-admin 8081:80  ->  http://localhost:8081"
    }
    Write-CtfInfo ''
    Write-CtfInfo 'Check a challenge against its success criteria:'
    Write-CtfInfo "  ./scoring/verify.ps1 -Context $($c.KubeContext) -Challenges $($c.Challenges -join ',')"
}

# Deletes a lab environment: resource group, soft-deleted Key Vault / Foundry account, kubectl context.
function Remove-CtfLab {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ClusterName,
        [switch]$NoWait
    )
    if (-not $ClusterName) { $ClusterName = 'aks-' + ($ResourceGroup -replace '^rg-', '') }
    if (-not (Test-AzCommand account show)) { throw 'Not signed in to Azure. Run: az login' }
    $subscriptionId = Invoke-AzTsv account show --query id
    $suffix = Get-CtfSha1Prefix "$subscriptionId/$ResourceGroup"
    $keyVault = "kv-ctf-$suffix"
    $aoai = "aoai-ctf-$suffix"

    Write-CtfStep "Cleaning up $ResourceGroup (subscription $subscriptionId)"
    if (Test-AzCommand group show -n $ResourceGroup) {
        if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Delete resource group and everything in it')) {
            if ($NoWait) {
                Invoke-AzCommand group delete -n $ResourceGroup --yes --no-wait | Out-Null
                Write-CtfOk 'deletion started (no purge of soft-deleted resources with -NoWait)'
            }
            else {
                Write-CtfInfo 'Deleting resource group (typically 5-15 minutes) ...'
                Invoke-AzCommand group delete -n $ResourceGroup --yes | Out-Null
                Write-CtfOk 'resource group deleted'
            }
        }
        else { return }
    }
    else { Write-CtfInfo "Resource group $ResourceGroup does not exist" }

    if (-not $NoWait) {
        if (Invoke-AzTsv keyvault list-deleted --query "[?name=='$keyVault'].name | [0]") {
            Write-CtfInfo "Purging soft-deleted Key Vault $keyVault ..."
            if (Test-AzCommand keyvault purge -n $keyVault) { Write-CtfOk 'Key Vault purged' }
        }
        $deletedId = Invoke-AzTsv cognitiveservices account list-deleted --query "[?name=='$aoai'].id | [0]"
        if ($deletedId -and $deletedId -match '/locations/([^/]+)/') {
            Write-CtfInfo "Purging soft-deleted Foundry account $aoai ..."
            if (Test-AzCommand cognitiveservices account purge -n $aoai -g $ResourceGroup -l $Matches[1]) { Write-CtfOk 'Foundry account purged' }
        }
    }
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        & kubectl config delete-context $ClusterName 2>$null | Out-Null
        & kubectl config delete-cluster $ClusterName 2>$null | Out-Null
        & kubectl config unset "users.clusterUser_$($ResourceGroup)_$ClusterName" 2>$null | Out-Null
        Write-CtfOk "removed kubectl context $ClusterName"
    }
    $render = Join-Path $RepoRoot ".lab/rendered/$ResourceGroup"
    if (Test-Path $render) { Remove-Item -Recurse -Force $render }
}
