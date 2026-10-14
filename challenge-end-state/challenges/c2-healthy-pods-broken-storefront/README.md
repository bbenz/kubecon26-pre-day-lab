# C2 · Healthy pods, broken storefront — END state

The storefront is served through the Gateway API gateway at its public hostname.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| HTTPRoute `storefront` | `backendRefs[0].port: 8080` (the container port) | `backendRefs[0].port: 80` (the Service port) |

Hostname, path (`PathPrefix /`), Gateway `store-gateway` (class `approuting-istio`) and all Services are
unchanged; `store-front` stays `ClusterIP` (reachable only through the gateway).

How a participant gets here: [begin-challenge/challenges/c2-healthy-pods-broken-storefront/SOLUTION.md](../../../begin-challenge/challenges/c2-healthy-pods-broken-storefront/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges c2        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges c2       # PowerShell
```

Every check should report `PASS`.