# C2 · Healthy pods, broken storefront

| | |
|---|---|
| **Round** | Proposed core, round 2 · Intermediate |
| **Namespace** | `c2-storefront` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | AKS Automatic with the application routing add-on's **Gateway API** implementation (GatewayClass `approuting-istio`) and a public Azure Load Balancer IP with a DNS name |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> The storefront stopped serving requests after a traffic-routing change (the move from Ingress-NGINX to the
> Kubernetes Gateway API). The application team reports that its pods are healthy.
> Restore the storefront at its public address **through the gateway**.

## Learning objective

Trace a request from the gateway through routing and Services; distinguish a routing failure from backend
health.

## What's running

* AKS Store demo: `store-front`, `product-service`, `order-service`, `rabbitmq` (all `ClusterIP` Services).
* Gateway `store-gateway` (class `approuting-istio`) with a public IP and DNS name
  `ctf-store-<id>.<region>.cloudapp.azure.com`, and HTTPRoute `storefront`.

```bash
kubectl get gateway,httproute,svc,pods -n c2-storefront
kubectl get httproute storefront -n c2-storefront -o jsonpath='{.spec.hostnames[0]}{"\n"}'   # the storefront URL host
```

Open `http://<that hostname>/` in a browser (the deploy script also prints it). If your DNS is slow to
resolve the name, use the gateway IP with a Host header:
`curl -i -H "Host: <hostname>" http://<gateway-ip>/`.

## Success criteria

1. The HTTPRoute is **accepted** and its references **resolve** (route status conditions).
2. `http://<hostname>/` through the gateway returns the storefront (HTTP 200, "Contoso Pet Store").
3. A request that does **not** match the route (another Host name) is **not** sent to the store (404).
4. The intended hostname and path are preserved, and the backend is **not** exposed some other way (no new
   public Service, no bypass of the gateway).

```bash
scoring/verify.sh --challenges c2          # bash
./scoring/verify.ps1 -Challenges c2        # PowerShell
```

## Hints

<details><summary>Hint 1 – Separate backend health from external access</summary>

Does the app work when you go *around* the gateway?
`kubectl port-forward -n c2-storefront svc/store-front 8080:80` → `http://localhost:8080`.
</details>

<details><summary>Hint 2 – Inspect route status and conditions</summary>

`kubectl describe httproute storefront -n c2-storefront` – read `Status → Parents → Conditions`
(`Accepted`, `ResolvedRefs`). Also look at `kubectl get gateway store-gateway -n c2-storefront`.
Careful: a route can be *accepted* with all references *resolved* and still send traffic nowhere – the
conditions don't check every detail of the backend.
</details>

<details><summary>Hint 3 – Ask the gateway what happened to your request</summary>

The gateway runs as pods in your namespace and writes a JSON access log line per request:
`kubectl logs -n c2-storefront deploy/store-gateway-approuting-istio --tail=5`. Look at `response_code`,
`response_code_details`, `route_name` and `upstream_cluster`.
</details>

<details><summary>Hint 4 – Compare the route's backend port with the Service port</summary>

A route's `backendRefs[].port` refers to a port **of the Service**, not the container port.
`kubectl get svc store-front -n c2-storefront -o wide` and `kubectl get endpointslices -n c2-storefront -l kubernetes.io/service-name=store-front`.
</details>

## What doesn't count

* Changing `store-front` to a `LoadBalancer`/`NodePort` Service or port-forwarding as the "fix".
* Deleting/re-creating the gateway (new load balancer and IP) or removing the route's hostname so it matches
  everything.

## Stretch objective

Design (or perform) a bounded Ingress-NGINX → Gateway API cutover with both data planes installed: validate the
new route before switching the client. Which fields of an `Ingress` map to `Gateway`/`HTTPRoute`?

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c c2
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c2
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High – validated on Azure (2026-10-14).** The application routing add-on's Istio-based Gateway API implementation and the managed Gateway API CRDs are GA (AKS release 2026-04-28). They are on by default only for AKS Automatic **1.36+**; the default version is currently 1.35, so all three deployments enable them explicitly (`--enable-gateway-api --enable-app-routing-istio` / `ingressProfile` in Terraform). The gateway gets its public IP and DNS name from `spec.infrastructure.annotations`. The fault (backendRef port 8080 vs Service port 80) is deterministic and never self-heals: the gateway answers **HTTP 500** (`server: istio-envoy`, empty body); another Host gets 404. |
| **Validation status** | Begin state, fix and end state validated on AKS Automatic 1.35 (westus3) with PowerShell, bash and Terraform deployments. **Observed:** the Istio controller reports the broken route as `Accepted=True` **and `ResolvedRefs=True`** ("All references resolved") – it does not validate the Service *port*. The evidence is in the gateway's access log: `"response_code":500, "response_code_details":"cluster_not_found", "response_flags":"NC", "route_name":"c2-storefront.storefront.0"`. |
| **Fit for 200-level users** | Medium. The troubleshooting idea ("pods healthy, path broken") is accessible, but Gateway API vocabulary (Gateway, HTTPRoute, backendRef, parent conditions) is new to many, and the healthy-looking route status is a trap. Hints 3 (gateway access log → `cluster_not_found`) and 4 (Service port vs container port) make it solvable; the port insight is a classic and very transferable. |
| **Expected time** | 15–25 min; release hint 3 at ~10 minutes if a group is stuck on the route status. |
| **Risks** | Gateway/LB/DNS provisioning happens at deploy time (not in the round), but a reset re-creates the gateway with a **new public IP** (the DNS name follows; allow a minute for DNS). Topical: Ingress-NGINX retirement makes this very relevant to the KubeCon audience. |
| **Opinion** | **Keep as round 2.** High audience value; the stretch migration exercise is a good "fast finisher" task. |
