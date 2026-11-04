# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - Azure resources (Azure CLI, PowerShell).
# Every function is idempotent: it creates what is missing and reuses what
# already exists, so deploy scripts can be re-run safely.
# -----------------------------------------------------------------------------

function New-CtfResourceGroup {
    $c = $script:Ctf
    Write-CtfStep "Resource group $($c.ResourceGroup)"
    if ($c.SkipInfra) {
        if (-not (Test-AzCommand group show -n $c.ResourceGroup)) { throw "Resource group $($c.ResourceGroup) not found (remove -SkipInfra)" }
        return
    }
    # An existing resource group stays as it is: its region and tags (a lab platform's own tags, for example).
    if (Test-AzCommand group show -n $c.ResourceGroup) { Write-CtfOk 'resource group exists'; return }
    Invoke-AzCommand group create -n $c.ResourceGroup -l $c.Location --tags purpose=kubecon-ctf "lab-state=$($c.State)" -o none | Out-Null
    Write-CtfOk 'resource group created'
}

function Install-CtfCluster {
    $c = $script:Ctf
    Write-CtfStep "AKS Automatic cluster $($c.ClusterName)"
    if (Test-AzCommand aks show -g $c.ResourceGroup -n $c.ClusterName) {
        Write-CtfOk 'cluster exists'
    }
    elseif ($c.SkipInfra) {
        throw "Cluster $($c.ClusterName) not found (remove -SkipInfra)"
    }
    else {
        $workspaces = Install-CtfMonitorWorkspaces
        Write-CtfInfo 'Creating the cluster - this typically takes 10-15 minutes ...'
        # --sku automatic           : AKS Automatic (NAP, Cilium, Azure RBAC, deployment safeguards,
        #                             Managed Prometheus, Container Insights, ...)
        # --enable-hosted-system    : managed system node pool (system components on AKS-managed nodes)
        # --enable-app-routing      : application routing add-on with managed NGINX (C2 starts on Ingress-NGINX)
        # --enable-gateway-api      : managed Gateway API CRDs (C2 migrates to Gateway API)
        # --enable-app-routing-istio: Istio-based Gateway API implementation of the application routing add-on
        # --azure-monitor-workspace-resource-id / --workspace-resource-id: keep Managed Prometheus
        #                             and Container Insights data in the lab resource group (A2 dashboards)
        #                             instead of default workspaces in DefaultResourceGroup-<region>
        # --no-ssh-key              : otherwise the CLI sends ~/.ssh/id_rsa.pub when it exists, which AKS rejects
        #                             for Automatic clusters with managed system node pools (BadRequest)
        Invoke-AzCoreCommand aks create -g $c.ResourceGroup -n $c.ClusterName -l $c.Location `
            --sku automatic --enable-hosted-system --no-ssh-key `
            --enable-app-routing --enable-gateway-api --enable-app-routing-istio `
            --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id $workspaces.AmwId `
            --workspace-resource-id $workspaces.LawId `
            --tags purpose=kubecon-ctf "lab-state=$($c.State)" -o none | Out-Null
        Write-CtfOk 'cluster created'
    }
    $c.AksId = Invoke-AzTsv aks show -g $c.ResourceGroup -n $c.ClusterName --query id
    $c.OidcIssuer = Invoke-AzTsv aks show -g $c.ResourceGroup -n $c.ClusterName --query oidcIssuerProfile.issuerUrl
}

# Azure Monitor workspace (Managed Prometheus metrics) and, unless -MetricsOnly, a
# Log Analytics workspace (Container Insights) in the lab resource group. Returns
# @{ AmwId; LawId }. Without explicit workspaces the Azure CLI uses default
# workspaces in DefaultResourceGroup-<region>, outside the lab resource group.
function Install-CtfMonitorWorkspaces([switch]$MetricsOnly) {
    $c = $script:Ctf
    if (-not (Test-AzCommand monitor account show -g $c.ResourceGroup -n $c.AmwName)) {
        Invoke-AzCommand monitor account create -g $c.ResourceGroup -n $c.AmwName -l $c.Location -o none | Out-Null
        Write-CtfOk "created Azure Monitor workspace $($c.AmwName) (Managed Prometheus)"
    }
    $result = @{ AmwId = (Invoke-AzTsv monitor account show -g $c.ResourceGroup -n $c.AmwName --query id); LawId = $null }
    if ($MetricsOnly) { return $result }
    if (-not (Test-AzCommand monitor log-analytics workspace show -g $c.ResourceGroup -n $c.LawName)) {
        Invoke-AzCommand monitor log-analytics workspace create -g $c.ResourceGroup -n $c.LawName -l $c.Location -o none | Out-Null
        Write-CtfOk "created Log Analytics workspace $($c.LawName) (Container Insights)"
    }
    $result.LawId = Invoke-AzTsv monitor log-analytics workspace show -g $c.ResourceGroup -n $c.LawName --query id
    return $result
}

# Object ID of the signed-in identity, from the oid claim of its own access token.
# Needs no Microsoft Graph permission, which a lab service principal (Skillable's
# cloud subscription identity, for example) often doesn't have.
function Get-CtfTokenObjectId {
    $token = Invoke-AzTsv account get-access-token --query accessToken
    $parts = "$token".Split('.')
    if ($parts.Count -lt 2) { return '' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    try { return [string]([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json).oid }
    catch { return '' }
}

function Get-CtfSignedInPrincipal {
    $type = if ((Invoke-AzTsv account show --query user.type) -eq 'user') { 'User' } else { 'ServicePrincipal' }
    $id = Get-CtfTokenObjectId
    if (-not $id) {
        $id = if ($type -eq 'User') { Invoke-AzTsv ad signed-in-user show --query id }
              else { Invoke-AzTsv ad sp show --id (Invoke-AzTsv account show --query user.name) --query id }
    }
    return @{ Id = $id; Type = $type }
}

function Set-CtfRoleAssignment([string]$PrincipalId, [string]$PrincipalType, [string]$Role, [string]$Scope) {
    # Listed by scope and role, not --assignee, which needs Microsoft Graph: a lab service principal, or an attendee
    # resetting a challenge, may not be allowed to read it. Inherited assignments count. The query has spaces, so
    # az.cmd gets it quoted: cmd.exe misreads the parentheses of an unquoted one.
    $count = Invoke-AzTsv role assignment list --scope $Scope --role $Role --include-inherited --fill-principal-name false `
        --query "length([?principalId == '$PrincipalId'])"
    if ($count -and $count -ne '0') { Write-CtfOk "'$Role' already assigned"; return }
    # New managed identities can take a few seconds to replicate, and requests can fail on the way: those are retried.
    # A policy denial doesn't go away, and a missing permission rarely does: those stop sooner, with Azure's reason.
    for ($attempt = 1; ; $attempt++) {
        $err = New-TemporaryFile
        try {
            & az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType `
                --role $Role --scope $Scope --only-show-errors -o none 2>$err.FullName | Out-Null
            $ok = $LASTEXITCODE -eq 0
            $text = ((Get-Content -Raw $err.FullName) -replace '\s+$', '')
        }
        finally { Remove-Item $err.FullName -ErrorAction SilentlyContinue }
        if ($ok -or $text -match 'RoleAssignmentExists') { Write-CtfOk "assigned '$Role'"; return }
        $code = if ($text -match '(?m)^(?:ERROR: \(|Code: )(\w+)') { $Matches[1] } else { 'error' }
        $limit = switch -Regex ($code) { '^RequestDisallowedByPolicy$' { 1 } '^(Linked)?AuthorizationFailed$' { 3 } default { 10 } }
        if ($attempt -ge $limit) { throw (Get-CtfRoleAssignmentFailure $Role $Scope $code $text) }
        Write-CtfWarn "Assigning '$Role' failed with $code (attempt $attempt of $limit) - retrying in 15 seconds ..."
        Start-Sleep -Seconds 15
    }
}

# Why a role assignment failed, from az's error output, and what to do about it.
function Get-CtfRoleAssignmentFailure([string]$Role, [string]$Scope, [string]$Code, [string]$ErrorText) {
    $roleId = Invoke-AzTsv role definition list --name $Role --query '[0].name'
    $failed = "Could not assign '$Role' (role definition ID $(if ($roleId) { $roleId } else { 'unknown' })) on $Scope ($Code)."
    switch -Regex ($Code) {
        '^RequestDisallowedByPolicy$' {
            $policy = if ($ErrorText -match '"policyAssignmentDisplayName":\s*"([^"]+)"') { " (policy assignment '$($Matches[1])')" }
                      elseif ($ErrorText -match '"policyAssignmentName":\s*"([^"]+)"') { " (policy assignment '$($Matches[1])')" } else { '' }
            return "$failed Azure Policy denied the role assignment$policy. The subscription's policies must allow role " +
                   "assignments (Microsoft.Authorization/roleAssignments) of this role: in a Skillable lab, the lab profile's " +
                   'access control policy (ACP).'
        }
        '^(Linked)?AuthorizationFailed$' {
            return "$failed The signed-in identity may not create role assignments there: it needs Owner, User Access " +
                   'Administrator, or Role Based Access Control Administrator on that scope, without a condition that ' +
                   'excludes this role.'
        }
        default {
            $line = @($ErrorText -split "`n" | Where-Object { $_ -match '^ERROR:' }) + @(($ErrorText -split "`n")[0]) | Select-Object -First 1
            return "$failed $(($line -replace '^ERROR:\s*', '').Trim())"
        }
    }
}

function Grant-CtfClusterAdmin {
    $c = $script:Ctf
    Write-CtfStep 'Kubernetes data-plane access (Azure RBAC)'
    Write-CtfInfo "AKS Automatic disables local accounts; kubectl needs '$($script:AksAdminRole)' (subscription Owner is not enough)."
    if ($c.SkipInfra) { return }
    $principal = Get-CtfSignedInPrincipal
    if (-not $principal.Id) { throw 'Could not determine the object ID of the signed-in principal' }
    # Granted on the resource group *before* the cluster exists: it has propagated by
    # the time the cluster is ready, and it cannot collide with an assignment AKS makes
    # on the cluster itself (same approach as the Terraform deployment).
    $rgId = Invoke-AzTsv group show -n $c.ResourceGroup --query id
    Set-CtfRoleAssignment $principal.Id $principal.Type $script:AksAdminRole $rgId
}

function Get-CtfCredentials {
    $c = $script:Ctf
    Write-CtfStep "kubectl credentials (context: $($c.KubeContext))"
    Invoke-AzCommand aks get-credentials -g $c.ResourceGroup -n $c.ClusterName --context $c.KubeContext --overwrite-existing | Out-Null
    # Pin the context to this subscription's tenant: kubectl keeps working when
    # the Azure CLI default later points at a subscription in another tenant.
    & kubelogin convert-kubeconfig -l azurecli --tenant-id $c.TenantId --context $c.KubeContext
    if ($LASTEXITCODE -ne 0) { throw 'kubelogin convert-kubeconfig failed' }
    Write-CtfInfo 'Waiting for the Kubernetes RBAC role assignment to take effect (can take up to 5 minutes) ...'
    for ($i = 0; $i -lt 40; $i++) {
        $answer = (Invoke-Kubectl auth can-i '*' '*' --all-namespaces 2>$null | Out-String).Trim()
        if ($answer -eq 'yes') { Write-CtfOk 'cluster-admin access confirmed'; return }
        Start-Sleep -Seconds 15
    }
    throw "kubectl still has no cluster-admin access after 10 minutes. Check the '$($script:AksAdminRole)' role assignment."
}

# C2: application routing add-on - managed NGINX (the Ingress-NGINX path the
# storefront starts on) and its Istio-based Gateway API implementation
# (approuting-istio, the path participants migrate the storefront to).
function Enable-CtfAppRouting {
    $c = $script:Ctf
    if (-not (Test-CtfSelected 'c2')) { return }
    Write-CtfStep 'C2: application routing add-on (managed NGINX + Gateway API with approuting-istio)'
    Invoke-Kubectl get ingressclass webapprouting.kubernetes.azure.com 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($c.SkipInfra) { throw 'IngressClass webapprouting.kubernetes.azure.com is missing (remove -SkipInfra)' }
        Write-CtfInfo 'Enabling the application routing add-on with managed NGINX (a few minutes) ...'
        Invoke-AzCoreCommand aks approuting enable -g $c.ResourceGroup -n $c.ClusterName -o none | Out-Null
    }
    $ok = Invoke-CtfRetry -Attempts 40 -DelaySeconds 15 -Action { Invoke-Kubectl get ingressclass webapprouting.kubernetes.azure.com 2>$null | Out-Null; $LASTEXITCODE -eq 0 }
    if (-not $ok) { throw 'IngressClass webapprouting.kubernetes.azure.com did not appear' }
    Write-CtfOk 'IngressClass webapprouting.kubernetes.azure.com (managed NGINX) available'
    Invoke-Kubectl get gatewayclass approuting-istio 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($c.SkipInfra) { throw 'GatewayClass approuting-istio is missing (remove -SkipInfra)' }
        Write-CtfInfo 'Enabling managed Gateway API CRDs and the approuting-istio GatewayClass (a few minutes) ...'
        Invoke-AzCoreCommand aks update -g $c.ResourceGroup -n $c.ClusterName --enable-gateway-api --enable-app-routing-istio -o none | Out-Null
    }
    $ok = Invoke-CtfRetry -Attempts 40 -DelaySeconds 15 -Action { Invoke-Kubectl get gatewayclass approuting-istio 2>$null | Out-Null; $LASTEXITCODE -eq 0 }
    if (-not $ok) { throw 'GatewayClass approuting-istio did not appear' }
    Write-CtfOk 'GatewayClass approuting-istio available'
}

# A2: Managed Prometheus, for the "Dashboards with Grafana" CPU throttling view.
# Clusters created by these scripts already send metrics to the lab's Azure
# Monitor workspace; an existing cluster without metrics is connected to it.
function Enable-CtfPrometheus {
    $c = $script:Ctf
    if (-not (Test-CtfSelected 'a2')) { return }
    Write-CtfStep 'A2: Azure Monitor managed service for Prometheus'
    if ((Invoke-AzTsv aks show -g $c.ResourceGroup -n $c.ClusterName --query azureMonitorProfile.metrics.enabled) -eq 'true') {
        Write-CtfOk 'Managed Prometheus metrics already enabled'
        return
    }
    if ($c.SkipInfra) { throw "Managed Prometheus is not enabled on $($c.ClusterName) (remove -SkipInfra)" }
    $workspaces = Install-CtfMonitorWorkspaces -MetricsOnly
    Write-CtfInfo "Enabling Managed Prometheus (Azure Monitor workspace $($c.AmwName)) - a few minutes ..."
    Invoke-AzCoreCommand aks update -g $c.ResourceGroup -n $c.ClusterName --enable-azure-monitor-metrics `
        --azure-monitor-workspace-resource-id $workspaces.AmwId -o none | Out-Null
    Write-CtfOk "Managed Prometheus metrics enabled ($($c.AmwName))"
}

# Returns @{ ClientId; PrincipalId } for a user-assigned managed identity, creating it if needed.
function Install-CtfIdentity([string]$Name) {
    $c = $script:Ctf
    if (-not (Test-AzCommand identity show -g $c.ResourceGroup -n $Name)) {
        if ($c.SkipInfra) { throw "Managed identity $Name not found (remove -SkipInfra)" }
        Invoke-AzCommand identity create -g $c.ResourceGroup -n $Name -l $c.Location -o none | Out-Null
        Write-CtfOk "created managed identity $Name"
    }
    return @{
        ClientId    = Invoke-AzTsv identity show -g $c.ResourceGroup -n $Name --query clientId
        PrincipalId = Invoke-AzTsv identity show -g $c.ResourceGroup -n $Name --query principalId
    }
}

function Set-CtfFederatedCredential([string]$Identity, [string]$Name, [string]$Subject) {
    $c = $script:Ctf
    $current = Invoke-AzTsv identity federated-credential show -g $c.ResourceGroup --identity-name $Identity -n $Name --query subject
    if ($current -eq $Subject) { Write-CtfOk "federated credential $Name -> $Subject"; return }
    $verb = if ($current) { 'update' } else { 'create' }
    Invoke-AzCommand identity federated-credential $verb -g $c.ResourceGroup --identity-name $Identity -n $Name `
        --issuer $c.OidcIssuer --subject $Subject --audiences api://AzureADTokenExchange -o none | Out-Null
    Write-CtfOk "federated credential $Name -> $Subject"
}

# Calls az rest with a JSON body passed through a file (avoids quoting problems
# with az.cmd on Windows). The requests are idempotent PUT/PATCH calls, so one
# that fails or hangs on the network is retried.
function Invoke-CtfAzRest([string]$Method, [string]$Url, [hashtable]$Body, [int]$Attempts = 3, [int]$TimeoutSeconds = 120) {
    $file = New-TemporaryFile
    try {
        $Body | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $file.FullName -Encoding utf8NoBOM
        for ($i = 1; $i -le $Attempts; $i++) {
            $r = Invoke-AzWithTimeout -TimeoutSeconds $TimeoutSeconds -Arguments @(
                'rest', '--method', $Method, '--url', $Url, '--body', "@$($file.FullName)", '--only-show-errors', '-o', 'none')
            if ($r.ExitCode -eq 0) { return }
            $reason = ($r.StdErr -replace '\s+', ' ').Trim()
            if ($i -eq $Attempts) { throw "az rest --method $Method --url $Url failed after $Attempts attempts: $reason" }
            Write-CtfWarn "az rest $Method failed (attempt $i/$Attempts): $reason - retrying ..."
            Start-Sleep -Seconds 10
        }
    }
    finally { Remove-Item $file.FullName -ErrorAction SilentlyContinue }
}

function Install-CtfC4Azure {
    $c = $script:Ctf
    if (-not (Test-CtfSelected 'c4')) { return }
    Write-CtfStep 'C4: Microsoft Foundry model deployment and ai-service identity'
    if (-not (Test-AzCommand cognitiveservices account show -g $c.ResourceGroup -n $c.AoaiAccount)) {
        if ($c.SkipInfra) { throw "Foundry account $($c.AoaiAccount) not found (remove -SkipInfra)" }
        $deletedId = Invoke-AzTsv cognitiveservices account list-deleted --query "[?name=='$($c.AoaiAccount)'].id | [0]"
        if ($deletedId -and $deletedId -match '/locations/([^/]+)/resourceGroups/([^/]+)/') {
            Write-CtfInfo "Purging soft-deleted account $($c.AoaiAccount) ..."
            Test-AzCommand cognitiveservices account purge -n $c.AoaiAccount -g $Matches[2] -l $Matches[1] | Out-Null
        }
        Invoke-AzCommand cognitiveservices account create -g $c.ResourceGroup -n $c.AoaiAccount -l $c.AoaiLocation `
            --kind AIServices --sku S0 --custom-domain $c.AoaiAccount --yes -o none | Out-Null
        Write-CtfOk "created Foundry account $($c.AoaiAccount) ($($c.AoaiLocation))"
    }
    $aoaiId = Invoke-AzTsv cognitiveservices account show -g $c.ResourceGroup -n $c.AoaiAccount --query id
    $c.Values.AZURE_OPENAI_ENDPOINT = "https://$($c.AoaiAccount).openai.azure.com/"
    if (-not $c.SkipInfra) {
        # Keys off: the app must authenticate with Microsoft Entra ID (workload identity).
        try { Invoke-CtfAzRest -Method patch -Url "https://management.azure.com$($aoaiId)?api-version=2024-10-01" -Body @{ properties = @{ disableLocalAuth = $true } } }
        catch { Write-CtfWarn "could not disable key authentication on $($c.AoaiAccount)" }
        # The update is asynchronous: a model deployment created while it runs fails with RequestConflict.
        $settled = Invoke-CtfRetry -Attempts 30 -DelaySeconds 10 -Action {
            (Invoke-AzTsv cognitiveservices account show -g $c.ResourceGroup -n $c.AoaiAccount --query properties.provisioningState) -eq 'Succeeded'
        }
        if (-not $settled) { Write-CtfWarn "Foundry account $($c.AoaiAccount) is still updating after 5 minutes" }
        if (-not (Test-AzCommand cognitiveservices account deployment show -g $c.ResourceGroup -n $c.AoaiAccount --deployment-name $c.DeploymentName)) {
            for ($attempt = 1; ; $attempt++) {
                try {
                    Invoke-AzCommand cognitiveservices account deployment create -g $c.ResourceGroup -n $c.AoaiAccount `
                        --deployment-name $c.DeploymentName --model-name $c.ModelName --model-version $c.ModelVersion `
                        --model-format OpenAI --sku-name GlobalStandard --sku-capacity $c.ModelCapacity -o none | Out-Null
                    break
                }
                catch {
                    if ($attempt -ge 6 -or $_.Exception.Message -notmatch 'RequestConflict|Another operation') { throw }
                    Write-CtfInfo "The Foundry account is busy (attempt $attempt of 6) - retrying in 20 seconds ..."
                    Start-Sleep -Seconds 20
                }
            }
        }
        Write-CtfOk "model deployment '$($c.DeploymentName)' ($($c.ModelName) $($c.ModelVersion), GlobalStandard x$($c.ModelCapacity))"
    }
    $identity = Install-CtfIdentity $c.AiIdentityName
    $c.Values.AI_SERVICE_CLIENT_ID = $identity.ClientId
    if (-not $c.SkipInfra) {
        Set-CtfRoleAssignment $identity.PrincipalId 'ServicePrincipal' 'Cognitive Services OpenAI User' $aoaiId
        Set-CtfFederatedCredential $c.AiIdentityName 'ai-service' 'system:serviceaccount:c4-assistant:ai-service'
    }
}

# Reads A4_FEDERATED_SUBJECT from <state>/challenges/a4-*/azure.env.
function Get-CtfA4Subject {
    $envFile = Join-Path (Get-CtfChallengeDir 'a4') 'azure.env'
    $line = Get-Content $envFile | Where-Object { $_ -match '^A4_FEDERATED_SUBJECT=' } | Select-Object -First 1
    if (-not $line) { throw "A4_FEDERATED_SUBJECT not found in $envFile" }
    return ($line -replace '^A4_FEDERATED_SUBJECT=', '').Trim()
}

function Install-CtfA4Azure {
    $c = $script:Ctf
    if (-not (Test-CtfSelected 'a4')) { return }
    Write-CtfStep 'A4: Key Vault, managed identity and federated credential'
    if (-not (Test-AzCommand keyvault show -n $c.KeyVaultName -g $c.ResourceGroup)) {
        if ($c.SkipInfra) { throw "Key Vault $($c.KeyVaultName) not found (remove -SkipInfra)" }
        if (Invoke-AzTsv keyvault list-deleted --query "[?name=='$($c.KeyVaultName)'].name | [0]") {
            Write-CtfInfo "Purging soft-deleted vault $($c.KeyVaultName) ..."
            Test-AzCommand keyvault purge -n $c.KeyVaultName | Out-Null
        }
        Invoke-AzCommand keyvault create -n $c.KeyVaultName -g $c.ResourceGroup -l $c.Location `
            --enable-rbac-authorization true --retention-days 7 -o none | Out-Null
        Write-CtfOk "created Key Vault $($c.KeyVaultName) (Azure RBAC)"
    }
    $kvId = Invoke-AzTsv keyvault show -n $c.KeyVaultName -g $c.ResourceGroup --query id
    $c.Values.KEY_VAULT_URI = Invoke-AzTsv keyvault show -n $c.KeyVaultName -g $c.ResourceGroup --query properties.vaultUri
    $identity = Install-CtfIdentity $c.ConfigIdentityName
    $c.Values.CONFIG_READER_CLIENT_ID = $identity.ClientId
    if ($c.SkipInfra) { return }
    # The secret is written through Azure Resource Manager (control plane), so the
    # deploying user needs no Key Vault data-plane role.
    Invoke-CtfAzRest -Method put -Url "https://management.azure.com$kvId/secrets/$($script:SecretName)?api-version=2023-07-01" `
        -Body @{ properties = @{ value = $script:SecretValue } }
    Write-CtfOk "secret '$($script:SecretName)' written"
    # Least privilege: read access to this one secret only.
    Set-CtfRoleAssignment $identity.PrincipalId 'ServicePrincipal' 'Key Vault Secrets User' "$kvId/secrets/$($script:SecretName)"
    Set-CtfFederatedCredential $c.ConfigIdentityName 'config-reader' (Get-CtfA4Subject)
}
