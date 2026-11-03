# C2 · Move the storefront to Gateway API — END state

The storefront is served through a Gateway API gateway (application routing add-on, GatewayClass
`approuting-istio`) at its public name `http://ctf-store-<id>.<region>.cloudapp.azure.com/`, and the legacy
Ingress-NGINX path is decommissioned.

| | Begin state | End state (this folder) |
|---|---|---|
| Front door | Ingress `storefront`, class `webapprouting.kubernetes.azure.com` (the add-on's shared NGINX) | Gateway `store-gateway`, class `approuting-istio`, its own public IP |
| Routing | Ingress rule: host, `Prefix /` → `store-front:80`, annotation `proxy-read-timeout: "120"` | HTTPRoute `storefront`: same host, `PathPrefix /` → `store-front:80`, `timeouts.request: 120s` |
| Public name | Reserved, not published (does not resolve) | Published on the gateway: `spec.infrastructure.annotations` → `service.beta.kubernetes.io/azure-dns-label-name` |
| Ingress | present | removed ([`prune.txt`](prune.txt) deletes it when this state is applied on top of a begin-state deployment) |

`store-front` and the other Services stay `ClusterIP`. The application routing add-on's NGINX stays enabled
cluster-wide (turning it off with `az aks approuting update --nginx None` is a production follow-up, not part of
the lab).

The Gateway and HTTPRoute are what `ingress2gateway` generates from the begin-state Ingress after the three AKS
adaptations (GatewayClass, DNS-label-safe Gateway name, request timeout) plus the DNS cutover annotation – see
the comments in [manifests/50-gateway.yaml](manifests/50-gateway.yaml) and
[manifests/60-httproute.yaml](manifests/60-httproute.yaml).

How a participant gets here: [begin-challenge/challenges/c2-ingress-nginx-to-gateway-api/SOLUTION.md](../../../begin-challenge/challenges/c2-ingress-nginx-to-gateway-api/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges c2        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges c2       # PowerShell
```

Every check should report `PASS`. Right after a fresh deployment the public name can take a minute or two to
resolve.
