# A1 · Where did DNS go? — END state

`inventory-sync` resolves and reaches `catalog-api`; `ledger-api` and the internet stay blocked.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| NetworkPolicy `inventory-sync-egress` | allows only TCP 8080 to `app=catalog-api` | + UDP/TCP 53 to the cluster DNS path only: LocalDNS (`169.254.10.10/32`, `169.254.10.11/32`) and the `k8s-app=kube-dns` pods in `kube-system` |

`default-deny-egress` is unchanged.

> **Pilot gate:** confirm on AKS Automatic (LocalDNS + Cilium) that this rule restores DNS. If Cilium does not
> match the LocalDNS addresses with `ipBlock`, update this end state (see the challenge README).

How a participant gets here: [begin-challenge/challenges/a1-where-did-dns-go/SOLUTION.md](../../../begin-challenge/challenges/a1-where-did-dns-go/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges a1        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges a1       # PowerShell
```

Every check should report `PASS`.