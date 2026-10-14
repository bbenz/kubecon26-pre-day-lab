# C3 · Capacity that never arrives

| | |
|---|---|
| **Round** | Proposed core, round 3 (recommended as an advanced bonus) · Intermediate–advanced |
| **Namespace** | `c3-processing` (plus the cluster-scoped NodePool `c3-processing`) |
| **Investigation time (design target)** | 20–25 minutes, including 1–5 minutes of node provisioning after the fix |
| **Azure services** | AKS Automatic node auto-provisioning (NAP, Karpenter-based) |
| **Walkthrough to the end state** | [SOLUTION.md](SOLUTION.md) (facilitators only) |

## Participant briefing

> A new order-processing batch job is stuck `Pending`. Node auto-provisioning is enabled, but the capacity it
> needs never appears. Get the batch to run **on its dedicated processing pool**.
>
> Platform standards for the processing pool: general-purpose **D-family**, **2–4 vCPU**, on-demand, nodes
> reserved for processing workloads (label + taint). The processing image is published for **amd64 only**.

## Learning objective

Relate workload scheduling requirements to NodePool eligibility and explain why useful capacity is not
provisioned.

## What's running

* Job `order-batch` (namespace `c3-processing`) – requires `kubecon.lab/pool=processing`,
  `kubernetes.io/arch=amd64` and tolerates the processing taint.
* NAP `NodePool` `c3-processing` (cluster-scoped, `karpenter.sh/v1`) – the dedicated pool for that workload.
* AKS Automatic's own NodePools (`default`, `system-surge`) also exist.

```bash
kubectl get pods,jobs -n c3-processing
kubectl get nodepools
```

## Success criteria

1. The batch Job **completes** on capacity from the **dedicated** NodePool `c3-processing`.
2. The workload keeps its placement, architecture (`amd64`) and isolation requirements (no removing the
   nodeSelector/toleration, no moving it to unrelated capacity).
3. The NodePool keeps its isolation (label + `NoSchedule` taint), its CPU limit and its `amd64` requirement –
   you make its requirements *satisfiable*, you don't delete all constraints.

```bash
scoring/verify.sh --challenges c3          # bash
./scoring/verify.ps1 -Challenges c3        # PowerShell
```

## Hints

<details><summary>Hint 1 – Follow the Pending pod's scheduling evidence</summary>

`kubectl describe pod -n c3-processing -l app=order-batch` – read **all** the Events, including those from
the node auto-provisioner (Karpenter), not just the default scheduler's. Karpenter explains why the pools it
*considered* don't fit – a pool that can't offer any instance type isn't mentioned at all, so don't take its
"typo of ..." suggestion at face value.
</details>

<details><summary>Hint 2 – Identify the pools eligible for this workload</summary>

Which NodePool could ever host this pod (label + taint)? `kubectl get nodepools`, then
`kubectl describe nodepool c3-processing` – its requirements **and its Events**. Note that a NodePool can
report `READY=True` and still be unable to launch anything.
</details>

<details><summary>Hint 3 – Look for constraints that cannot be satisfied together</summary>

Compare every requirement in the NodePool with each other, not just with the pod. What does the `p` in
an Azure VM size such as `Standard_D4ps_v6` mean? (`az vm list-skus -l <region> --size Standard_D4ps_v6 --query "[0].capabilities[?name=='CpuArchitectureType'].value"`)
</details>

## What doesn't count

* Removing the Job's `nodeSelector`/toleration, switching it to `arm64`, or running it on the `default` pool.
* Removing the NodePool's taint, label, CPU limit or architecture requirement, or deleting the NodePool.

## Stretch objective

Explain how these would look different in the evidence: an impossible selector combination, a pool resource
limit, Azure vCPU quota exhaustion, and temporary SKU unavailability in a zone.

## Reset

```bash
begin-challenge/azure-cli-bash/deploy.sh -c c3        # deletes the NodePool (and its nodes) and re-creates it
./begin-challenge/azure-cli-powershell/deploy.ps1 -Challenges c3
```

Allow 2–5 minutes for the reset: deleting the NodePool drains and removes nodes from a previous successful
run, so retained nodes cannot mask the fault.

---

## Feasibility assessment (evaluation notes)

| Aspect | Assessment |
|---|---|
| **Technical feasibility** | **Medium–high – validated on Azure (2026-10-14).** Custom NAP NodePools (`karpenter.sh/v1`, `AKSNodeClass` `default`) work on AKS Automatic. The seeded fault is self-contradictory *inside* the pool (`kubernetes.io/arch In [amd64]` + an approved SKU list of Arm64 `Dps/Dpds v6` sizes): the NodePool reports `READY=True`, `NODES 0` and the event `NoCompatibleInstanceTypes: NodePool requirements filtered out all compatible available instance types`. Deterministic, never auto-fixed. After the fix NAP launched a `Standard_D4as_v6` node and the batch completed ~2 minutes after the change. |
| **Validation status** | Begin and end state validated on AKS Automatic 1.35 (westus3). Observed pod events: the scheduler's `0/6 nodes are available ...`, a cluster-autoscaler `NotTriggerScaleUp`, and a **misleading Karpenter message** (`label "kubecon.lab/pool" does not have known values (typo of "karpenter.sh/nodepool"?)`) that describes the *other* pools. Regional SKU restrictions matter: the test subscription cannot use v5/v6 x64 sizes in eastus2 (default region is westus3); the end-state SKU list spans v5/v6/v7. |
| **Fit for 200-level users** | **Stretch.** Requires NodePool/Karpenter concepts (requirements, taints vs tolerations, nodeSelector) and Azure VM naming knowledge (`p` = Arm64). The evidence is spread across scheduler events, Karpenter events and the NodePool object, and the Karpenter "typo" suggestion points the wrong way. Hints are essential. |
| **Expected time** | 20–30 min (investigation 15–25 + ~2 min provisioning and batch). Tight for a 20–25 min window. |
| **Risks** | A participant who types a SKU that is restricted in the subscription/region hits a *second* failure; reset needs 2–5 min outside the round; after 10 minutes the finished batch pod disappears with its consolidated node (the Job still shows `Complete`). |
| **Opinion** | **Advanced bonus round** (technically clean, but the riskiest core challenge for a 200-level audience); put **A2** (or A5) in its core slot. |
