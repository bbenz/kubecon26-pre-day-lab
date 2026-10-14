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

# C2 - HTTPRoute backend port.
function Test-ChallengeC2 {
    $ns = 'c2-storefront'
    $gateway = kobj get gateway store-gateway -n $ns
    $route = kobj get httproute storefront -n $ns
    $want = [string](Get-Prop $gateway 'metadata.annotations').'kubecon.lab/storefront-hostname'
    Expect 'route keeps the intended hostname' $want ((@(Get-Prop $route 'spec.hostnames') -join ' '))
    $rules = @(Get-Prop $route 'spec.rules')
    $backend = (@($rules | ForEach-Object { $_.backendRefs } | ForEach-Object { $_.name }) -join ' ')
    $match = (@($rules | ForEach-Object { $_.matches } | ForEach-Object { "$($_.path.type):$($_.path.value)" }) -join ' ')
    Expect 'route still sends PathPrefix / to the store-front Service' 'store-front PathPrefix:/' "$backend $match"
    $conditions = @((@(Get-Prop $route 'status.parents') | Select-Object -First 1).conditions)
    $accepted = ($conditions | Where-Object type -EQ 'Accepted').status
    $resolved = ($conditions | Where-Object type -EQ 'ResolvedRefs').status
    Expect 'HTTPRoute status: Accepted / ResolvedRefs' 'True/True' "$accepted/$resolved"
    $ip = (@(Get-Prop $gateway 'status.addresses') | Select-Object -First 1).value
    if (-not $ip) { Fail 'gateway store-gateway has a public address' }
    else {
        try {
            $r = Invoke-WebRequest -Uri "http://$ip/" -Headers @{ Host = $want } -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
            if ($r.StatusCode -eq 200 -and $r.Content -match 'Contoso Pet Store') { Pass "storefront served through the gateway: http://$want/ -> HTTP $($r.StatusCode)" }
            else { Fail "storefront served through the gateway: http://$want/ -> HTTP $($r.StatusCode) (gateway $ip)" }
        }
        catch { Fail "storefront served through the gateway: http://$want/ (gateway $ip)"; Detail $_.Exception.Message }
        try {
            $r2 = Invoke-WebRequest -Uri "http://$ip/" -Headers @{ Host = 'not-the-store.example' } -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
            Expect 'requests that do not match the route are not sent to the store (HTTP status)' '404' ([string]$r2.StatusCode)
        }
        catch { Fail 'requests that do not match the route are not sent to the store'; Detail $_.Exception.Message }
    }
    Expect 'store-front is not exposed directly (Service type)' 'ClusterIP' (kj get service store-front -n $ns -o 'jsonpath={.spec.type}')
    $lbs = @((kobj get services -n $ns).items | Where-Object { $_.spec.type -eq 'LoadBalancer' } | ForEach-Object { $_.metadata.name })
    $extra = @($lbs | Where-Object { $_ -notlike 'store-gateway*' })
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
