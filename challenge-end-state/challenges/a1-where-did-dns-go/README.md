# A1 · Where did DNS go? — END state

`inventory-sync` resolves and reaches `catalog-api`; `ledger-api` and the internet stay blocked.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| NetworkPolicy `inventory-sync-egress` | allows only TCP 8080 to `app=catalog-api` | + UDP/TCP 53 with no destination restriction |

`default-deny-egress` is unchanged.

Why no destination: on AKS Automatic pods resolve through LocalDNS (node-local `169.254.10.11`), and Azure CNI
powered by Cilium treats that traffic as the `host` entity, which a Kubernetes NetworkPolicy cannot select – the
textbook rules (53 to the `kube-dns` pods, or `ipBlock` 169.254.10.x) do not restore DNS (verified on Azure).
The least-privilege alternative, a `CiliumNetworkPolicy` with `toEntities: [host]`, is in the
[SOLUTION](../../../begin-challenge/challenges/a1-where-did-dns-go/SOLUTION.md) (option B); both pass the checks.

How a participant gets here: [begin-challenge/challenges/a1-where-did-dns-go/SOLUTION.md](../../../begin-challenge/challenges/a1-where-did-dns-go/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges a1        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges a1       # PowerShell
```

Every check should report `PASS`.