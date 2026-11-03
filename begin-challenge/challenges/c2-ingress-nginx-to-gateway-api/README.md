# C2 · Move the storefront to Gateway API

| | |
|---|---|
| **Round** | Proposed core, round 2 · Intermediate |
| **Namespace** | `c2-storefront` |
| **Investigation time (design target)** | 25–30 minutes |
| **Azure services** | AKS Automatic with the **application routing add-on**: managed NGINX (IngressClass `webapprouting.kubernetes.azure.com`) and the add-on's Istio-based **Gateway API** implementation (GatewayClass `approuting-istio`); Azure Load Balancer public IPs with an Azure-provided DNS name |
| **Tools** | `kubectl`, `curl`, [`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway) (the Kubernetes SIG Network migration tool), an AI assistant of your choice |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> The storefront is published through **Ingress-NGINX** – the managed NGINX of the AKS application routing
> add-on. The upstream Ingress-NGINX project is retired, and Microsoft-supported security patches for the
> add-on's NGINX end in **November 2026**. Platform engineering has already enabled the add-on's **Gateway API**
> implementation on this cluster.
>
> Move the storefront to Gateway API **without a big-bang outage**: translate the existing Ingress with
> `ingress2gateway`, have an AI assistant adapt the draft for AKS (and check its work), validate the new path
> side by side with the old one, then cut the public name over to the gateway and decommission the Ingress.
>
> The storefront's public name, `ctf-store-<id>.<region>.cloudapp.azure.com`, is reserved for the go-live: it
> starts resolving when you publish it on the gateway.

## Learning objective

Run an Ingress → Gateway API migration on AKS end to end: inventory, automated translation, AI-assisted (and
human-verified) adaptation, side-by-side validation, DNS cutover and decommissioning.

## What's running

* AKS Store demo: `store-front`, `product-service`, `order-service`, `rabbitmq` (all `ClusterIP` Services).
* Ingress `storefront` (class `webapprouting.kubernetes.azure.com`) for the storefront's host name, served by the
  add-on's shared NGINX controller (Service `nginx` in `app-routing-system`: one public IP for every Ingress).
* GatewayClass `approuting-istio` – ready to use; no Gateway exists yet.

```bash
kubectl get ingress,svc,pods -n c2-storefront
kubectl get ingressclass,gatewayclass
STORE_HOST=$(kubectl get ingress storefront -n c2-storefront -o jsonpath='{.spec.rules[0].host}')
INGRESS_IP=$(kubectl get ingress storefront -n c2-storefront -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s --resolve "$STORE_HOST:80:$INGRESS_IP" "http://$STORE_HOST/" | grep -o '<title>.*</title>'   # today: via NGINX
```

```powershell
$STORE_HOST = kubectl get ingress storefront -n c2-storefront -o jsonpath='{.spec.rules[0].host}'
$INGRESS_IP = kubectl get ingress storefront -n c2-storefront -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
curl.exe -s --resolve "${STORE_HOST}:80:${INGRESS_IP}" "http://$STORE_HOST/" | Select-String '<title>'
```

`--resolve` sends a request for the real host name to an IP you choose – the usual way to test a front door
before DNS points at it. **Don't browse to the name before the cutover**: a "name does not exist" answer can be
cached for up to 5 minutes.

### How public names work here

Azure creates `<label>.<region>.cloudapp.azure.com` for a load balancer's public IP when the Kubernetes Service
behind it has the annotation `service.beta.kubernetes.io/azure-dns-label-name: <label>`. A Gateway passes
annotations to the Service it generates through `spec.infrastructure.annotations`. The storefront's label:

```bash
kubectl get namespace c2-storefront -o jsonpath='{.metadata.annotations.kubecon\.lab/storefront-dns-label}{"\n"}'
```

### Your tools

**ingress2gateway** translates Ingress resources (and ingress-nginx annotations) into Gateway API resources. It
reads from your current kubectl context or from a file and prints the result – it never changes the cluster.

```bash
# Linux / Azure Cloud Shell
curl -sSL https://github.com/kubernetes-sigs/ingress2gateway/releases/download/v1.2.0/ingress2gateway_Linux_x86_64.tar.gz | tar -xz ingress2gateway
./ingress2gateway version
# macOS
brew install ingress2gateway
```

```powershell
# Windows
Invoke-WebRequest https://github.com/kubernetes-sigs/ingress2gateway/releases/download/v1.2.0/ingress2gateway_Windows_x86_64.zip -OutFile ingress2gateway.zip
Expand-Archive ingress2gateway.zip -DestinationPath ingress2gateway; .\ingress2gateway\ingress2gateway.exe version
```

**An AI assistant** – GitHub Copilot (Chat in VS Code or the Copilot CLI; the Free plan is enough), Copilot in
Azure (the Copilot button in the Azure portal), or any assistant you use. A starting prompt:

> I'm migrating an app on AKS from the application routing add-on's managed NGINX (Ingress) to Gateway API with
> the add-on's Istio-based implementation, GatewayClass `approuting-istio`. Below are the existing Ingress and
> the draft ingress2gateway produced, including its warnings. Adapt the draft so it works on this cluster. Keep
> the host name, path and backend unchanged and don't add TLS. Explain every change and anything I should
> double-check before applying it.
>
> *(paste the Ingress YAML, the ingress2gateway output and its warnings)*

**AI drafts, you verify.** Before you apply anything, check the GatewayClass, the Gateway's name (it becomes
part of the generated Deployment and Service names), that the HTTPRoute's `parentRefs` point at your Gateway, that
host name, path, backend Service and port match the Ingress, and the request timeout ingress2gateway derived from
the `proxy-read-timeout` annotation.

## Success criteria

1. A Gateway of class `approuting-istio` in `c2-storefront` is **programmed** with a public IP, and an HTTPRoute
   attached to it serves the storefront's host name (`PathPrefix /` → Service `store-front` port 80) – route
   status **Accepted**, references **resolved**.
2. **Cutover:** `http://<storefront host name>/` resolves to the gateway and returns the storefront (HTTP 200,
   "Contoso Pet Store"); other host names get 404 from the gateway.
3. **Decommissioned:** no Ingress is left in `c2-storefront`; `store-front` is still `ClusterIP` and the gateway is
   the namespace's only public endpoint.

```bash
scoring/verify.sh --challenges c2          # bash
./scoring/verify.ps1 -Challenges c2        # PowerShell
```

## Hints

<details><summary>Hint 1 – ingress2gateway says "No resources found"</summary>

Its ingress-nginx provider only reads Ingresses of class `nginx` unless you tell it otherwise. Which class does
the storefront's Ingress use? Look at `ingress2gateway print --help` for an ingress-class flag, and use
`--providers=ingress-nginx --namespace c2-storefront`. (Offline alternative:
`kubectl get ingress storefront -n c2-storefront -o yaml > ingress.yaml` and `--input-file ingress.yaml`.)
</details>

<details><summary>Hint 2 – The Gateway never becomes programmed</summary>

`kubectl get gateway -n c2-storefront` – look at `CLASS` and `PROGRAMMED`. The draft reuses the IngressClass
name as the GatewayClass (`kubectl get gatewayclass`); on AKS the Gateway API implementation is
`approuting-istio`. Give the Gateway a short name that is a valid DNS label, such as `store-gateway`: the
gateway's Deployment and Service are called `<gateway-name>-approuting-istio`. Point the HTTPRoute's `parentRefs`
at that name. `kubectl describe gateway <name> -n c2-storefront` shows why a Gateway isn't programmed.
</details>

<details><summary>Hint 3 – Validate side by side, before any DNS change</summary>

```bash
kubectl wait --for=condition=Programmed gateway/<name> -n c2-storefront --timeout=5m
GW_IP=$(kubectl get gateway <name> -n c2-storefront -o jsonpath='{.status.addresses[0].value}')
curl -s --resolve "$STORE_HOST:80:$GW_IP" "http://$STORE_HOST/" | grep -o '<title>.*</title>'      # the storefront
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: not-the-store.example' "http://$GW_IP/"      # 404
kubectl describe httproute -n c2-storefront                                    # Accepted / ResolvedRefs
kubectl logs -n c2-storefront deploy/<name>-approuting-istio --tail=5          # the gateway's access log
```

The old path through NGINX keeps working the whole time – nothing has changed for customers yet.
</details>

<details><summary>Hint 4 – Cut over, then decommission</summary>

Publish the name on the gateway (see *How public names work here*): add `spec.infrastructure.annotations` with
`service.beta.kubernetes.io/azure-dns-label-name: <label>` to your Gateway and re-apply it. Within a minute or
so `nslookup <storefront host name>` returns the gateway's IP. Open `http://<storefront host name>/` in a
browser – then delete the Ingress.
</details>

## What doesn't count

* Exposing `store-front` as a `LoadBalancer`/`NodePort` Service, or port-forwarding.
* Leaving the Ingress in place – or deleting it before the gateway serves the storefront (big-bang).
* Publishing the storefront under a different host name.

## Stretch objectives

* Map the Ingress fields to Gateway API: which part of the `Ingress` became the `Gateway`, which the `HTTPRoute`?
  What did the `proxy-read-timeout` annotation turn into, and is that equivalent?
* Why does the gateway get its own load balancer IP while NGINX served every Ingress from one shared IP?
* Production follow-up: once no Ingress uses the add-on's NGINX, it is turned off with
  `az aks approuting update -g <resource-group> -n <cluster> --nginx None`. That is cluster-wide – **don't** do it
  in the lab.

## Troubleshooting

* **curl works but the browser doesn't** – type the full `http://` URL (browsers may try HTTPS first; the
  gateway only listens on port 80), use a private window (cached error pages or DNS answers), and check whether a
  VPN or corporate proxy blocks `*.cloudapp.azure.com`.
* **The name doesn't resolve after the cutover** – give it a minute. `kubectl get svc -n c2-storefront` should show
  the gateway's Service with your label annotation; `kubectl describe svc <name>-approuting-istio -n c2-storefront`
  shows load-balancer events (for example a label already in use). If you looked the name up before the cutover,
  your resolver may cache "does not exist" for up to 5 minutes: compare with `nslookup <host> 8.8.8.8`.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c c2
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c2
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High.** Everything is managed by AKS: the application routing add-on's NGINX (still enabled by `--enable-app-routing` / `az aks approuting enable`) and its Istio-based Gateway API implementation (GatewayClass `approuting-istio`, GA) run side by side, each with its own public IP – exactly the side-by-side pattern of the AKS "Migrate from Ingress-NGINX to Gateway API" guide. `ingress2gateway` v1.2.0 (ingress-nginx provider) translates the Ingress and its annotation; three adaptations are needed: the ingress-class flag, GatewayClass `approuting-istio` and a DNS-label-safe Gateway name. The cutover is a single annotation (`spec.infrastructure.annotations`); Azure's DNS answers have a 10-second TTL. |
| **Validation status** | See [docs/testing.md](../../../docs/testing.md) for the Azure walkthrough (translation, adaptation, side-by-side test, DNS cutover, decommissioning) and the end-state deployment. |
| **Fit for 200-level users** | Good. A guided, realistic workflow instead of a hidden fault; the tool's three gaps make the "AI drafts, you verify" lesson concrete without being obscure. Gateway API vocabulary is new to many – the hints name each object. Very topical for KubeCon (Ingress-NGINX retirement) and it shows off AKS features (application routing, managed Gateway API) rather than only kubectl. |
| **Expected time** | 25–30 min: tool install 2–3 min (pre-install it on lab VMs), translate and adapt ~10 min, gateway provisioning 1–3 min (a new NAP node can add 1–3 min), validation and cutover ~5 min. |
| **Risks** | (1) **NGINX support window:** Microsoft-supported patches for the add-on's NGINX end in November 2026 – the month of the event. Re-check before the event that `--enable-app-routing` still deploys NGINX on new clusters; fallback: keep the Ingress (it is just YAML) and translate it offline with `--input-file`, dropping the "today's path" test. (2) Participants need `ingress2gateway` and access to an AI assistant (GitHub Copilot Free needs a GitHub account; Copilot in Azure needs the lab tenant to allow it). (3) DNS: negative caching (up to 5 min) if the name is looked up before the cutover; browsers that try HTTPS first. (4) A reset deletes the participant's gateway and its IP. |
| **Opinion** | **Keep as core round 2 – stronger than the previous "broken route" version.** It answers the pilot feedback (show AKS features, not only Kubernetes troubleshooting), uses the free CNCF tooling plus AI in a realistic way, and every step is observable and verifiable. |
