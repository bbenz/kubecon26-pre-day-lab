# A5 · Running is not ready — END state

A rollout under traffic completes with zero failed customer requests.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| Deployment `web` readiness probe | `httpGet /healthz` (passes as soon as the process starts) | `httpGet /ready` (passes only after the 20 s warm-up, fails while draining) |
| Rollout strategy | `maxUnavailable: 1`, `maxSurge: 1` | `maxUnavailable: 0`, `maxSurge: 1` |

The liveness probe stays on `/healthz`; the app, image and rollout tester are unchanged.

How a participant gets here: [begin-challenge/challenges/a5-running-is-not-ready/SOLUTION.md](../../../begin-challenge/challenges/a5-running-is-not-ready/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges a5        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges a5       # PowerShell
```

Every check should report `PASS`.