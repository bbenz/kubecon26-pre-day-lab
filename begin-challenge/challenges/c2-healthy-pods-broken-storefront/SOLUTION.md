# C2 · Walkthrough to the end state (facilitators)

> Spoilers. Status text and gateway responses below were captured on AKS Automatic 1.35 (westus3) on 2026-10-14.

## 1. Reproduce from the outside

```bash
HOST=$(kubectl get httproute storefront -n c2-storefront -o jsonpath='{.spec.hostnames[0]}')
IP=$(kubectl get gateway store-gateway -n c2-storefront -o jsonpath='{.status.addresses[0].value}')
curl -i -H "Host: $HOST" "http://$IP/"
# HTTP/1.1 500 Internal Server Error
# server: istio-envoy          <- answered by the gateway (Envoy), not by the app; empty body
```

## 2. Prove the backend is healthy (go around the gateway)

```bash
kubectl get pods -n c2-storefront              # all Running / Ready
kubectl port-forward -n c2-storefront svc/store-front 8080:80
curl -s http://localhost:8080/ | grep -o '<title>.*</title>'   # <title>Contoso Pet Store</title>
```

The app works directly, so the failing hop is **gateway → route → Service**.

## 3. Read the route status – and the gateway's own log

```bash
kubectl describe httproute storefront -n c2-storefront
kubectl get httproute storefront -n c2-storefront -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
#   Accepted=True Route was valid
#   ResolvedRefs=True All references resolved          <- looks healthy!
```

The Istio-based controller accepts the route and reports its references as resolved: it checks that the
`store-front` Service exists, not that the *port* exists (the Gateway API spec would expect `ResolvedRefs=False`
here). The gateway's access log tells the real story:

```bash
kubectl logs -n c2-storefront deploy/store-gateway-approuting-istio --tail=3
# {... "response_code":500, "response_code_details":"cluster_not_found", "response_flags":"NC",
#      "route_name":"c2-storefront.storefront.0", "upstream_cluster":null ...}
```

`cluster_not_found` / `NC` (no cluster): the route matched (`route_name` = namespace.route.rule), but the
backend it points to doesn't exist in the gateway's configuration.

## 4. Compare the route with the Service

```bash
kubectl get httproute storefront -n c2-storefront -o jsonpath='{.spec.rules[0].backendRefs}{"\n"}'
#   [{"group":"","kind":"Service","name":"store-front","port":8080,"weight":1}]
kubectl get svc store-front -n c2-storefront -o jsonpath='{.spec.ports}{"\n"}'
#   [{"name":"http","port":80,"protocol":"TCP","targetPort":8080}]
kubectl get endpointslices -n c2-storefront -l kubernetes.io/service-name=store-front
```

The route targets port **8080** – the *container* port. The Service exposes port **80** (which forwards to
`targetPort` 8080). Routes always reference **Service ports**.

## 5. Fix the route (keep hostname and path)

```bash
kubectl patch httproute storefront -n c2-storefront --type json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":80}]'
```

## 6. Prove it

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $HOST" "http://$IP/"                 # 200
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: not-the-store.example" "http://$IP/"  # 404
scoring/verify.sh --challenges c2
```

## End state

Matches [`challenge-end-state/challenges/c2-healthy-pods-broken-storefront`](../../../challenge-end-state/challenges/c2-healthy-pods-broken-storefront/README.md):
`backendRefs[0].port: 80`, same hostname, same `PathPrefix /`, same gateway.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Change `store-front` to `type: LoadBalancer` | Bypasses the gateway and creates a new public endpoint – explicitly out of bounds. |
| Change the Service port to 8080 | Breaks every other client of the Service contract (store-front's own nginx config, other routes); the route was wrong, not the Service. |
| Remove `hostnames` from the route | "Fixes" the symptom but makes the route match every host – the negative test (other Host → 404) fails. |
| Delete and re-create the gateway | New load balancer/IP/DNS propagation during the round, and the routing error is still there. |

## Stretch objective – notes

Ingress `rules[].host` → `HTTPRoute.spec.hostnames`; `paths[].path/pathType` → `rules[].matches[].path`;
`backend.service.name/port.number` → `rules[].backendRefs[].name/port`; `ingressClassName` → the `Gateway`
(`gatewayClassName: approuting-istio`) the route attaches to via `parentRefs`. Cut over safely by running both
data planes side by side (separate IPs), validating the Gateway IP with a Host header, then switching DNS with a
low TTL (see the AKS "Migrate from Ingress-NGINX to Gateway API" guide; `ingress2gateway` can generate a first
draft).
