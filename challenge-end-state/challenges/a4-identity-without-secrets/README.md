# A4 · Identity without secrets — END state

`config-reader` reads the lab value from Key Vault with workload identity; `report-generator` is still denied.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| Federated identity credential `config-reader` on `id-ctf-config-reader` (Azure) | subject `system:serviceaccount:config-legacy:config-reader` | subject `system:serviceaccount:a4-config:config-reader` |

The value comes from [`azure.env`](azure.env) and is applied by all three deployment approaches. The Kubernetes
manifests are identical in both states; no secrets or extra roles are added.

How a participant gets here: [begin-challenge/challenges/a4-identity-without-secrets/SOLUTION.md](../../../begin-challenge/challenges/a4-identity-without-secrets/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges a4        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges a4       # PowerShell
```

Every check should report `PASS`.