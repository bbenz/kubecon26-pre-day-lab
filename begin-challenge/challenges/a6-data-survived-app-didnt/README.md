# A6 · The data survived, the application didn't

| | |
|---|---|
| **Round** | Additional candidate (timing risk) · Intermediate |
| **Namespace** | `a6-records` |
| **Investigation time (design target)** | 20–25 minutes |
| **Azure services** | AKS Automatic with Azure Disk (CSI, `managed-csi`, ReadWriteOnce) |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> A deployment change ("prepare records-api for the storage migration", CHG-1177) left `records-api` unable to
> mount its data. Recover the service **without deleting, replacing or re-creating the dataset** – the existing
> 500 order records must be served unchanged.

## Learning objective

Trace a workload's storage references and restore access while preserving persistent data.

## What's running

* `records-api` – serves the persisted order records (`/records`: count + checksum). Its readiness probe only
  passes when the dataset is present and intact.
* PersistentVolumeClaim `records-data` (Azure Disk) – seeded with 500 synthetic records by the Job `seed-records`
  when the challenge was deployed.

```bash
kubectl get deploy,pods,pvc,pv -n a6-records
kubectl describe pod -n a6-records -l app=records-api
```

## Success criteria

1. `records-api` becomes Ready and serves the **500 seeded records** with the **original checksum**.
2. It uses the **original** claim and volume – no deleted/re-created claim, no new empty dataset.
3. No destructive recovery (PVC/PV deletion, forced detach).

```bash
scoring/verify.sh --challenges a6          # bash
./scoring/verify.ps1 -Challenges a6        # PowerShell
```

## Hints

<details><summary>Hint 1 – Follow the pod's volume event</summary>

`kubectl describe pod -n a6-records -l app=records-api` → Events. What exactly can't the scheduler find?
</details>

<details><summary>Hint 2 – Compare the referenced claim with the existing claims</summary>

`kubectl get pvc -n a6-records` vs. the Deployment's `volumes[].persistentVolumeClaim.claimName`.
</details>

<details><summary>Hint 3 – Verify the identity and contents of the original storage before changing it</summary>

Which PV is bound to which claim (`kubectl get pv`)? The `seed-records` Job's log shows the dataset checksum it
wrote. Change the reference – not the data.
</details>

## What doesn't count

* Creating a claim called `records-data-v2` (a new, **empty** disk – the app won't become Ready, and it would not
  be the original dataset anyway).
* Deleting/re-creating `records-data`, re-running the seed Job against a new volume, or force-detaching disks.

## Stretch objective

Explain why restoring availability with a new empty volume would not satisfy the business recovery requirement.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c a6        # re-creates the namespace, disk and seed data
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges a6
```

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **High (Kubernetes) / medium (timing on Azure).** The Deployment references a non-existent claim → pod `Pending` with `persistentvolumeclaim "records-data-v2" not found`. The original claim, disk and seeded data stay intact (the seed Job runs in a setup phase *before* the app is deployed, so there is no attach race). The readiness probe checks dataset presence and checksum, so the "new empty volume" bypass visibly fails. Deployment strategy `Recreate` avoids two pods fighting over the RWO disk. |
| **Validation status** | Fault, fix and scoring validated locally with bash, PowerShell and Terraform (local-path storage). **Pending Azure pilot:** Azure Disk attach latency after the fix (typically 30–90 s; plus a NAP node in the disk's zone if no node there has room), and repeated mount/rollout behaviour (the design doc's pilot gate). |
| **Fit for 200-level users** | Good – the event names the missing claim directly; PVC/PV basics are core knowledge. The interesting part is resisting the "just create the missing PVC" reflex. |
| **Expected time** | 10–15 min + 1–3 min attach/scheduling → may finish early. |
| **Risks** | Zonal disk + node placement latency; transient `Multi-Attach` events if the app lands on a different node from the (completed) seed pod while Azure detaches the disk – resolves on its own within ~1 min. |
| **Opinion** | **Reserve.** Reliable and safe, but somewhat easy and the waiting time is mostly attach latency; use it if a storage topic is wanted. |
