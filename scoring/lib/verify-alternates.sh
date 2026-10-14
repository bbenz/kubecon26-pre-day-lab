#!/usr/bin/env bash
# shellcheck shell=bash
# Success-criteria checks for the alternate challenges A1-A6 (sourced by scoring/verify.sh).

# A1 - DNS blocked by a namespace egress policy.
verify_a1() {
  local ns=a1-inventory pod status dd rules
  pod=$(first_pod "$ns" app=inventory-sync)
  if [ -z "$pod" ]; then fail "inventory-sync pod is running"; return; fi
  # All probes run inside the affected workload, so its network policy applies.
  check "name resolution works from inventory-sync (catalog-api resolves)" k exec -n "$ns" "$pod" -- getent hosts catalog-api
  check "application transaction works (inventory-sync -> catalog-api /items)" \
    k exec -n "$ns" "$pod" -- curl -sf -m 5 -o /dev/null http://catalog-api:8080/items
  status=$(kj exec -n "$ns" "$pod" -- curl -s -m 5 http://localhost:8080/status)
  if printf '%s' "$status" | grep -q '"http": "ok"'; then
    pass "inventory-sync reports successful syncs"
  else
    fail "inventory-sync reports successful syncs"; detail "$(printf '%s' "$status" | grep -E 'dns|lastError')"
  fi
  if k exec -n "$ns" "$pod" -- curl -s -m 4 -o /dev/null http://ledger-api:8080/ >/dev/null 2>&1; then
    fail "prohibited egress is still blocked: inventory-sync -> ledger-api"
  else
    pass "prohibited egress is still blocked: inventory-sync -> ledger-api"
  fi
  if k exec -n "$ns" "$pod" -- curl -s -m 4 -o /dev/null https://www.microsoft.com >/dev/null 2>&1; then
    fail "prohibited egress is still blocked: inventory-sync -> internet"
  else
    pass "prohibited egress is still blocked: inventory-sync -> internet"
  fi
  dd=$(kj get networkpolicy default-deny-egress -n "$ns" -o jsonpath='{.spec.podSelector}|{.spec.policyTypes[*]}|{.spec.egress}')
  expect "namespace default-deny-egress policy unchanged (podSelector|policyTypes|egress rules)" "{}|Egress|" "$dd"
  rules=$(kj get networkpolicy -n "$ns" -o jsonpath='{range .items[*]}{range .spec.egress[*]}[{.to}|{.ports}]{end}{end}')
  case "$rules" in
    *"[|]"*) fail "no policy allows unrestricted egress"; detail "an egress rule has neither 'to' nor 'ports' (allows everything)" ;;
    *)       pass "no policy allows unrestricted egress" ;;
  esac
}

# A2 - CPU throttling under a fixed load.
verify_a2() {
  local ns=a2-checkout cpu mem replicas hpa max_ok=true m out api test
  cpu=$(kj get deployment checkout-api -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')
  mem=$(kj get deployment checkout-api -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
  replicas=$(kj get deployment checkout-api -n "$ns" -o jsonpath='{.spec.replicas}')
  if [ -n "$cpu" ] && [ -n "$mem" ]; then pass "checkout-api keeps CPU and memory limits (cpu $cpu, memory $mem)"; else fail "checkout-api keeps CPU and memory limits (cpu '${cpu}', memory '${mem}')"; fi
  if awk -v v="$cpu" 'BEGIN { if (v ~ /m$/) { sub(/m$/, "", v); m = v + 0 } else m = v * 1000; exit !(m > 0 && m <= 1000) }'; then
    pass "CPU limit within the approved envelope (<= 1 CPU per container)"
  else
    fail "CPU limit within the approved envelope (<= 1 CPU per container, got '$cpu')"
  fi
  if [ -n "$replicas" ] && [ "$replicas" -le 2 ]; then pass "replicas within the approved envelope (<= 2, got $replicas)"; else fail "replicas within the approved envelope (<= 2, got $replicas)"; fi
  hpa=$(kj get hpa -n "$ns" -o jsonpath='{range .items[*]}{.spec.maxReplicas}{" "}{end}')
  for m in $hpa; do [ "$m" -le 2 ] || max_ok=false; done
  if [ "$max_ok" = true ]; then pass "no autoscaling beyond 2 replicas"; else fail "no autoscaling beyond 2 replicas (HPA maxReplicas: $hpa)"; fi
  api=$(kj get configmap checkout-api-script -n "$ns" -o jsonpath='{.data.checkout_api\.py}')
  test=$(kj get configmap loadtest-script -n "$ns" -o jsonpath='{.data.loadtest\.py}')
  if printf '%s' "$api" | grep -q '^ITERATIONS = 250000$' && printf '%s' "$test" | grep -q '^REQUESTS = 120$' \
      && printf '%s' "$test" | grep -q '^CONCURRENCY = 4$' && printf '%s' "$test" | grep -q '^TARGET_P95_MS = 300.0$'; then
    pass "workload and load test unchanged (same work per request, 120 requests @ concurrency 4, p95 <= 300 ms)"
  else
    fail "workload and load test unchanged"
  fi
  check "checkout-api rollout complete, all replicas ready" k rollout status deployment/checkout-api -n "$ns" --timeout="${RT}s"
  out=$(kj exec -n "$ns" deployment/loadgen -- python3 /app/loadtest.py)
  if printf '%s' "$out" | grep -q '"result": "PASS"'; then
    pass "fixed load test meets the objective"
  else
    fail "fixed load test meets the objective"
  fi
  detail "$(printf '%s' "$out" | tail -n 1)"
}

# A3 - single replica + PodDisruptionBudget blocks voluntary eviction.
verify_a3() {
  local ns=a3-maintenance desired pdb_sel min max job log
  desired=$(kj get deployment inventory-api -n "$ns" -o jsonpath='{.spec.replicas}')
  if [ -n "$desired" ] && [ "$desired" -ge 2 ]; then pass "inventory-api has redundancy (replicas: $desired)"; else fail "inventory-api has redundancy (replicas: ${desired:-?}, need at least 2)"; fi
  pdb_sel=$(kj get pdb inventory-api -n "$ns" -o jsonpath='{.spec.selector.matchLabels.app}')
  min=$(kj get pdb inventory-api -n "$ns" -o jsonpath='{.spec.minAvailable}')
  max=$(kj get pdb inventory-api -n "$ns" -o jsonpath='{.spec.maxUnavailable}')
  if [ "$pdb_sel" = "inventory-api" ] && { [ -n "$min" ] && [ "$min" != "0" ] && [ "$min" != "0%" ] || [ -n "$max" ]; }; then
    pass "PodDisruptionBudget still protects inventory-api (minAvailable=${min:-unset}, maxUnavailable=${max:-unset})"
  else
    fail "PodDisruptionBudget still protects inventory-api (deleted or minAvailable 0?)"
  fi
  check "inventory-api rollout complete, all replicas ready" k rollout status deployment/inventory-api -n "$ns" --timeout="${RT}s"
  job="verify-$(date +%s)"
  if k create job "$job" --from=cronjob/maintenance-check -n "$ns" >/dev/null 2>&1; then
    wait_job "$ns" "$job" 300
    log=$(kj logs "job/$job" -n "$ns")
    if printf '%s' "$log" | grep -q '^RESULT: PASS'; then pass "maintenance check: controlled eviction accepted with no failed requests"; else fail "maintenance check: controlled eviction accepted with no failed requests"; fi
    detail "$(printf '%s' "$log" | grep -E 'Eviction|Synthetic|RESULT')"
    k delete job "$job" -n "$ns" --wait=false >/dev/null 2>&1
  else
    fail "maintenance check job could be started (cronjob/maintenance-check missing?)"
  fi
  check "inventory-api back at its target replica count" k rollout status deployment/inventory-api -n "$ns" --timeout="${RT}s"
}

# A4 - workload identity federation subject mismatch.
verify_a4() {
  local ns=a4-config i status neg secrets wi
  # The app retries every 20s; allow time for the federated credential and role assignment to propagate.
  for i in 1 2 3 4 5 6 7 8 9; do
    status=$(svc_get "$ns" config-reader:http /status)
    printf '%s' "$status" | grep -q '"ok": true' && break
    [ "$i" -lt 9 ] && sleep 20
  done
  if printf '%s' "$status" | grep -q '"ok": true' && printf '%s' "$status" | grep -q '"value": "kubecon-ctf-a4: identity without secrets works"'; then
    pass "config-reader reads the lab value from Key Vault with workload identity"
  else
    fail "config-reader reads the lab value from Key Vault with workload identity"
    detail "$(printf '%s' "$status" | grep -E '"stage"|"detail"')"
  fi
  neg=$(svc_get "$ns" report-generator:http /status)
  if printf '%s' "$neg" | grep -q '"ok": false' && printf '%s' "$neg" | grep -q '"stage": "token-exchange"'; then
    pass "unrelated workload report-generator is still NOT authorized"
  else
    fail "unrelated workload report-generator is still NOT authorized"; detail "$(printf '%s' "$neg" | grep -E '"ok"|"stage"')"
  fi
  secrets=$(kj get secrets -n "$ns" -o name | grep -c . || true)
  expect "no stored credentials added to the namespace (Kubernetes Secrets)" "0" "${secrets:-0}"
  wi=$(kj get deployment config-reader -n "$ns" -o jsonpath='{.spec.template.metadata.labels.azure\.workload\.identity/use}')
  expect "config-reader still uses workload identity (pod label azure.workload.identity/use)" "true" "$wi"
}

# A5 - readiness probe that passes before the app can serve.
verify_a5() {
  local ns=a5-releases rp lp delay out
  rp=$(kj get deployment web -n "$ns" -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].readinessProbe.httpGet.path}')
  lp=$(kj get deployment web -n "$ns" -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].livenessProbe.httpGet.path}')
  delay=$(kj get deployment web -n "$ns" -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].readinessProbe.initialDelaySeconds}')
  expect "readiness probe uses the meaningful readiness endpoint" "/ready" "$rp"
  if [ "$lp" != "/ready" ]; then pass "liveness probe does not depend on readiness (path $lp)"; else fail "liveness probe does not depend on readiness (liveness uses /ready: restart loop risk)"; fi
  if [ "${delay:-0}" -le 10 ]; then pass "no long arbitrary readiness delay (initialDelaySeconds ${delay:-0})"; else fail "no long arbitrary readiness delay (initialDelaySeconds $delay)"; fi
  check "web rollout complete, all replicas ready" k rollout status deployment/web -n "$ns" --timeout="${RT}s"
  out=$(kj exec -n "$ns" deployment/rollout-tester -- python3 /app/rollout_test.py)
  if printf '%s' "$out" | grep -q '^RESULT: PASS'; then pass "controlled rollout under traffic with zero failed requests"; else fail "controlled rollout under traffic with zero failed requests"; fi
  detail "$(printf '%s' "$out" | grep -E '^(Rollout|Customer|RESULT)')"
}

# A6 - Deployment references the wrong PersistentVolumeClaim.
verify_a6() {
  local ns=a6-records claim phase records others
  claim=$(kj get deployment records-api -n "$ns" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')
  expect "records-api mounts the original claim" "records-data" "$claim"
  phase=$(kj get pvc records-data -n "$ns" -o jsonpath='{.status.phase}')
  expect "original PersistentVolumeClaim records-data still exists and is bound" "Bound" "$phase"
  check "records-api rollout complete, ready (includes disk attach)" k rollout status deployment/records-api -n "$ns" --timeout="${RT}s"
  records=$(svc_get "$ns" records-api:http /records)
  if printf '%s' "$records" | grep -q '"records": 500'; then pass "records-api serves the 500 seeded records"; else fail "records-api serves the 500 seeded records"; detail "${records:-no response}"; fi
  if printf '%s' "$records" | grep -q '"sha256": "aa451749a529f6202fb1f54e43d7f092419a70fb8f24d1d4121725bc4f4cc149"'; then
    pass "dataset checksum unchanged"
  else
    fail "dataset checksum unchanged"
  fi
  others=$(kj get pvc -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | tr ' ' '\n' | grep -v '^records-data$' | grep -v '^$' | tr '\n' ' ')
  if [ -n "$others" ]; then detail "note: extra claims in the namespace ($others) - an empty replacement volume is not a valid recovery"; fi
}
