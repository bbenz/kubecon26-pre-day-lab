# Scoring – verify a challenge against its success criteria

`verify.sh` (bash) and `verify.ps1` (PowerShell 7.4+) run the same checks. They need only `kubectl` access to the
lab cluster (plus `curl` for C2 in bash) – no Azure CLI. C2 also resolves the storefront's public name from the
machine running the check, like your browser would.

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
passed. A freshly deployed challenge reports **NOT PASSED**; once you've fixed it, it reports **PASSED**.

## What is checked

Each check follows the challenge's success criteria and its *What doesn't count* list: a fix that bypasses the
problem, such as an override that the next deployment would undo, doesn't pass.

Some checks act on the cluster the way you would: A3 creates a short-lived Job from the
`maintenance-check` CronJob (one controlled eviction), A5 starts a rollout of `web`, C1 places one synthetic order
and A2 runs the bounded load test.

## Event leaderboard

At an event with a leaderboard, the lab VMs are registered for it (by the event's Skillable life cycle action, or the
`CTF_LEADERBOARD_URL` / `CTF_PLAYER_ID` / `CTF_PLAYER_NAME` environment variables), and both scripts also record each
checked challenge there: one write-once record with pass/fail and the number of checks passed, sent with a
create-only token (`curl` in bash, `Invoke-WebRequest` in PowerShell). A failed submission prints one line and never
changes the result or the exit code. `--no-report` / `-NoReport` skips it; `--quick` / `-Quick` runs are never recorded.
On a machine that isn't registered, nothing is sent.
