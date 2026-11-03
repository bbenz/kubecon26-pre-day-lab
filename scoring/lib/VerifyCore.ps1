# Success-criteria checks for the core challenges C1-C4 (dot-sourced by scoring/verify.ps1).

function Get-OrdersQueueDepth([string]$Namespace) {
    $lines = (k exec -n $Namespace rabbitmq-0 '--' rabbitmqctl list_queues name messages 2>$null) -split "`r?`n"
    foreach ($line in $lines) { if ($line -match '^orders\s+(\d+)') { return [int]$Matches[1] } }
    return 0
}

# C1 - order-service crash after a configuration rollout.
function Test-ChallengeC1 {
    $ns = 'c1-store'
    $addr = kj get configmap order-service-configs -n $ns -o 'jsonpath={.data.FASTIFY_ADDRESS}'
    # A bind host (0.0.0.0 / ::) or unset (fastify-cli then listens on all interfaces) are both valid.
    if ($addr -notmatch ':\d+$') {
        Pass "authoritative config fixed: FASTIFY_ADDRESS in ConfigMap order-service-configs is a bind host or unset ('$addr')"
    }
    else {
        Fail 'authoritative config fixed: FASTIFY_ADDRESS in ConfigMap order-service-configs is a bind host or unset'
        Detail "current value: '$addr' (a host only - the port is FASTIFY_PORT)"
    }
    $override = kj get deployment order-service -n $ns -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="FASTIFY_ADDRESS")].value}'
    Expect 'no temporary override of FASTIFY_ADDRESS on the Deployment (fix lives in the ConfigMap)' '' $override
    Check 'order-service rollout complete, all replicas ready' { Test-Rollout $ns 'order-service' }
    $before = Get-RestartCount $ns 'app=order-service'
    Start-Sleep -Seconds $script:ObserveSeconds
    $after = Get-RestartCount $ns 'app=order-service'
    $ready = kj get deployment order-service -n $ns -o 'jsonpath={.status.readyReplicas}/{.spec.replicas}'
    $parts = $ready -split '/'
    if ($before -eq $after -and $parts[0] -and $parts[0] -eq $parts[1]) {
        Pass "stable for $($script:ObserveSeconds)s: restart count unchanged ($after), $ready ready"
    }
    else { Fail "stable for $($script:ObserveSeconds)s: restart count $before -> $after, ready $ready" }
    $q1 = Get-OrdersQueueDepth $ns
    # A customer order through the storefront's API path (store-front nginx -> order-service).
    $out = k exec -n $ns deployment/store-front '--' wget -q -O /dev/null --header 'Content-Type: application/json' `
        --post-data '{"customerId":"ctf-verify","items":[{"productId":1,"quantity":1,"price":9.99}]}' `
        http://localhost:8080/api/orders 2>&1
    if ($LASTEXITCODE -eq 0) { Pass 'synthetic order accepted (POST /api/orders through the storefront)' }
    else { Fail 'synthetic order accepted (POST /api/orders through the storefront)'; Detail ($out | Out-String) }
    Start-Sleep -Seconds 3
    $q2 = Get-OrdersQueueDepth $ns
    if ($q2 -gt $q1) { Pass "order reached the RabbitMQ 'orders' queue ($q1 -> $q2 messages)" }
    else { Fail "order reached the RabbitMQ 'orders' queue ($q1 -> $q2 messages)" }
}

# C2 - move the storefront from Ingress-NGINX (application routing add-on) to
# Gateway API (application routing's approuting-istio implementation). The
# participant names the Gateway and HTTPRoute, so they are discovered here.
function Test-ChallengeC2 {
    $ns = 'c2-storefront'
    $labelKey = 'service.beta.kubernetes.io/azure-dns-label-name'
    $nsAnnotations = Get-Prop (kobj get namespace $ns) 'metadata.annotations'
    $hostName = [string](Get-Key $nsAnnotations 'kubecon.lab/storefront-hostname')
    $label = [string](Get-Key $nsAnnotations 'kubecon.lab/storefront-dns-label')
    if (-not $hostName -or -not $label) {
        Fail 'storefront hostname known (namespace annotations kubecon.lab/storefront-hostname and -dns-label)'
        return
    }
    # 1. A gateway of the AKS application routing Gateway API class, programmed.
    #    Prefer the one that carries the storefront's DNS label.
    $allGateways = @(Get-Prop (kobj get gateways.gateway.networking.k8s.io -n $ns) 'items' | Where-Object { $null -ne $_ })
    $candidates = @($allGateways | Where-Object { (Get-Prop $_ 'spec.gatewayClassName') -eq 'approuting-istio' })
    $gateway = @($candidates | Where-Object { [string](Get-Key (Get-Prop $_ 'spec.infrastructure.annotations') $labelKey) -eq $label }) | Select-Object -First 1
    if (-not $gateway) { $gateway = $candidates | Select-Object -First 1 }
    $gw = ''; $ip = ''
    if (-not $gateway) {
        Fail "a Gateway of class approuting-istio exists in $ns (application routing Gateway API implementation)"
        Detail "gateways found: $((@($allGateways | ForEach-Object { "$(Get-Prop $_ 'metadata.name')($(Get-Prop $_ 'spec.gatewayClassName'))" }) -join ' '))"
    }
    else {
        $gw = [string](Get-Prop $gateway 'metadata.name')
        $programmed = Get-ConditionStatus (Get-Prop $gateway 'status.conditions') 'Programmed'
        $ip = [string](@(Get-Prop $gateway 'status.addresses' | Where-Object { $null -ne $_ } | ForEach-Object { Get-Prop $_ 'value' }) | Select-Object -First 1)
        if ($programmed -eq 'True' -and $ip) { Pass "Gateway $gw (approuting-istio) is programmed with public address $ip" }
        else { Fail "Gateway $gw (approuting-istio) is programmed with a public address (Programmed=$(if ($programmed) { $programmed } else { 'unknown' }))" }
        Expect "gateway publishes the storefront's DNS name (infrastructure annotation azure-dns-label-name)" $label ([string](Get-Key (Get-Prop $gateway 'spec.infrastructure.annotations') $labelKey))
    }
    # 2. An HTTPRoute attached to that gateway, accepted, for the storefront hostname.
    $route = $null; $routeSummary = @()
    foreach ($r in @(Get-Prop (kobj get httproutes.gateway.networking.k8s.io -n $ns) 'items' | Where-Object { $null -ne $_ })) {
        $parents = @(Get-Prop $r 'spec.parentRefs' | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-Prop $_ 'name') })
        $routeHosts = @(Get-Prop $r 'spec.hostnames' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $routeSummary += "$(Get-Prop $r 'metadata.name')|$($parents -join ' ')|$($routeHosts -join ' ')"
        if (-not $route -and $gw -and $parents -contains $gw -and $routeHosts -contains $hostName) { $route = $r }
    }
    if (-not $route) {
        Fail "an HTTPRoute attached to the gateway serves $hostName"
        Detail "routes found (name|parents|hostnames): $($routeSummary -join '  ')"
    }
    else {
        $routeName = [string](Get-Prop $route 'metadata.name')
        $parentStatus = @(Get-Prop $route 'status.parents' | Where-Object { $null -ne $_ -and (Get-Prop $_ 'parentRef.name') -eq $gw }) | Select-Object -First 1
        $conditions = Get-Prop $parentStatus 'conditions'
        $accepted = Get-ConditionStatus $conditions 'Accepted'
        $resolved = Get-ConditionStatus $conditions 'ResolvedRefs'
        Expect "HTTPRoute $routeName attached to $gw for ${hostName}: Accepted / ResolvedRefs" 'True/True' "$accepted/$resolved"
        $rules = @(Get-Prop $route 'spec.rules' | Where-Object { $null -ne $_ } | ForEach-Object {
                $rule = $_
                $matchText = @(Get-Prop $rule 'matches' | Where-Object { $null -ne $_ } | ForEach-Object { "$(Get-Prop $_ 'path.type'):$(Get-Prop $_ 'path.value')" }) -join ''
                $backendText = @(Get-Prop $rule 'backendRefs' | Where-Object { $null -ne $_ } | ForEach-Object { "$(Get-Prop $_ 'name'):$(Get-Prop $_ 'port')" }) -join ''
                "$matchText>$backendText"
            })
        if ($rules -contains 'PathPrefix:/>store-front:80' -or $rules -contains '>store-front:80') { Pass 'route sends PathPrefix / to the store-front Service on port 80' }
        else { Fail 'route sends PathPrefix / to the store-front Service on port 80'; Detail "rules: $($rules -join '; ')" }
    }
    # 3. The public name now reaches the store through the gateway (the cutover).
    if ($gw -and $ip) {
        $tries = if ($script:QuickMode) { 2 } else { 6 }
        $status = 0; $resolvedIps = @(); $content = ''
        for ($i = 1; $i -le $tries; $i++) {
            try { $resolvedIps = @([System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString }) } catch { $resolvedIps = @() }
            if ($resolvedIps -contains $ip) {
                try {
                    $resp = Invoke-WebRequest -Uri "http://$hostName/" -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
                    $status = [int]$resp.StatusCode; $content = [string]$resp.Content
                }
                catch { $status = 0; $content = '' }
                if ($status -eq 200 -and $content -match 'Contoso Pet Store') { break }
            }
            if ($i -lt $tries) { Start-Sleep -Seconds 10 }
        }
        if ($resolvedIps -contains $ip -and $status -eq 200 -and $content -match 'Contoso Pet Store') {
            Pass "storefront served at http://$hostName/ through the gateway (DNS -> $ip, HTTP 200)"
        }
        elseif (-not $resolvedIps) {
            Fail "storefront served at http://$hostName/ through the gateway"
            Detail 'the name does not resolve yet - publish the DNS label on the gateway (cutover); new labels take up to a minute'
        }
        elseif ($resolvedIps -notcontains $ip) { Fail "storefront served at http://$hostName/ through the gateway (DNS -> $($resolvedIps -join ','), gateway $ip)" }
        else { Fail "storefront served at http://$hostName/ through the gateway (HTTP $status, gateway $ip)" }
        try {
            $resp2 = Invoke-WebRequest -Uri "http://$ip/" -Headers @{ Host = 'not-the-store.example' } -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
            Expect 'requests for other host names are not sent to the store (HTTP status at the gateway)' '404' ([string]$resp2.StatusCode)
        }
        catch { Fail 'requests for other host names are not sent to the store'; Detail $_.Exception.Message }
    }
    else { Fail "storefront served at http://$hostName/ through the gateway (no programmed gateway)" }
    # 4. Ingress-NGINX decommissioned for the storefront, nothing exposed around the gateway.
    $ingresses = @(Get-Prop (kobj get ingresses -n $ns) 'items' | Where-Object { $null -ne $_ } | ForEach-Object { "$(Get-Prop $_ 'metadata.name')($(Get-Prop $_ 'spec.ingressClassName'))" })
    if (-not $ingresses) { Pass "legacy Ingress-NGINX path decommissioned (no Ingress left in $ns)" }
    else { Fail "legacy Ingress-NGINX path decommissioned (Ingress still present: $($ingresses -join ' '))" }
    Expect 'store-front is not exposed directly (Service type)' 'ClusterIP' (kj get service store-front -n $ns -o 'jsonpath={.spec.type}')
    $lbs = @(Get-Prop (kobj get services -n $ns) 'items' | Where-Object { $null -ne $_ -and (Get-Prop $_ 'spec.type') -eq 'LoadBalancer' } | ForEach-Object { [string](Get-Prop $_ 'metadata.name') })
    $extra = @($lbs | Where-Object { $_ -notlike '*-approuting-istio' })
    if (-not $extra) { Pass "no extra public endpoints in the namespace (LoadBalancer services: $(if ($lbs) { $lbs -join ' ' } else { 'none' }))" }
    else { Fail "no extra public endpoints in the namespace (LoadBalancer services: $($lbs -join ' '))" }
}

# C3 - node auto-provisioning NodePool constraints.
function Test-ChallengeC3 {
    $ns = 'c3-processing'
    $pool = kobj get nodepool c3-processing
    $requirements = @(Get-Prop $pool 'spec.template.spec.requirements')
    $arch = (@(($requirements | Where-Object key -EQ 'kubernetes.io/arch').values) -join ' ')
    Expect 'NodePool keeps the required architecture' 'amd64' $arch
    $skus = @(($requirements | Where-Object key -EQ 'karpenter.azure.com/sku-name').values | Where-Object { $_ })
    $arm = @($skus | Where-Object { $_ -cmatch '^Standard_[A-Za-z]+[0-9]+[a-z]*p[a-z]*_v[0-9]+$' })
    if (-not $arm) { Pass "approved instance types are compatible with amd64 ($(if ($skus) { $skus -join ' ' } else { 'no sku-name restriction' }))" }
    else { Fail 'approved instance types are compatible with amd64'; Detail "Arm64 SKUs still listed: $($arm -join ' ')" }
    $label = (Get-Prop $pool 'spec.template.metadata.labels').'kubecon.lab/pool'
    $taint = (@(Get-Prop $pool 'spec.template.spec.taints') | Where-Object key -EQ 'kubecon.lab/pool').effect
    Expect 'pool isolation intact (node label / NoSchedule taint)' 'processing/NoSchedule' "$label/$taint"
    $limit = Get-Prop $pool 'spec.limits.cpu'
    if ($limit) { Pass "pool CPU limit still set ($limit)" } else { Fail 'pool CPU limit still set' }
    $job = kobj get job order-batch -n $ns
    $sel = Get-Prop $job 'spec.template.spec.nodeSelector'
    Expect 'order-batch keeps its placement requirements (pool/arch)' 'processing/amd64' "$($sel.'kubecon.lab/pool')/$($sel.'kubernetes.io/arch')"
    # Node provisioning can take a few minutes; do not wait long while the fault is obviously still present.
    $wait = if ($arm) { 30 } else { $script:LongWait }
    $jobDone = $false
    if (Wait-K8sJob $ns 'order-batch' $wait) { Pass 'order-batch Job completed'; $jobDone = $true }
    else {
        Fail "order-batch Job completed (waited $($wait)s for a node from NAP)"
        Detail (kj get events -n $ns --field-selector reason=FailedScheduling -o 'jsonpath={.items[-1:].message}')
    }
    $log = kj logs job/order-batch -n $ns --tail=3 --pod-running-timeout=5s
    if ($log -match 'BATCH COMPLETE.*arch x86_64') { Pass 'batch ran on an amd64 node' }
    elseif ($jobDone -and -not (kj get pods -n $ns -l app=order-batch -o name)) {
        # NAP removes the empty node (consolidateAfter) and the finished pod goes with it.
        Pass "batch ran on an amd64 node (pod already removed with its empty node; placement enforced by the Job's nodeSelector)"
    }
    else { Fail 'batch ran on an amd64 node' }
    $node = kj get pods -n $ns -l app=order-batch --field-selector=status.phase=Succeeded -o 'jsonpath={.items[0].spec.nodeName}'
    if ($node) {
        $nodePool = kj get node $node -o 'jsonpath={.metadata.labels.karpenter\.sh/nodepool}'
        if ($nodePool) { Expect "batch ran on capacity from the dedicated NodePool (node $node)" 'c3-processing' $nodePool }
        else { Detail "node $node has already been consolidated away - placement checked via the pod's nodeSelector" }
    }
}

# C4 - AI dependency: model deployment name.
function Test-ChallengeC4 {
    $ns = 'c4-assistant'
    $cm = kobj get configmap ai-service-configs -n $ns
    $useAd = [string](Get-Prop $cm 'data.USE_AZURE_AD')
    $keys = "$(Get-Prop $cm 'data.AZURE_OPENAI_API_KEY')$(Get-Prop $cm 'data.OPENAI_API_KEY')"
    $keys += kj get deployment ai-service -n $ns -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="AZURE_OPENAI_API_KEY")].value}{.spec.template.spec.containers[*].env[?(@.name=="OPENAI_API_KEY")].value}'
    if ($useAd -eq 'true' -and -not $keys) { Pass 'ai-service still authenticates with Microsoft Entra ID (no API keys configured)' }
    else { Fail "ai-service still authenticates with Microsoft Entra ID (USE_AZURE_AD=$useAd, API key configured: $([bool]$keys))" }
    # The effective setting (a Deployment env var wins over the ConfigMap) must name
    # the provisioned deployment. A bare model name also answers on Foundry accounts
    # but bypasses the deployment's capacity and policies. Override the expected
    # name with AOAI_DEPLOYMENT_NAME if the lab was deployed with another name.
    $want = if ($env:AOAI_DEPLOYMENT_NAME) { $env:AOAI_DEPLOYMENT_NAME } else { 'store-assistant' }
    $dep = kj get deployment ai-service -n $ns -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="AZURE_OPENAI_DEPLOYMENT_NAME")].value}'
    if (-not $dep) { $dep = [string](Get-Prop $cm 'data.AZURE_OPENAI_DEPLOYMENT_NAME') }
    Expect 'ai-service calls the provisioned model deployment' $want $dep
    Check 'ai-service rollout complete, all replicas ready' { Test-Rollout $ns 'ai-service' }
    # The same call the store admin's "Ask AI Assistant" button makes:
    # store-admin nginx -> product-service -> ai-service -> Foundry model deployment.
    # Retries cover role-assignment propagation right after a fresh deployment.
    $out = ''
    for ($i = 1; $i -le 4; $i++) {
        $out = (k exec -n $ns deployment/store-admin '--' wget -q -O - --header 'Content-Type: application/json' `
                --post-data '{"name":"Contoso Catnip Kicker","tags":["toy","cat"]}' `
                http://localhost:8081/api/ai/generate/description 2>&1) | Out-String
        if ($LASTEXITCODE -eq 0 -and $out -match '"description"') { break }
        if ($i -lt 4) { Start-Sleep -Seconds 20 }
    }
    if ($out -match '"description"') { Pass 'synthetic request store-admin -> product-service -> ai-service -> model deployment returns a description' }
    else {
        Fail 'synthetic request store-admin -> product-service -> ai-service -> model deployment returns a description'
        Detail $out
        Detail ((kj logs deployment/ai-service -n $ns --tail=50) -split "`r?`n" | Where-Object { $_ -match 'error|exception' } | Select-Object -Last 2 | Out-String)
    }
}
