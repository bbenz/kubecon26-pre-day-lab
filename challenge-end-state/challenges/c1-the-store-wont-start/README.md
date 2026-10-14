# C1 · The store won't start — END state

The order service runs, stays stable and accepts orders.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| ConfigMap `order-service-configs` | `FASTIFY_ADDRESS: "0.0.0.0:3000"` (host:port in a host-only setting) | `FASTIFY_ADDRESS: "0.0.0.0"` and `FASTIFY_PORT: "3000"` |
| Deployment `order-service` | pod template annotation `kubecon.lab/config-revision: CHG-1109` | `CHG-1109-fix` (the rollout that picks up the corrected configuration) |

Everything else (RabbitMQ, product-service, store-front) is identical to the begin state.

How a participant gets here: [begin-challenge/challenges/c1-the-store-wont-start/SOLUTION.md](../../../begin-challenge/challenges/c1-the-store-wont-start/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges c1        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges c1       # PowerShell
```

Every check should report `PASS`.