# C2 · Walkthrough to the end state (facilitators)

> Spoilers. Commands and output below were captured on AKS Automatic 1.36 (westus3) on 2026-11-03 with
> ingress2gateway 1.2.0; `ctf-store-eadae1` is that environment's label – yours differs.

## 1. Inventory and today's path

```bash
kubectl get ingress -A                                  # one Ingress: c2-storefront/storefront
kubectl get nginxingresscontrollers                     # default  webapprouting.kubernetes.azure.com  ...  True
kubectl get ingressclass,gatewayclass                   # webapprouting.kubernetes.azure.com / approuting-istio
STORE_HOST=$(kubectl get ingress storefront -n c2-storefront -o jsonpath='{.spec.rules[0].host}')
INGRESS_IP=$(kubectl get ingress storefront -n c2-storefront -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s --resolve "$STORE_HOST:80:$INGRESS_IP" "http://$STORE_HOST/" | grep -o '<title>.*</title>'
# <title>Contoso Pet Store</title>
nslookup "$STORE_HOST"                                  # NXDOMAIN - the public name is not published yet
```

The Ingress carries one NGINX-specific annotation, `nginx.ingress.kubernetes.io/proxy-read-timeout: "120"`.

## 2. Translate with ingress2gateway

```bash
ingress2gateway print --providers=ingress-nginx --namespace c2-storefront
# No resources found in c2-storefront namespace          <- the provider only reads class "nginx" by default
ingress2gateway print --providers=ingress-nginx --namespace c2-storefront \
  --ingress-nginx-ingress-class=webapprouting.kubernetes.azure.com > gateway-draft.yaml
```

The draft (warnings go to stderr):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    gateway.networking.k8s.io/generator: ingress2gateway-1.2.0
  name: webapprouting.kubernetes.azure.com
  namespace: c2-storefront
spec:
  gatewayClassName: webapprouting.kubernetes.azure.com
  listeners:
  - hostname: ctf-store-eadae1.westus3.cloudapp.azure.com
    name: ctf-store-eadae1-westus3-cloudapp-azure-com-http
    port: 80
    protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  annotations:
    gateway.networking.k8s.io/generator: ingress2gateway-1.2.0
  name: storefront-ctf-store-eadae1-westus3-cloudapp-azure-com
  namespace: c2-storefront
spec:
  hostnames:
  - ctf-store-eadae1.westus3.cloudapp.azure.com
  parentRefs:
  - name: webapprouting.kubernetes.azure.com
  rules:
  - backendRefs:
    - name: store-front
      port: 80
    matches:
    - path:
        type: PathPrefix
        value: /
    timeouts:
      request: 20m0s
```

Warnings: NGINX's self-signed HTTPS for the host is not translated; `proxy-read-timeout` got a "best-effort
translation" to `timeouts.request` (**20m0s** for 120 s – verify it); URL normalization isn't configurable in
Gateway API.

## 3. Adapt it (with an AI assistant) – and verify

What a good AI answer changes, and what the participant must check:

| Draft | Problem on AKS | Adapted |
|---|---|---|
| `gatewayClassName: webapprouting.kubernetes.azure.com` | That's the IngressClass. The draft applies, but no GatewayClass has that name, so no controller picks it up: `PROGRAMMED Unknown`, "Waiting for controller" (verified) | `approuting-istio` |
| Gateway `name: webapprouting.kubernetes.azure.com` | The controller creates Deployment **and Service** `<name>-approuting-istio`; a Service name can't contain dots, so the Gateway stays unprogrammed (below) | a DNS label, e.g. `store-gateway` |
| `parentRefs: [name: webapprouting.kubernetes.azure.com]` | Must follow the rename | `store-gateway` |
| `timeouts.request: 20m0s` | ingress2gateway's heuristic; the Ingress meant "wait up to 120 s for the backend" | `120s` (either value passes the scoring – the point is to decide, not to accept blindly) |

What participants see if they fix only the class and keep the dotted name (verified):

```bash
kubectl get gateway -n c2-storefront
# NAME                                 CLASS              ADDRESS   PROGRAMMED   AGE
# webapprouting.kubernetes.azure.com   approuting-istio             False        50s
kubectl describe gateway webapprouting.kubernetes.azure.com -n c2-storefront
#   Reason:   AddressNotUsable
#   Message:  Failed to assign to any requested addresses: hostname
#             "webapprouting.kubernetes.azure.com-approuting-istio.c2-storefront.svc.cluster.local" not found
```

The adapted manifests (`adapted.yaml`):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: store-gateway
  namespace: c2-storefront
spec:
  gatewayClassName: approuting-istio
  listeners:
  - hostname: ctf-store-eadae1.westus3.cloudapp.azure.com
    name: ctf-store-eadae1-westus3-cloudapp-azure-com-http
    port: 80
    protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: storefront-ctf-store-eadae1-westus3-cloudapp-azure-com
  namespace: c2-storefront
spec:
  hostnames:
  - ctf-store-eadae1.westus3.cloudapp.azure.com
  parentRefs:
  - name: store-gateway
  rules:
  - backendRefs:
    - name: store-front
      port: 80
    matches:
    - path:
        type: PathPrefix
        value: /
    timeouts:
      request: 120s
```

## 4. Apply and validate side by side

```bash
kubectl apply -f adapted.yaml
kubectl wait --for=condition=Programmed gateway/store-gateway -n c2-storefront --timeout=5m    # ~15 s
GW_IP=$(kubectl get gateway store-gateway -n c2-storefront -o jsonpath='{.status.addresses[0].value}')
curl -s --resolve "$STORE_HOST:80:$GW_IP" "http://$STORE_HOST/" | grep -o '<title>.*</title>'      # new path
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: not-the-store.example' "http://$GW_IP/"      # 404
curl -s --resolve "$STORE_HOST:80:$INGRESS_IP" "http://$STORE_HOST/" | grep -o '<title>.*</title>' # old path still up
kubectl get httproute -n c2-storefront -o jsonpath='{range .items[*].status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'
# Accepted=True
# ResolvedRefs=True
kubectl logs -n c2-storefront deploy/store-gateway-approuting-istio --tail=1
# {... "response_code":200, "response_code_details":"via_upstream",
#      "route_name":"c2-storefront.storefront-ctf-store-eadae1-westus3-cloudapp-azure-com.0",
#      "upstream_cluster":"outbound|80||store-front.c2-storefront.svc.cluster.local" ...}
```

The gateway has its own load balancer (`kubectl get svc -n c2-storefront` → `store-gateway-approuting-istio`,
`LoadBalancer`). At this point the scoring reports 6/9: everything except the cutover and the decommissioning.

## 5. Cut over: publish the public name on the gateway

```bash
LABEL=$(kubectl get namespace c2-storefront -o jsonpath='{.metadata.annotations.kubecon\.lab/storefront-dns-label}')
kubectl patch gateway store-gateway -n c2-storefront --type merge \
  -p "{\"spec\":{\"infrastructure\":{\"annotations\":{\"service.beta.kubernetes.io/azure-dns-label-name\":\"$LABEL\"}}}}"
kubectl get svc store-gateway-approuting-istio -n c2-storefront -o jsonpath='{.metadata.annotations}'   # label propagated
nslookup "$STORE_HOST" 8.8.8.8                          # -> $GW_IP after ~20 s
```

(Adding the same `infrastructure.annotations` block to `adapted.yaml` and re-applying works just as well.)
Measured: the public resolver answered with the gateway IP **18 s** after the patch; a workstation that had looked
the name up before the cutover kept its cached "does not exist" answer for about **5 minutes** (the zone's negative
caching TTL is 300 s). The positive answer's TTL is 10 s.

Then open `http://<storefront host name>/` in a browser.

## 6. Decommission the Ingress

```bash
kubectl delete ingress storefront -n c2-storefront
scoring/verify.sh --challenges c2           # PASSED 9/9
```

## End state

Matches [`challenge-end-state/challenges/c2-ingress-nginx-to-gateway-api`](../../../challenge-end-state/challenges/c2-ingress-nginx-to-gateway-api/README.md):
Gateway `store-gateway` (`approuting-istio`) with the DNS label, an HTTPRoute for the storefront host
(`PathPrefix /` → `store-front:80`), no Ingress. The reference manifests name the route `storefront` and the
listener `http`; the scoring accepts any names.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Change `store-front` to `type: LoadBalancer` with the DNS label | Bypasses the gateway; an extra public endpoint (scoring: only `*-approuting-istio` LoadBalancers allowed). |
| Move the DNS label to NGINX's shared Service | Not a migration – and that Service is managed by the add-on (`app-routing-system`). |
| Delete the Ingress first, then build the gateway | Big-bang outage; the side-by-side checks are the point of the exercise. |
| Leave the Ingress in place | Ingress-NGINX still serves the host – the decommissioning check fails. |
| Apply the draft unchanged | It applies, but no GatewayClass `webapprouting.kubernetes.azure.com` exists – nothing gets programmed. |

## Stretch objectives – notes

* **Field mapping:** `Ingress.spec.ingressClassName` → the `Gateway` (`gatewayClassName`); `rules[].host` →
  `Gateway` listener `hostname` and `HTTPRoute.spec.hostnames`; `paths[].path/pathType` → `rules[].matches[].path`;
  `backend.service.name/port.number` → `rules[].backendRefs[].name/port`; NGINX annotations → route features such as
  `timeouts` (or implementation-specific policies) – some don't translate at all.
* **Why a dedicated IP:** the add-on's Gateway API implementation deploys an Envoy data plane per Gateway, in the
  Gateway's namespace, with its own `LoadBalancer` Service. Team-owned gateways vs. one shared NGINX is a design
  choice Gateway API makes explicit (role separation: infrastructure provider → GatewayClass, cluster operator →
  Gateway, app team → HTTPRoute).
* **Production follow-up:** when no Ingress uses the add-on's NGINX any more:
  `az aks approuting update -g <rg> -n <cluster> --nginx None`, then delete the `NginxIngressController` resources
  (see the AKS "Migrate from Ingress-NGINX to Gateway API" guide). Cluster-wide – not part of the lab.
