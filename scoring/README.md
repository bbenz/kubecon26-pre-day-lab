# Scoring – verify a challenge against its success criteria

`verify.sh` (bash) and `verify.ps1` (PowerShell 7.4+) run the same checks. They need only `kubectl` access to the
lab cluster (plus `curl` for C2 in bash) – no Azure CLI – so they also work for proctors and, later, for automated
scoring. C2 also resolves the storefront's public name from the machine running the check, like a participant's
browser would.

```bash
scoring/verify.sh                                        # every challenge found in the current kubectl context
scoring/verify.sh --context aks-kubecon-ctf-begin-bash --challenges c1,a3
scoring/verify.sh --quick                                # shorter waits / 15 s stability window
scoring/verify.sh --no-report                            # don't record this run on the event leaderboard
```

```powershell
./scoring/verify.ps1
./scoring/verify.ps1 -Context aks-kubecon-ctf-begin-pwsh -Challenges c1,a3
./scoring/verify.ps1 -Quick
./scoring/verify.ps1 -NoReport                         # don't record this run on the event leaderboard
```

Output: `PASS`/`FAIL` per check with short evidence, then a summary; exit code `0` only if every selected challenge
passed. In the begin state every challenge reports **NOT PASSED**; after the expected repair (or on an end-state
deployment) it reports **PASSED**.

## What is checked

| ID | Checks (from the design document's success criteria and "what doesn't count") |
|---|---|
| C1 | `FASTIFY_ADDRESS` in the ConfigMap is a bind host (or unset); no override on the Deployment; rollout ready; no restarts during 60 s; synthetic order via the storefront succeeds and reaches the RabbitMQ queue |
| C2 | a Gateway of class `approuting-istio` in `c2-storefront` (any name; the one carrying the storefront's DNS label is preferred) is `Programmed` with an address; its `infrastructure.annotations` publish the storefront's DNS label; an HTTPRoute (any name) attached to it for the storefront host is `Accepted`/`ResolvedRefs` and sends `PathPrefix /` to `store-front:80`; `http://<host>/` resolves to the gateway and returns the storefront (200, retried for ~1 min for DNS); other Host → 404 at the gateway; no Ingress left in the namespace; `store-front` stays `ClusterIP`; no LoadBalancer Services other than `*-approuting-istio`. Host name and label come from the namespace annotations `kubecon.lab/storefront-hostname` / `-dns-label` |
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

## Leaderboard reporting

On a machine registered for an event leaderboard (by the Skillable life cycle action, `leaderboard/join.*`, or the
`CTF_LEADERBOARD_URL` / `CTF_PLAYER_ID` / `CTF_PLAYER_NAME` environment variables), both scripts also record each checked
challenge on the leaderboard: one write-once record with pass/fail and the number of checks passed, sent with a
create-only token (`curl` in bash, `Invoke-WebRequest` in PowerShell). A failed submission prints one line and never
changes the result or the exit code. `--no-report` / `-NoReport` skips it; `--quick` / `-Quick` runs are never recorded.
Machines without a registration behave exactly as before. Details: [leaderboard/README.md](../leaderboard/README.md).
