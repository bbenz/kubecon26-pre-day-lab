# C1 · Walkthrough to the end state (facilitators)

> Spoilers. Use this to rehearse the round and to demo the solution in the debrief.

## 1. Find the failing component

```bash
kubectl get pods -n c1-store
```

```text
NAME                               READY   STATUS             RESTARTS      AGE
order-service-79d7f6cc7c-qh5v2     0/1     CrashLoopBackOff   4 (30s ago)   2m
product-service-6566d8b567-v2xxl   1/1     Running            0             2m
rabbitmq-0                         1/1     Running            0             2m
store-front-87f8c64f8-r85gj        1/1     Running            0             2m
```

`kubectl describe pod -n c1-store -l app=order-service` → Events show `Back-off restarting failed container`.
The store UI still loads (store-front is healthy) but placing an order fails.

## 2. Read the previous container's logs

```bash
kubectl logs -n c1-store deploy/order-service --previous
```

```text
connected to RabbitMQ at rabbitmq:5672, queue "orders" declared
{"level":50,...,"msg":"getaddrinfo ENOTFOUND 0.0.0.0:3000"}
...
npm notice New minor version of npm available! ...
```

The service connects to RabbitMQ, then fails to **bind its HTTP listener**: it is trying to resolve a host
literally called `0.0.0.0:3000`.

## 3. Trace the setting to its source

```bash
kubectl describe deployment order-service -n c1-store | grep -A3 "Environment Variables from"
kubectl get configmap order-service-configs -n c1-store -o yaml
```

```yaml
data:
  FASTIFY_ADDRESS: "0.0.0.0:3000"     # host and port in a host-only setting
  ORDER_QUEUE_HOSTNAME: rabbitmq
  ...
metadata:
  annotations:
    kubecon.lab/change-ticket: CHG-1109 - bind order-service explicitly to port 3000
```

`FASTIFY_ADDRESS` is the **bind host**; the port is a separate setting (`FASTIFY_PORT`, default 3000). The
change ticket's intent ("bind explicitly to port 3000") was implemented in the wrong field.

## 4. Fix the authoritative configuration and roll out

```bash
kubectl patch configmap order-service-configs -n c1-store --type merge \
  -p '{"data":{"FASTIFY_ADDRESS":"0.0.0.0","FASTIFY_PORT":"3000"}}'
kubectl rollout restart deployment/order-service -n c1-store
kubectl rollout status deployment/order-service -n c1-store
```

(`kubectl edit configmap order-service-configs -n c1-store` works just as well.)

## 5. Prove it

```bash
kubectl get pods -n c1-store -w            # watch for ~60s: RESTARTS must not increase
kubectl exec -n c1-store deploy/store-front -- wget -q -O /dev/null \
  --header 'Content-Type: application/json' \
  --post-data '{"customerId":"demo","items":[{"productId":1,"quantity":1,"price":9.99}]}' \
  http://localhost:8080/api/orders && echo "order accepted"
kubectl exec -n c1-store rabbitmq-0 -- rabbitmqctl list_queues name messages
scoring/verify.sh --challenges c1
```

## End state

Matches [`challenge-end-state/challenges/c1-the-store-wont-start`](../../../challenge-end-state/challenges/c1-the-store-wont-start/README.md):
`FASTIFY_ADDRESS: "0.0.0.0"` (+ `FASTIFY_PORT: "3000"`) in the ConfigMap and a new rollout of `order-service`.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| `kubectl delete pod ...` / restart only | The pod reads the same broken ConfigMap again – the stretch-objective answer. |
| `kubectl set env deployment/order-service FASTIFY_ADDRESS=0.0.0.0` | Works until the next deployment re-applies the Deployment manifest; the authoritative source is still wrong. Scoring checks for the override. |
| `kubectl rollout undo` | Reverts the pod template, not the ConfigMap – the crash continues. |
| Removing `FASTIFY_ADDRESS` from the ConfigMap | **Accepted.** fastify-cli then listens on all interfaces (verified on containerd), and the fix still lives in the authoritative source. Setting it explicitly to `0.0.0.0` documents the intent better. |

## Stretch objective – model answer

Restarting re-creates the container with the same environment from the same ConfigMap, so it fails the same
way. A pre-deployment check could validate settings against a schema (e.g. `@fastify/env` / JSON Schema),
run `kubectl apply --dry-run=server` plus a policy (Gatekeeper/Kyverno) that rejects `host:port` in
`FASTIFY_ADDRESS`, or smoke-test the new revision (readiness gate / canary) before it receives traffic.
