# A2 · Fast yesterday, slow today — END state

The fixed load test meets the objective (p95 ≤ 300 ms, 0 errors at concurrency 4) within the resource envelope.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| Deployment `checkout-api` resources | requests `cpu: 100m`, limits `cpu: 100m` (throttled on every request) | requests `cpu: 500m`, limits `cpu: "1"` (top of the envelope), 1 replica |

The workload, load test, LimitRange (max 1 CPU / 512Mi per container) and objective are unchanged.
2 replicas × 1 CPU is another valid end state.

How a participant gets here: [begin-challenge/challenges/a2-fast-yesterday-slow-today/SOLUTION.md](../../../begin-challenge/challenges/a2-fast-yesterday-slow-today/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges a2        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges a2       # PowerShell
```

Every check should report `PASS`.