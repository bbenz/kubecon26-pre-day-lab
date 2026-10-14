#!/usr/bin/env bash
# shellcheck shell=bash
# Success-criteria checks for the core challenges C1-C4 (sourced by scoring/verify.sh).

# C1 - order-service crash after a configuration rollout.
verify_c1() {
  local ns=c1-store addr override before after ready q1 q2 out
  addr=$(kj get configmap order-service-configs -n "$ns" -o jsonpath='{.data.FASTIFY_ADDRESS}')
  # A bind host (0.0.0.0 / ::) or unset (fastify-cli then listens on all interfaces) are both valid.
  if ! printf '%s' "$addr" | grep -Eq ':[0-9]+$'; then
    pass "authoritative config fixed: FASTIFY_ADDRESS in ConfigMap order-service-configs is a bind host or unset ('$addr')"
  else
    fail "authoritative config fixed: FASTIFY_ADDRESS in ConfigMap order-service-configs is a bind host or unset"
    detail "current value: '$addr' (a host only - the port is FASTIFY_PORT)"
  fi
  override=$(kj get deployment order-service -n "$ns" -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FASTIFY_ADDRESS")].value}')
  expect "no temporary override of FASTIFY_ADDRESS on the Deployment (fix lives in the ConfigMap)" "" "$override"
  check "order-service rollout complete, all replicas ready" k rollout status deployment/order-service -n "$ns" --timeout="${RT}s"
  before=$(restarts "$ns" app=order-service)
  sleep "$OBSERVE_SECONDS"
  after=$(restarts "$ns" app=order-service)
  ready=$(kj get deployment order-service -n "$ns" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
  if [ "$before" = "$after" ] && [ "${ready%/*}" = "${ready#*/}" ]; then
    pass "stable for ${OBSERVE_SECONDS}s: restart count unchanged ($after), $ready ready"
  else
    fail "stable for ${OBSERVE_SECONDS}s: restart count $before -> $after, ready $ready"
  fi
  q1=$(kj exec -n "$ns" rabbitmq-0 -- rabbitmqctl list_queues name messages | awk '$1=="orders"{print $2}')
  # A customer order through the storefront's API path (store-front nginx -> order-service).
  if out=$(k exec -n "$ns" deployment/store-front -- wget -q -O /dev/null --header 'Content-Type: application/json' \
      --post-data '{"customerId":"ctf-verify","items":[{"productId":1,"quantity":1,"price":9.99}]}' \
      http://localhost:8080/api/orders 2>&1); then
    pass "synthetic order accepted (POST /api/orders through the storefront)"
  else
    fail "synthetic order accepted (POST /api/orders through the storefront)"; detail "$out"
  fi
  sleep 3
  q2=$(kj exec -n "$ns" rabbitmq-0 -- rabbitmqctl list_queues name messages | awk '$1=="orders"{print $2}')
  if [ "${q2:-0}" -gt "${q1:-0}" ] 2>/dev/null; then
    pass "order reached the RabbitMQ 'orders' queue (${q1:-0} -> $q2 messages)"
  else
    fail "order reached the RabbitMQ 'orders' queue (${q1:-0} -> ${q2:-0} messages)"
  fi
}

# C2 - HTTPRoute backend port.
verify_c2() {
  local ns=c2-storefront want host backend path accepted resolved ip code code2 lbs page
  want=$(kj get gateway store-gateway -n "$ns" -o jsonpath='{.metadata.annotations.kubecon\.lab/storefront-hostname}')
  host=$(kj get httproute storefront -n "$ns" -o jsonpath='{.spec.hostnames[*]}')
  expect "route keeps the intended hostname" "$want" "$host"
  backend=$(kj get httproute storefront -n "$ns" -o jsonpath='{.spec.rules[*].backendRefs[*].name}')
  path=$(kj get httproute storefront -n "$ns" -o jsonpath='{.spec.rules[*].matches[*].path.type}:{.spec.rules[*].matches[*].path.value}')
  expect "route still sends PathPrefix / to the store-front Service" "store-front PathPrefix:/" "$backend $path"
  accepted=$(kj get httproute storefront -n "$ns" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')
  resolved=$(kj get httproute storefront -n "$ns" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')
  expect "HTTPRoute status: Accepted / ResolvedRefs" "True/True" "$accepted/$resolved"
  ip=$(kj get gateway store-gateway -n "$ns" -o jsonpath='{.status.addresses[0].value}')
  if [ -z "$ip" ]; then
    fail "gateway store-gateway has a public address"
  elif ! command -v curl >/dev/null 2>&1; then
    fail "curl is required to test the gateway"
  else
    page=$(mktemp)
    code=$(curl -s -o "$(npath "$page")" -w '%{http_code}' -m 15 -H "Host: $want" "http://$ip/")
    if [ "$code" = "200" ] && grep -q 'Contoso Pet Store' "$page"; then
      pass "storefront served through the gateway: http://$want/ -> HTTP $code"
    else
      fail "storefront served through the gateway: http://$want/ -> HTTP $code (gateway $ip)"
    fi
    rm -f "$page"
    code2=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H "Host: not-the-store.example" "http://$ip/")
    expect "requests that do not match the route are not sent to the store (HTTP status)" "404" "$code2"
  fi
  expect "store-front is not exposed directly (Service type)" "ClusterIP" "$(kj get service store-front -n "$ns" -o jsonpath='{.spec.type}')"
  lbs=$(kj get services -n "$ns" -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{" "}{end}')
  if ! printf '%s' "$lbs" | tr ' ' '\n' | grep -v '^store-gateway' | grep -q .; then
    pass "no extra public endpoints in the namespace (LoadBalancer services: ${lbs:-none})"
  else
    fail "no extra public endpoints in the namespace (LoadBalancer services: $lbs)"
  fi
}

# C3 - node auto-provisioning NodePool constraints.
verify_c3() {
  local ns=c3-processing arch skus sku arm="" label taint limit sel log node pool
  arch=$(kj get nodepool c3-processing -o jsonpath='{.spec.template.spec.requirements[?(@.key=="kubernetes.io/arch")].values[*]}')
  expect "NodePool keeps the required architecture" "amd64" "$arch"
  skus=$(kj get nodepool c3-processing -o jsonpath='{.spec.template.spec.requirements[?(@.key=="karpenter.azure.com/sku-name")].values[*]}')
  for sku in $skus; do
    printf '%s' "$sku" | grep -Eq '^Standard_[A-Za-z]+[0-9]+[a-z]*p[a-z]*_v[0-9]+$' && arm="$arm $sku"
  done
  if [ -z "$arm" ]; then
    pass "approved instance types are compatible with amd64 (${skus:-no sku-name restriction})"
  else
    fail "approved instance types are compatible with amd64"; detail "Arm64 SKUs still listed:$arm"
  fi
  label=$(kj get nodepool c3-processing -o jsonpath='{.spec.template.metadata.labels.kubecon\.lab/pool}')
  taint=$(kj get nodepool c3-processing -o jsonpath='{.spec.template.spec.taints[?(@.key=="kubecon.lab/pool")].effect}')
  expect "pool isolation intact (node label / NoSchedule taint)" "processing/NoSchedule" "$label/$taint"
  limit=$(kj get nodepool c3-processing -o jsonpath='{.spec.limits.cpu}')
  if [ -n "$limit" ]; then pass "pool CPU limit still set ($limit)"; else fail "pool CPU limit still set"; fi
  sel=$(kj get job order-batch -n "$ns" -o jsonpath='{.spec.template.spec.nodeSelector.kubecon\.lab/pool}/{.spec.template.spec.nodeSelector.kubernetes\.io/arch}')
  expect "order-batch keeps its placement requirements (pool/arch)" "processing/amd64" "$sel"
  # Node provisioning can take a few minutes; do not wait long while the fault is obviously still present.
  if wait_job "$ns" order-batch "$([ -n "$arm" ] && echo 30 || echo "$LONG_WAIT")"; then
    pass "order-batch Job completed"
  else
    fail "order-batch Job completed (waited ${LONG_WAIT}s for a node from NAP)"
    detail "$(kj get events -n "$ns" --field-selector reason=FailedScheduling -o jsonpath='{.items[-1:].message}')"
  fi
  log=$(kj logs job/order-batch -n "$ns" --tail=3)
  if printf '%s' "$log" | grep -q 'BATCH COMPLETE.*arch x86_64'; then
    pass "batch ran on an amd64 node"
  else
    fail "batch ran on an amd64 node"
  fi
  node=$(kj get pods -n "$ns" -l app=order-batch --field-selector=status.phase=Succeeded -o jsonpath='{.items[0].spec.nodeName}')
  if [ -n "$node" ]; then
    pool=$(kj get node "$node" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}')
    if [ -n "$pool" ]; then
      expect "batch ran on capacity from the dedicated NodePool (node $node)" "c3-processing" "$pool"
    else
      detail "node $node has already been consolidated away - placement checked via the pod's nodeSelector"
    fi
  fi
}

# C4 - AI dependency: model deployment name.
verify_c4() {
  local ns=c4-assistant use_ad keys out i
  use_ad=$(kj get configmap ai-service-configs -n "$ns" -o jsonpath='{.data.USE_AZURE_AD}')
  keys=$(kj get configmap ai-service-configs -n "$ns" -o jsonpath='{.data.AZURE_OPENAI_API_KEY}{.data.OPENAI_API_KEY}')
  keys="$keys$(kj get deployment ai-service -n "$ns" -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="AZURE_OPENAI_API_KEY")].value}{.spec.template.spec.containers[*].env[?(@.name=="OPENAI_API_KEY")].value}')"
  if [ "$(printf '%s' "$use_ad" | tr '[:upper:]' '[:lower:]')" = "true" ] && [ -z "$keys" ]; then
    pass "ai-service still authenticates with Microsoft Entra ID (no API keys configured)"
  else
    fail "ai-service still authenticates with Microsoft Entra ID (USE_AZURE_AD=$use_ad, API key configured: $([ -n "$keys" ] && echo yes || echo no))"
  fi
  check "ai-service rollout complete, all replicas ready" k rollout status deployment/ai-service -n "$ns" --timeout="${RT}s"
  # The same call the store admin's "Ask AI Assistant" button makes:
  # store-admin nginx -> product-service -> ai-service -> Foundry model deployment.
  # Retries cover role-assignment propagation right after a fresh deployment.
  for i in 1 2 3 4; do
    if out=$(k exec -n "$ns" deployment/store-admin -- wget -q -O - --header 'Content-Type: application/json' \
        --post-data '{"name":"Contoso Catnip Kicker","tags":["toy","cat"]}' \
        http://localhost:8081/api/ai/generate/description 2>&1) && printf '%s' "$out" | grep -q '"description"'; then
      break
    fi
    [ "$i" -lt 4 ] && sleep 20
  done
  if printf '%s' "$out" | grep -q '"description"'; then
    pass "synthetic request store-admin -> product-service -> ai-service -> model deployment returns a description"
  else
    fail "synthetic request store-admin -> product-service -> ai-service -> model deployment returns a description"
    detail "$out"
    detail "$(kj logs deployment/ai-service -n "$ns" --tail=50 | grep -iE 'error|exception' | tail -n 2)"
  fi
  out=$(kj logs deployment/ai-service -n "$ns" --tail=200 | grep 'Using Azure OpenAI' | tail -n 1)
  if [ -n "$out" ]; then detail "dependency evidence (ai-service log): $out"; fi
}
