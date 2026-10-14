# Feasibility assessment – KubeCon AKS capture-the-flag lab

Evaluation of the ten candidate challenges from *AKS Capture the Flag Lab Approach and Azure Requirements – v2*
(C1–C4 proposed core, A1–A6 alternates). The question for each one: can it be **built reliably** on AKS Automatic,
and can a participant with **200-level** Kubernetes/Azure knowledge **finish it within the round** with minimal
friction? Each challenge's README has the detailed assessment; this page summarises them.

> **Status (2026-10-13):** code complete for all ten challenges in three deployment approaches (Azure CLI bash,
> Azure CLI PowerShell, Terraform). Kubernetes-level behaviour of C1, A1, A2, A3, A5 and A6 is **validated on a
> local cluster** with all three approaches (begin state fails the success criteria, end state passes, documented
> fixes converge). **Nothing has been deployed to Azure yet** – the "pilot gate" items below need the first Azure run.

## Summary

| ID | Challenge | Built reliably on AKS Automatic? | 200-level fit | Expected time (design) | Main risk | Validated | Opinion |
|---|---|---|---|---|---|---|---|
| **C1** | The store won't start | **High** – deterministic crash, no Azure deps | Good | 10–15 (15–20) | Low | Local ✔ · Azure ⏳ | **Keep – round 1** |
| **C2** | Healthy pods, broken storefront | **Medium–high** – Gateway API GA, enabled explicitly | Medium (new API vocabulary) | 15–25 (20–25) | Route status wording; Gateway API novelty | Azure ⏳ | **Keep – round 2** (after pilot) |
| **C3** | Capacity that never arrives | **Medium** – deterministic, but NAP latency | Stretch (Karpenter + VM naming) | 20–30 (20–25) | Provisioning time, knowledge gap, SKU restrictions | Azure ⏳ | **Pilot gate – swap for A2 if > 5 min or unclear events** |
| **C4** | The AI assistant is up, but not working | **Medium–high** – single fault, Entra auth | Good | 10–20 (20–25) | Model quota/availability per subscription | Azure ⏳ | **Keep – round 4** (after pilot); fallback A4 |
| **A1** | Where did DNS go? | **Medium** – LocalDNS + Cilium behaviour unknown | Medium (NetworkPolicy YAML) | 20–30 (20–25) | DNS path on Automatic may defeat the "classic" fix | Local ✔ · Azure ⚠ | Alternate **only if pilot is clean** |
| **A2** | Fast yesterday, slow today | **High** – self-contained, calibrated | Good | 15–20 (20–25) | CPU speed variance across VM sizes | Local ✔ · Azure ⏳ | **Strong alternate – first substitute for C3** |
| **A3** | Ready for maintenance? | **High** – PDBs untouched by safeguards | Good (slightly easy) | 10–15 (20–25) | Low | Local ✔ · Azure ⏳ | Reserve / easy round |
| **A4** | Identity without secrets | **Medium–high** – clear AADSTS evidence | Medium | 15–20 (20–25) | Student needs Azure rights on the identity | Azure ⏳ | **Swap-in for C4** |
| **A5** | Running is not ready | **High** – deterministic, objective test | Very good | 15–20 (15–20) | Low | Local ✔ · Azure ⏳ | **Strong alternate** (great for 200-level) |
| **A6** | The data survived, the application didn't | **High / timing medium** | Good (slightly easy) | 10–15 + attach (20–25) | Disk attach/zone latency | Local ✔ · Azure ⏳ | Reserve |

Times are investigation minutes (excluding briefing, debrief and reset); the design target from the document is in
parentheses.

## Recommended line-up (four rounds, 200-level audience)

1. **C1 – The store won't start** (warm-up: logs, ConfigMaps, rollouts)
2. **C2 – Healthy pods, broken storefront** (Gateway API – topical after the Ingress-NGINX retirement)
3. **A2 – Fast yesterday, slow today** in place of C3 (measurable, deterministic); keep **C3** as an *advanced bonus*
   for fast finishers if its pilot is clean
4. **C4 – The AI assistant is up, but not working** (AI dependency); fallback **A4** if per-subscription model access
   is a problem

Reserves: **A5** (best substitute for any round that fails its pilot), A3, A6. A1 only if the AKS Automatic DNS pilot
gives a simple, explainable fix.

### Timing plan (3 hours)

| Block | Minutes |
|---|---|
| Welcome, environment access, `kubectl` context check | 15 |
| Round 1 – brief 5 · work 20 · debrief 8 | 33 |
| Round 2 – brief 5 · work 25 · debrief 8 | 38 |
| Break | 10 |
| Round 3 – brief 5 · work 25 · debrief 8 | 38 |
| Round 4 – brief 5 · work 25 · debrief 8 | 38 |
| Wrap-up, scores, prizes | 8 |
| **Total** | **180** |

All challenges are pre-deployed side by side in separate namespaces of one cluster per attendee, so rounds are
independent: no rebuild between rounds, and participants can move on even if they didn't finish (review comments
C3/C4). Each challenge resets on its own (re-run the begin-state deploy for that ID).

## Platform findings that affect every challenge

| Finding | Impact | How the code handles it |
|---|---|---|
| **Deployment safeguards are enforced and can't be lowered on Automatic**: probes required (deny), CPU/memory floors 100m/100Mi (mutate), anti-affinity for replicas > 1 (mutate), `:latest` denied. PDBs are **not** checked. | Faults must not be "auto-fixed" or blocked by policy (review comment C5). | Every container sets probes and explicit resources; A2's fault sits exactly at the 100m floor; multi-replica workloads pre-set topology spread. No challenge relies on something safeguards rewrite. |
| **Managed system node pools + node auto-provisioning** are always on. | No node pools to size; workload nodes appear on demand (≤ 5 min SLA). | Nothing to configure; C3 uses a dedicated NodePool. |
| **Local accounts disabled, Azure RBAC for Kubernetes** – `kubectl` needs *Azure Kubernetes Service RBAC Cluster Admin* (Owner is not enough). | Students and scoring scripts need the data-plane role. | All approaches grant it on the resource group *before* creating the cluster. |
| **LocalDNS on by default** (pods resolve via 169.254.10.10/11). | Changes the DNS path for A1. | A1 end state allows both LocalDNS and kube-dns; marked as a pilot gate. |
| **Gateway API is on by default only for Automatic ≥ 1.36**; the current default version is 1.35. | C2 needs the managed CRDs and the `approuting-istio` class. | Enabled explicitly in all approaches (`--enable-gateway-api --enable-app-routing-istio` / azapi `ingressProfile`). |
| **Regional SKU restrictions differ per subscription** (the test subscription can't use v5/v6 x64 sizes in eastus2). | NAP picks from what's allowed; C3's fix must name allowed sizes. | Default region westus3; C3 end state spans v5/v6/v7. Check Skillable subscriptions the same way (`az vm list-skus`). |
| **Images**: store v2.2.0 from GHCR, fixtures on MCR Azure Linux images; RabbitMQ 4.x only on Docker Hub. | Anonymous Docker Hub pulls (3 per environment). | Acceptable for testing; for Skillable consider importing to ACR. |
| **`aks-preview` extension** (installed on the test workstation) overrides `az aks` with preview behaviour. | Possible preview-only errors. | Scripts bypass extensions for `az aks create/update`. |

## Pilot gates – confirm on the first Azure deployment

- [ ] AKS Automatic creation (hosted system pool, Gateway API, App Routing Istio) succeeds with all three approaches; record creation time.
- [ ] Safeguards accept every challenge workload; check whether bare pods (`kubectl run`, `kubectl debug`) are denied for missing probes (affects troubleshooting UX in every round).
- [ ] **C2**: gateway IP + DNS label, HTTPRoute conditions for the wrong port, gateway response code.
- [ ] **C3**: exact pod/NodePool events, provisioning latency after the fix, replay with retained nodes.
- [ ] **C4**: end-to-end call with `gpt-6-luna` and ai-service's API version; role propagation time.
- [ ] **A1**: does the seeded policy block DNS under LocalDNS, and does the end-state rule restore it?
- [ ] **A2**: recalibrate the 300 ms objective on the VM sizes NAP picks.
- [ ] **A4**: AADSTS message, propagation after the fix, negative test.
- [ ] **A6**: disk attach latency after the fix.
- [ ] Total environment footprint (nodes NAP creates with all ten challenges deployed) and deploy time.

## Method

* Requirements and review comments from the design document (pricing sections ignored as instructed).
* Platform facts researched from Microsoft Learn, the Azure CLI/REST specs, Karpenter and aks-store-demo sources;
  key behaviours reproduced locally (Docker, kind with an enforcing CNI).
* Each challenge implemented with begin/end manifests, three deployment approaches and automated scoring
  (`scoring/verify.*`) that encodes the success criteria from the document, including the "what doesn't count"
  bypasses.
