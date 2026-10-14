# A6 · Walkthrough to the end state (facilitators)

> Spoilers.

## 1. Follow the pod's volume event

```bash
kubectl get pods -n a6-records                      # records-api-...  0/1  Pending
kubectl describe pod -n a6-records -l app=records-api | sed -n '/Events/,$p'
# Warning  FailedScheduling  ... persistentvolumeclaim "records-data-v2" not found
```

## 2. Compare the reference with the existing claims

```bash
kubectl get pvc -n a6-records
# NAME           STATUS   VOLUME        CAPACITY   ACCESS MODES   STORAGECLASS
# records-data   Bound    pvc-1a2b...   8Gi        RWO            managed-csi
kubectl get deploy records-api -n a6-records \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}{"\n"}'   # records-data-v2
kubectl get deploy records-api -n a6-records -o jsonpath='{.metadata.annotations}{"\n"}'                # CHG-1177
```

The Deployment was pointed at a claim for a migration that never happened. The original claim still exists and
is bound.

## 3. Verify the original storage before changing anything

```bash
kubectl get pv
kubectl logs -n a6-records job/seed-records        # seeded 500 order records, sha256=aa451749...
```

## 4. Point the application back at the original claim

```bash
kubectl patch deployment records-api -n a6-records --type strategic -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"records-data"}}]}}}}'
kubectl rollout status deployment/records-api -n a6-records --timeout=5m
```

(`kubectl edit deployment records-api -n a6-records` works too.) On Azure the disk attach takes ~30–90 s; you may
briefly see `Multi-Attach error` while the disk detaches from the node that ran the seed Job.

## 5. Prove it

```bash
kubectl get --raw /api/v1/namespaces/a6-records/services/records-api:http/proxy/records
# {"present": true, "records": 500, "sha256": "aa451749...", "expected_sha256": "aa451749...", "intact": true}
scoring/verify.sh --challenges a6
```

## End state

Matches [`challenge-end-state/challenges/a6-data-survived-app-didnt`](../../../challenge-end-state/challenges/a6-data-survived-app-didnt/README.md):
`claimName: records-data`.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Create PVC `records-data-v2` | Provisions a new, empty disk: the app's readiness fails (no dataset) – and an empty volume is not a recovery. |
| Delete/re-create `records-data` | With `reclaimPolicy: Delete` the disk and the data are destroyed. |
| Re-run the seed Job | Re-creating data is not restoring it (in real life the data can't be regenerated). |

## Stretch objective – notes

Availability is not recovery: the business needs *its* data (orders, history), not a running process. A new empty
volume makes the pod Ready but loses the records – arguably worse than downtime, because the service looks healthy
while serving wrong (empty) data. Verify identity (which PV, which checksum) before and after any storage change.
