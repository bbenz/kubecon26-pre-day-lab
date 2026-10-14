# A3 · Ready for maintenance? — END state

A controlled voluntary eviction is accepted and requests keep succeeding.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| Deployment `inventory-api` | `replicas: 1` with PDB `minAvailable: 1` → 0 disruptions allowed | `replicas: 2`, PDB unchanged → 1 disruption allowed |

The PodDisruptionBudget, the maintenance check and its RBAC are identical in both states. On deployment the
`pre-maintenance-check` Job reports `RESULT: PASS`.

How a participant gets here: [begin-challenge/challenges/a3-ready-for-maintenance/SOLUTION.md](../../../begin-challenge/challenges/a3-ready-for-maintenance/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges a3        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges a3       # PowerShell
```

Every check should report `PASS`.