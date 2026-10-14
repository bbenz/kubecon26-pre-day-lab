# Scoring – verify a challenge against its success criteria

`verify.sh` (bash) and `verify.ps1` (PowerShell 7.4+) run the same checks. They need only `kubectl` access to the
lab cluster (plus `curl` for C2 in bash) – no Azure CLI – so they also work for proctors and, later, for automated
scoring.

```bash
scoring/verify.sh                                        # every challenge found in the current kubectl context
scoring/verify.sh --context aks-kubecon-ctf-begin-bash --challenges c1,a3
scoring/verify.sh --quick                                # shorter waits / 15 s stability window
```

```powershell
./scoring/verify.ps1
./scoring/verify.ps1 -Context aks-kubecon-ctf-begin-pwsh -Challenges c1,a3
./scoring/verify.ps1 -Quick
```

Output: `PASS`/`FAIL` per check with short evidence, then a summary; exit code `0` only if every selected challenge
passed. In the begin state every challenge reports **NOT PASSED**; after the expected repair (or on an end-state
deployment) it reports **PASSED**.

## What is checked

| ID | Checks (from the design document's success criteria and "what doesn't count") |
|---|---|
| C1 | `FASTIFY_ADDRESS` in the ConfigMap is a bind host (or unset); no override on the Deployment; rollout ready; no restarts during 60 s; synthetic order via the storefront succeeds and reaches the RabbitMQ queue |
| C2 | route keeps its hostname, `PathPrefix /` and `store-front` backend; route `Accepted`/`ResolvedRefs`; storefront served through the gateway (200); other Host → 404; `store-front` stays `ClusterIP`; no extra LoadBalancer Services |
| C3 | NodePool keeps `amd64`, label/taint isolation and CPU limit; no Arm64 sizes in the allow-list; Job keeps its placement; Job completes on a node from `c3-processing` (if node auto-provisioning has already removed the empty node and the finished pod with it, the completed Job and its placement rules count) |
| C4 | Entra ID auth (no API keys); `ai-service` is configured for the provisioned model deployment (`store-assistant`, or `AOAI_DEPLOYMENT_NAME` if you deployed with another name); ai-service ready; store-admin → product-service → ai-service → model returns a description (retries for propagation) |
| A1 | from inside `inventory-sync`: DNS resolves, catalog call works, `ledger-api` and the internet stay blocked; `default-deny-egress` unchanged; no allow-all egress rule |
| A2 | limits set, CPU ≤ 1, replicas ≤ 2, no HPA > 2; workload/test unchanged; fixed load test p95 ≤ 300 ms, 0 errors |
| A3 | replicas ≥ 2; PDB still protects the app; an on-demand `maintenance-check` eviction is accepted with 0 failed requests; back at target replicas |
| A4 | `config-reader` reads the lab value via workload identity; `report-generator` still unauthorized; no Secrets in the namespace; workload identity label kept |
| A5 | readiness on `/ready`, liveness not on `/ready`, no long initial delay; rollout under traffic with 0 failed requests |
| A6 | Deployment uses `records-data`; PVC still bound; app ready; 500 records with the original checksum |

Some checks act on the cluster the way a participant would: A3 creates a short-lived Job from the
`maintenance-check` CronJob (one controlled eviction), A5 starts a rollout of `web`, C1 places one synthetic order
and A2 runs the bounded load test.
