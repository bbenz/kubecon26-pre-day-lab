# A5 · Walkthrough to the end state (facilitators)

> Spoilers.

## 1. Reproduce under traffic

```bash
kubectl exec -n a5-releases deploy/rollout-tester -- python3 /app/rollout_test.py
```

```text
Deployment web: replicas=3, readinessProbe path=/healthz, maxUnavailable=1, maxSurge=1
Baseline (5s before the rollout): 98 ok, 0 failed
Started rollout (new pod template revision, generation 2) ...
Rollout completed in 8s (timeout 240s)
Customer requests: 170 ok, 172 failed {"HTTP 503": 172}
RESULT: FAIL - 172 customer requests failed during the rollout
```

The rollout "succeeds" in 8 seconds – far faster than the 20 s warm-up – and customers get 503s.

## 2. Compare Running/Ready with what the app can do

```bash
kubectl get pods -n a5-releases -w                          # new pods READY 1/1 after ~2 s
kubectl logs -n a5-releases -l app=web --tail=2             # "... product cache loaded after 20s ..."
kubectl exec -n a5-releases deploy/rollout-tester -- curl -s web:8080/ready    # 503 while warming up
```

## 3. Find the mismatch

```bash
kubectl get deploy web -n a5-releases -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}{"\n"}{.spec.strategy}{"\n"}'
```

* The readiness probe calls `/healthz`, which only says "the process is alive" – so pods are marked Ready (and
  added to the Service endpoints) before the cache is loaded.
* `maxUnavailable: 1` lets the controller remove an old, serving pod before the replacement can serve.

## 4. Fix readiness and the rollout strategy

```bash
kubectl patch deployment web -n a5-releases --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"},
  {"op":"replace","path":"/spec/strategy/rollingUpdate/maxUnavailable","value":0}]'
kubectl rollout status deployment/web -n a5-releases
```

(Keep liveness on `/healthz`.)

## 5. Prove it

```bash
kubectl exec -n a5-releases deploy/rollout-tester -- python3 /app/rollout_test.py
# Rollout completed in 70s ... Customer requests: 1521 ok, 0 failed {}
# RESULT: PASS - zero failed customer requests during the rollout
scoring/verify.sh --challenges a5
```

The rollout now takes longer (each new pod must warm up before an old one is removed) – that is the point.

## End state

Matches [`challenge-end-state/challenges/a5-running-is-not-ready`](../../../challenge-end-state/challenges/a5-running-is-not-ready/README.md):
readiness `/ready`, liveness `/healthz`, `maxUnavailable: 0`, `maxSurge: 1`.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| `initialDelaySeconds: 60` on the `/healthz` readiness probe | A guess, not a signal: too short under load, needlessly slow otherwise; scoring requires a meaningful readiness check. |
| `/ready` as the liveness probe | Liveness failures during warm-up restart the pod – a crash loop under slow starts. |
| `maxUnavailable: 0` only | Fewer errors, but new pods still get traffic before they can serve. |
| `minReadySeconds: 30` only | Delays the next step of the rollout but traffic still reaches the warming pod. |

## Stretch objective – notes

* **Startup probe**: slow initialisation – holds off liveness/readiness until the app has started.
* **Readiness probe**: "can I take traffic *now*?" – may flip to false temporarily (warm-up, draining, overload).
* **Liveness probe**: "am I stuck beyond recovery?" – keep it local and cheap.
* Putting a **dependency check** (database, downstream API, model endpoint) into liveness restarts every pod when
  the dependency blips – a cascading outage. Even in readiness, an outage of a shared dependency removes *all*
  replicas from service at once, so use it deliberately.
