# C3 · Walkthrough to the end state (facilitators)

> Spoilers. Events below were captured on AKS Automatic 1.35 (westus3) on 2026-10-14.

## 1. Follow the Pending pod

```bash
kubectl get pods -n c3-processing                        # order-batch-xxxxx   0/1   Pending
kubectl describe pod -n c3-processing -l app=order-batch | sed -n '/Events/,$p'
```

Three sources of evidence:

* **default-scheduler** – `0/6 nodes are available: 1 node(s) didn't match Pod's node affinity/selector,
  5 node(s) had untolerated taint(s) ...` (no *existing* node fits: none carries `kubecon.lab/pool=processing`).
* **karpenter** (node auto-provisioning) – `Failed to schedule pod, did not tolerate taint
  (taint=CriticalAddonsOnly=true:NoSchedule); incompatible requirements, label "kubecon.lab/pool" does not have
  known values (typo of "karpenter.sh/nodepool"?)`. **Careful – this is a red herring:** Karpenter reports why the
  *other* pools (`system-surge`, `default`) don't fit. The only pool that could host the pod, `c3-processing`, isn't
  mentioned because it has no usable instance types at all. Nothing is wrong with the pod's label.
* **cluster-autoscaler** – `NotTriggerScaleUp ... pod didn't trigger scale-up` (the managed system pool; ignore).

## 2. Find the eligible pool and read its evidence

```bash
kubectl get nodepools                                   # c3-processing  NODES 0  READY True (!)
kubectl describe nodepool c3-processing                 # Events: NoCompatibleInstanceTypes
#   Warning  NoCompatibleInstanceTypes  NodePool requirements filtered out all compatible available instance types
kubectl get nodepool c3-processing -o yaml | sed -n '/requirements:/,/limits:/p'
```

```yaml
- key: kubernetes.io/arch
  operator: In
  values: ["amd64"]
...
- key: karpenter.azure.com/sku-name
  operator: In
  values: [Standard_D2ps_v6, Standard_D4ps_v6, Standard_D2pds_v6, Standard_D4pds_v6]
```

Only `c3-processing` can host the pod (`default`/`system-surge` don't set the processing label or tolerate
nothing it needs). Its `READY=True` only means the pool definition is valid – not that it can launch nodes.

## 3. Spot the contradiction

The `p` in `Dps_v6`/`Dpds_v6` means **Arm64** (Azure Cobalt 100). The pool requires `amd64` *and* only allows
Arm64 sizes → zero compatible instance types. The workload is amd64-only, so the fix is in the pool's approved
size list, not in the workload.

```bash
az vm list-skus -l <region> --size Standard_D2ps_v6 --query "[0].capabilities[?name=='CpuArchitectureType'].value" -o tsv   # Arm64
az vm list-skus -l <region> --size Standard_D2s_v6  --query "[0].capabilities[?name=='CpuArchitectureType'].value" -o tsv   # x64
```

## 4. Make the pool satisfiable (keep isolation, limits and amd64)

Either replace the approved list with amd64 sizes that are available in your region...

```bash
# requirement index 5 is karpenter.azure.com/sku-name (0 os, 1 arch, 2 capacity-type, 3 family, 4 cpu)
kubectl patch nodepool c3-processing --type json -p '[{"op":"replace","path":"/spec/template/spec/requirements/5/values",
  "value":["Standard_D2s_v5","Standard_D4s_v5","Standard_D2s_v6","Standard_D4s_v6","Standard_D2s_v7","Standard_D4s_v7"]}]'
```

...or remove only the contradictory `sku-name` requirement and rely on the platform standard already encoded
in the pool (`sku-family In [D]`, `sku-cpu In [2,4]`, `arch In [amd64]`):

```bash
kubectl patch nodepool c3-processing --type json -p '[{"op":"remove","path":"/spec/template/spec/requirements/5"}]'
```

> Check availability first: `az vm list-skus -l <region> --size Standard_D2s --output table` – a size with a
> `NotAvailableForSubscription` restriction in every zone produces a *second* failure (the test subscription
> cannot use v5/v6 x64 sizes in eastus2).

## 5. Watch capacity arrive and the batch run

```bash
kubectl get nodeclaims -w                                   # a c3-processing NodeClaim launches
kubectl get nodes -l karpenter.sh/nodepool=c3-processing
kubectl logs -n c3-processing job/order-batch -f            # ... BATCH COMPLETE ... (arch x86_64)
scoring/verify.sh --challenges c3
```

Observed on Azure: the node was Ready and the batch finished about 2 minutes after the fix. NAP removes the empty
node 10 minutes later (`consolidateAfter`), and the finished pod – with its logs – disappears together with the
node; the Job keeps `Complete`.

## End state

Matches [`challenge-end-state/challenges/c3-capacity-that-never-arrives`](../../../challenge-end-state/challenges/c3-capacity-that-never-arrives/README.md):
the approved list holds amd64 D-series sizes (v5/v6/v7); everything else in the pool and the Job is unchanged.

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Change the pool to `arm64` | The image is amd64-only; the pod still requires `kubernetes.io/arch=amd64`. |
| Remove the Job's nodeSelector/toleration | Moves the workload onto unrelated capacity – breaks the placement/isolation requirement. |
| Delete all pool requirements / taint / limits | Removes the platform guardrails instead of fixing the contradiction. |
| Delete the NodePool | The workload can then never be placed (or lands somewhere unintended). |

## Stretch objective – notes

* **Impossible combination** (this challenge): nothing is ever launched; NodePool event
  `NoCompatibleInstanceTypes`; pod events say no instance type satisfies the requirements.
* **Pool limit reached**: instance types exist but would exceed `spec.limits`; Karpenter reports the pool's
  limits and the NodePool status shows resources at the limit.
* **Azure quota exhausted**: a NodeClaim is created but the VM launch fails with a quota error (NodeClaim
  conditions/events show the Azure error); raising quota or choosing another family fixes it.
* **Temporary SKU unavailability**: launch fails with an allocation/`SkuNotAvailable` error for a zone/size;
  Karpenter retries other sizes/zones from the allowed set – a broader allow-list makes the pool resilient.
