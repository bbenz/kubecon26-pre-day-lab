# C3 · Capacity that never arrives — END state

Node auto-provisioning creates an amd64 node from the dedicated NodePool and the batch Job completes on it.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| NodePool `c3-processing`, `karpenter.azure.com/sku-name` | Arm64 sizes only (`Standard_D2ps_v6`, `D4ps_v6`, `D2pds_v6`, `D4pds_v6`) while the pool requires `kubernetes.io/arch: amd64` | amd64 sizes across generations (`Standard_D2s_v5` … `Standard_D4s_v7`) so NAP finds capacity even when a series is restricted in a region |

Pool isolation (label + `NoSchedule` taint), CPU limit, `amd64` requirement and the Job's placement are unchanged.
Removing only the `sku-name` requirement (keeping family D, 2–4 vCPU, amd64) is an equally valid repair.

How a participant gets here: [begin-challenge/challenges/c3-capacity-that-never-arrives/SOLUTION.md](../../../begin-challenge/challenges/c3-capacity-that-never-arrives/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges c3        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges c3       # PowerShell
```

Every check should report `PASS`.