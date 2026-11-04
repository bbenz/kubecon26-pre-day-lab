<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: manual test access life cycle action (LCA), for TEST lab profiles only.

.DESCRIPTION
    Lets the lab's cloud portal user build the begin state by hand (the prepare LCA with Manual =
    $true, or skillable\lca\manual-begin-state-bootstrap.txt) before a pool admin turns on the prepare
    LCA's cloud credentials. Don't add it to the event's lab profile: attendees don't need it, and the
    prepare LCA registers the providers itself.

    Skillable gives the cloud portal user the role in the resource group's Permissions on the profile's
    Cloud tab, usually Contributor (LOD Contributor), which can't assign roles. The begin state assigns
    roles (AKS RBAC Cluster Admin, and roles for the C4 and A4 managed identities). This script gives
    the portal user Owner on the resource group, and registers the lab's resource providers, which
    each new pool subscription may be missing. It runs in Skillable's cloud platform, signed in as the
    cloud subscription's service principal, so it needs none of the pool's secure tokens.

      Action: Execute Script in Cloud Platform    Language: PowerShell
      Event: Post-Build                           Blocking: No    Timeout: 10 minutes    Retries: 0
      Error action: Log
#>
$ErrorActionPreference = 'Stop'

$ResourceGroup = '@lab.CloudResourceGroup(ResourceGroup1).Name'
$PortalUser    = '@lab.CloudPortalCredential(User1).Username'
$Role          = 'Owner'   # If the access control policy blocks Owner, use User Access Administrator.
$Providers     = 'Microsoft.ContainerService', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.ManagedIdentity',
                 'Microsoft.PolicyInsights', 'Microsoft.CognitiveServices', 'Microsoft.KeyVault', 'Microsoft.Monitor',
                 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.AlertsManagement', 'Microsoft.Dashboard',
                 'Microsoft.Storage', 'Microsoft.KubernetesConfiguration'

if (-not $ResourceGroup -or $ResourceGroup -match '^@\s*lab\.') { throw 'KubeCon CTF manual test access: ResourceGroup has no value. Check its token.' }
$report = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[string]

# 1. The role, first, so that you can start the manual begin state while the providers register
try {
    $scope = (Get-AzResourceGroup -Name $ResourceGroup).ResourceId
    if (-not $PortalUser -or $PortalUser -match '^@\s*lab\.') {
        $users = @(Get-AzRoleAssignment -Scope $scope | Where-Object { $_.ObjectType -eq 'User' -and $_.Scope -eq $scope -and $_.SignInName } |
                   ForEach-Object { [string]$_.SignInName } | Select-Object -Unique)
        if ($users.Count -ne 1) { throw "PortalUser has no value, and $($users.Count) users have a role on $ResourceGroup." }
        $PortalUser = $users[0]
    }
    try {
        New-AzRoleAssignment -SignInName $PortalUser -RoleDefinitionName $Role -Scope $scope | Out-Null
        $report.Add("$PortalUser is now $Role of $ResourceGroup.")
    } catch {
        if ($_.Exception.Message -notmatch 'already exists|Conflict') { throw }
        $report.Add("$PortalUser was already $Role of $ResourceGroup.")
    }
} catch {
    $problems.Add("Couldn't give the cloud portal user the $Role role on ${ResourceGroup}: $($_.Exception.Message)")
}

# 2. Resource providers
try {
    $registered = New-Object System.Collections.Generic.List[string]
    foreach ($namespace in $Providers) {
        $states = @(Get-AzResourceProvider -ProviderNamespace $namespace -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.RegistrationState })
        if ($states -notcontains 'Registered') {
            Register-AzResourceProvider -ProviderNamespace $namespace | Out-Null
            $registered.Add($namespace)
        }
    }
    if ($registered.Count -gt 0) { $report.Add("Registering $($registered -join ', ').") } else { $report.Add('The resource providers were already registered.') }
} catch {
    $problems.Add("Couldn't register the resource providers: $($_.Exception.Message)")
}

$summary = 'KubeCon CTF manual test access: ' + ($report -join ' ')
if ($problems.Count -gt 0) { throw ($summary + ' ' + ($problems -join ' ')) }
Write-Output $summary
