# Success-criteria checks for the alternate challenges A1-A6 (dot-sourced by scoring/verify.ps1).

# A1 - DNS blocked by a namespace egress policy.
function Test-ChallengeA1 {
    $ns = 'a1-inventory'
    $pod = Get-RunningPod $ns 'app=inventory-sync'
    if (-not $pod) { Fail 'inventory-sync pod is running'; return }
    # All probes run inside the affected workload, so its network policy applies.
    Check 'name resolution works from inventory-sync (catalog-api resolves)' { k exec -n $ns $pod '--' getent hosts catalog-api *> $null; $LASTEXITCODE -eq 0 }
    Check 'application transaction works (inventory-sync -> catalog-api /items)' { k exec -n $ns $pod '--' curl -sf -m 5 -o /dev/null http://catalog-api:8080/items *> $null; $LASTEXITCODE -eq 0 }
    $status = kj exec -n $ns $pod '--' curl -s -m 5 http://localhost:8080/status
    if ($status -match '"http": "ok"') { Pass 'inventory-sync reports successful syncs' }
    else { Fail 'inventory-sync reports successful syncs'; Detail (($status -split "`n") -match 'dns|lastError' | Out-String) }
    k exec -n $ns $pod '--' curl -s -m 4 -o /dev/null http://ledger-api:8080/ *> $null
    if ($LASTEXITCODE -ne 0) { Pass 'prohibited egress is still blocked: inventory-sync -> ledger-api' } else { Fail 'prohibited egress is still blocked: inventory-sync -> ledger-api' }
    k exec -n $ns $pod '--' curl -s -m 4 -o /dev/null https://www.microsoft.com *> $null
    if ($LASTEXITCODE -ne 0) { Pass 'prohibited egress is still blocked: inventory-sync -> internet' } else { Fail 'prohibited egress is still blocked: inventory-sync -> internet' }
    $deny = kobj get networkpolicy default-deny-egress -n $ns
    $selectorEmpty = $deny -and -not @((Get-Prop $deny 'spec.podSelector').PSObject.Properties).Count
    $types = (@(Get-Prop $deny 'spec.policyTypes') -join ',')
    $rules = @(Get-Prop $deny 'spec.egress' | Where-Object { $_ })
    if ($selectorEmpty -and $types -eq 'Egress' -and -not $rules) { Pass 'namespace default-deny-egress policy unchanged' }
    else { Fail 'namespace default-deny-egress policy unchanged'; Detail "podSelector empty: $selectorEmpty, policyTypes: $types, egress rules: $($rules.Count)" }
    $allowAll = $false
    foreach ($np in @((kobj get networkpolicy -n $ns).items)) {
        foreach ($rule in @(Get-Prop $np 'spec.egress' | Where-Object { $null -ne $_ })) {
            if (-not (Get-Prop $rule 'to') -and -not (Get-Prop $rule 'ports')) { $allowAll = $true }
        }
    }
    if (-not $allowAll) { Pass 'no policy allows unrestricted egress' }
    else { Fail 'no policy allows unrestricted egress'; Detail "an egress rule has neither 'to' nor 'ports' (allows everything)" }
}

function ConvertTo-MilliCpu([string]$Quantity) {
    if (-not $Quantity) { return 0 }
    if ($Quantity -match '^(\d+)m$') { return [double]$Matches[1] }
    return [double]$Quantity * 1000
}

# A2 - CPU throttling under a fixed load.
function Test-ChallengeA2 {
    $ns = 'a2-checkout'
    $deploy = kobj get deployment checkout-api -n $ns
    $limits = (@(Get-Prop $deploy 'spec.template.spec.containers') | Select-Object -First 1).resources.limits
    $cpu = [string](Get-Prop $limits 'cpu'); $mem = [string](Get-Prop $limits 'memory')
    $replicas = [int](Get-Prop $deploy 'spec.replicas')
    if ($cpu -and $mem) { Pass "checkout-api keeps CPU and memory limits (cpu $cpu, memory $mem)" } else { Fail "checkout-api keeps CPU and memory limits (cpu '$cpu', memory '$mem')" }
    $milli = ConvertTo-MilliCpu $cpu
    if ($milli -gt 0 -and $milli -le 1000) { Pass 'CPU limit within the approved envelope (<= 1 CPU per container)' } else { Fail "CPU limit within the approved envelope (<= 1 CPU per container, got '$cpu')" }
    if ($replicas -le 2) { Pass "replicas within the approved envelope (<= 2, got $replicas)" } else { Fail "replicas within the approved envelope (<= 2, got $replicas)" }
    $hpaMax = @((kobj get hpa -n $ns).items | ForEach-Object { $_.spec.maxReplicas })
    if (-not ($hpaMax | Where-Object { $_ -gt 2 })) { Pass 'no autoscaling beyond 2 replicas' } else { Fail "no autoscaling beyond 2 replicas (HPA maxReplicas: $($hpaMax -join ' '))" }
    $api = (kobj get configmap checkout-api-script -n $ns).data.'checkout_api.py'
    $test = (kobj get configmap loadtest-script -n $ns).data.'loadtest.py'
    if ($api -match '(?m)^ITERATIONS = 250000$' -and $test -match '(?m)^REQUESTS = 120$' -and $test -match '(?m)^CONCURRENCY = 4$' -and $test -match '(?m)^TARGET_P95_MS = 300\.0$') {
        Pass 'workload and load test unchanged (same work per request, 120 requests @ concurrency 4, p95 <= 300 ms)'
    }
    else { Fail 'workload and load test unchanged' }
    Check 'checkout-api rollout complete, all replicas ready' { Test-Rollout $ns 'checkout-api' }
    $out = kj exec -n $ns deployment/loadgen '--' python3 /app/loadtest.py
    # Empty output means kubectl exec itself failed (for example a dropped API
    # connection), not the test: run it once more and keep errors for the report.
    if (-not $out) { $out = ((& kubectl --context $script:Kctx exec -n $ns deployment/loadgen '--' python3 /app/loadtest.py 2>&1) | Out-String).Trim() }
    if ($out -match '"result": "PASS"') { Pass 'fixed load test meets the objective' } else { Fail 'fixed load test meets the objective' }
    Detail (($out -split "`r?`n") | Select-Object -Last 1)
}

# A3 - single replica + PodDisruptionBudget blocks voluntary eviction.
function Test-ChallengeA3 {
    $ns = 'a3-maintenance'
    $desired = [int](kj get deployment inventory-api -n $ns -o 'jsonpath={.spec.replicas}')
    if ($desired -ge 2) { Pass "inventory-api has redundancy (replicas: $desired)" } else { Fail "inventory-api has redundancy (replicas: $desired, need at least 2)" }
    $pdb = kobj get pdb inventory-api -n $ns
    $sel = (Get-Prop $pdb 'spec.selector.matchLabels').app
    $min = [string](Get-Prop $pdb 'spec.minAvailable'); $max = [string](Get-Prop $pdb 'spec.maxUnavailable')
    if ($sel -eq 'inventory-api' -and (($min -and $min -notin '0', '0%') -or $max)) {
        Pass "PodDisruptionBudget still protects inventory-api (minAvailable=$(if ($min) { $min } else { 'unset' }), maxUnavailable=$(if ($max) { $max } else { 'unset' }))"
    }
    else { Fail 'PodDisruptionBudget still protects inventory-api (deleted or minAvailable 0?)' }
    Check 'inventory-api rollout complete, all replicas ready' { Test-Rollout $ns 'inventory-api' }
    $job = "verify-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    k create job $job --from=cronjob/maintenance-check -n $ns *> $null
    if ($LASTEXITCODE -eq 0) {
        [void](Wait-K8sJob $ns $job 300)
        $log = kj logs "job/$job" -n $ns
        if ($log -match '(?m)^RESULT: PASS') { Pass 'maintenance check: controlled eviction accepted with no failed requests' }
        else { Fail 'maintenance check: controlled eviction accepted with no failed requests' }
        Detail ((($log -split "`r?`n") -match 'Eviction|Synthetic|RESULT') -join "`n")
        k delete job $job -n $ns --wait=false *> $null
    }
    else { Fail 'maintenance check job could be started (cronjob/maintenance-check missing?)' }
    Check 'inventory-api back at its target replica count' { Test-Rollout $ns 'inventory-api' }
}

# A4 - workload identity federation subject mismatch.
function Test-ChallengeA4 {
    $ns = 'a4-config'
    # The app retries every 20s; allow time for the federated credential and role assignment to propagate.
    $status = $null
    for ($i = 1; $i -le 9; $i++) {
        $raw = Get-ServiceProxy $ns 'config-reader:http' '/status'
        $status = if ($raw) { $raw | ConvertFrom-Json } else { $null }
        if ($status -and $status.ok) { break }
        if ($i -lt 9) { Start-Sleep -Seconds 20 }
    }
    if ($status -and $status.ok -and $status.value -eq 'kubecon-ctf-a4: identity without secrets works') { Pass 'config-reader reads the lab value from Key Vault with workload identity' }
    else { Fail 'config-reader reads the lab value from Key Vault with workload identity'; if ($status) { Detail "stage: $($status.stage)"; Detail "detail: $($status.detail)" } }
    $rawNeg = Get-ServiceProxy $ns 'report-generator:http' '/status'
    $neg = if ($rawNeg) { $rawNeg | ConvertFrom-Json } else { $null }
    if ($neg -and -not $neg.ok -and $neg.stage -eq 'token-exchange') { Pass 'unrelated workload report-generator is still NOT authorized' }
    else { Fail 'unrelated workload report-generator is still NOT authorized'; if ($neg) { Detail "ok: $($neg.ok), stage: $($neg.stage)" } }
    $secrets = @((kobj get secrets -n $ns).items).Count
    Expect 'no stored credentials added to the namespace (Kubernetes Secrets)' '0' ([string]$secrets)
    $wi = kj get deployment config-reader -n $ns -o 'jsonpath={.spec.template.metadata.labels.azure\.workload\.identity/use}'
    Expect 'config-reader still uses workload identity (pod label azure.workload.identity/use)' 'true' $wi
}

# A5 - readiness probe that passes before the app can serve.
function Test-ChallengeA5 {
    $ns = 'a5-releases'
    $web = @((kobj get deployment web -n $ns).spec.template.spec.containers | Where-Object name -EQ 'web')[0]
    $rp = [string](Get-Prop $web 'readinessProbe.httpGet.path')
    $lp = [string](Get-Prop $web 'livenessProbe.httpGet.path')
    $delay = [int](Get-Prop $web 'readinessProbe.initialDelaySeconds')
    Expect 'readiness probe uses the meaningful readiness endpoint' '/ready' $rp
    if ($lp -ne '/ready') { Pass "liveness probe does not depend on readiness (path $lp)" } else { Fail 'liveness probe does not depend on readiness (liveness uses /ready: restart loop risk)' }
    if ($delay -le 10) { Pass "no long arbitrary readiness delay (initialDelaySeconds $delay)" } else { Fail "no long arbitrary readiness delay (initialDelaySeconds $delay)" }
    Check 'web rollout complete, all replicas ready' { Test-Rollout $ns 'web' }
    $out = kj exec -n $ns deployment/rollout-tester '--' python3 /app/rollout_test.py
    if ($out -match '(?m)^RESULT: PASS') { Pass 'controlled rollout under traffic with zero failed requests' } else { Fail 'controlled rollout under traffic with zero failed requests' }
    Detail ((($out -split "`r?`n") -match '^(Rollout|Customer|RESULT)') -join "`n")
}

# A6 - Deployment references the wrong PersistentVolumeClaim.
function Test-ChallengeA6 {
    $ns = 'a6-records'
    $claim = kj get deployment records-api -n $ns -o 'jsonpath={.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}'
    Expect 'records-api mounts the original claim' 'records-data' $claim
    Expect 'original PersistentVolumeClaim records-data still exists and is bound' 'Bound' (kj get pvc records-data -n $ns -o 'jsonpath={.status.phase}')
    Check 'records-api rollout complete, ready (includes disk attach)' { Test-Rollout $ns 'records-api' }
    $raw = Get-ServiceProxy $ns 'records-api:http' '/records'
    $records = if ($raw) { $raw | ConvertFrom-Json } else { $null }
    if ($records -and $records.records -eq 500) { Pass 'records-api serves the 500 seeded records' } else { Fail 'records-api serves the 500 seeded records'; Detail $(if ($raw) { $raw } else { 'no response' }) }
    if ($records -and $records.sha256 -eq 'aa451749a529f6202fb1f54e43d7f092419a70fb8f24d1d4121725bc4f4cc149') { Pass 'dataset checksum unchanged' } else { Fail 'dataset checksum unchanged' }
    $others = @((kobj get pvc -n $ns).items | ForEach-Object { $_.metadata.name } | Where-Object { $_ -ne 'records-data' })
    if ($others) { Detail "note: extra claims in the namespace ($($others -join ' ')) - an empty replacement volume is not a valid recovery" }
}
