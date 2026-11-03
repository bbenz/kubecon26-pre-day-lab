# Feasibility assessment – KubeCon AKS capture-the-flag lab

Evaluation of the ten candidate challenges from *AKS Capture the Flag Lab Approach and Azure Requirements – v2*
(C1–C4 proposed core, A1–A6 alternates). The question for each one: can it be **built reliably** on AKS Automatic,
and can a participant with **200-level** Kubernetes/Azure knowledge **finish it within the round** with minimal
friction? Each challenge's README has the detailed assessment; this page summarises them.

> **Status (2026-10-14):** code complete for all ten challenges in three deployment approaches (Azure CLI bash,
> Azure CLI PowerShell, Terraform), and **piloted on Azure**: the BEGIN state was deployed with PowerShell (re-run
> with bash) and the END state with Terraform, both on AKS Automatic 1.35 in westus3. Every challenge fails as
> designed in the begin state and passes in the end state; the pilot found and fixed several platform behaviours
> (see *Platform findings* and *Pilot gates* below), including a redesign of C4's fault and of A1's expected fix.
>
> **Update (2026-11-03):** after team feedback, **C2** became an Ingress-NGINX → Gateway API migration (application
> routing add-on, `ingress2gateway`, AI-assisted) and **A2** now uses the Managed Prometheus dashboards; both were
> re-validated on Azure (AKS Automatic 1.36) – see *Changes after the team review* below.

## Summary

| ID | Challenge | Built reliably on AKS Automatic? | 200-level fit | Expected time (design) | Main risk | Validated | Opinion |
|---|---|---|---|---|---|---|---|
| **C1** | The store won't start | **High** – deterministic crash, no Azure deps | Good | 10–15 (15–20) | Low | Local ✔ · Azure ✔ | **Keep – round 1** |
| **C2** | Move the storefront to Gateway API | **High** – managed NGINX and Gateway API side by side; `ingress2gateway` + 3 adaptations; DNS cutover in ~20 s | Good (guided migration; new Gateway API vocabulary) | 25–30 (20–25) | NGINX support window ends Nov 2026; participants need `ingress2gateway` and an AI assistant; DNS negative caching | Azure ✔ | **Keep – round 2** |
| **C3** | Capacity that never arrives | **Medium–high** – deterministic; NAP launched the fixed pool's node ~1 min after the fix | Stretch (Karpenter + VM naming) | 20–30 (20–25) | Karpenter's pod event is misleading; knowledge gap; SKU restrictions | Azure ✔ | **Advanced bonus; A2 in its core slot** |
| **C4** | The AI assistant is up, but not working | **High** – single fault, Entra auth (fault redesigned in the pilot) | Good | 10–20 (20–25) | Model quota/availability per subscription | Azure ✔ | **Keep – round 4**; fallback A4 |
| **A1** | Where did DNS go? | **Medium–high** – deterministic, but the textbook fix fails on AKS Automatic | Medium-low (medium with hint 4) | 20–30 (20–25) | LocalDNS + Cilium `host` entity defeat the classic rules | Local ✔ · Azure ✔ | Advanced alternate only |
| **A2** | Fast yesterday, slow today | **High** – p95 2.6 s (begin) vs 0.19 s (end) with background traffic; throttling visible in Managed Prometheus | Good | 20–25 (20–25) | Metric delay 1–3 min; dashboard access needs read on the Azure Monitor workspace data | Local ✔ · Azure ✔ | **Strong alternate – first substitute for C3** |
| **A3** | Ready for maintenance? | **High** – PDBs untouched by safeguards | Good (slightly easy) | 10–15 (20–25) | Low | Local ✔ · Azure ✔ | Reserve / easy round |
| **A4** | Identity without secrets | **High** – clear AADSTS700213 evidence | Medium | 15–20 (20–25) | Student needs Azure rights on the identity | Azure ✔ | **Swap-in for C4** |
| **A5** | Running is not ready | **High** – 144 failed requests (begin) vs 0 (end) | Very good | 15–20 (15–20) | Low | Local ✔ · Azure ✔ | **Strong alternate** (great for 200-level) |
| **A6** | The data survived, the application didn't | **High** | Good (slightly easy) | 10–15 + attach (20–25) | Low | Local ✔ · Azure ✔ | Reserve |

Times are investigation minutes (excluding briefing, debrief and reset); the design target from the document is in
parentheses.

## Recommended line-up (four rounds, 200-level audience)

1. **C1 – The store won't start** (warm-up: logs, ConfigMaps, rollouts)
2. **C2 – Move the storefront to Gateway API** (Ingress-NGINX → Gateway API with `ingress2gateway` and AI – topical
   after the Ingress-NGINX retirement, and a showcase for the application routing add-on)
3. **A2 – Fast yesterday, slow today** in place of C3 (measurable, deterministic, Managed Prometheus dashboards);
   keep **C3** as an *advanced bonus*
   for fast finishers (its pilot is technically clean, but Karpenter vocabulary and its misleading pod event make it
   a stretch for 200-level)
4. **C4 – The AI assistant is up, but not working** (AI dependency); fallback **A4** if per-subscription model access
   is a problem

Reserves: **A5** (best substitute for any round), A3, A6. A1 works on AKS Automatic, but the familiar NetworkPolicy
fix doesn't (LocalDNS + Cilium) – use it for an advanced group or release its hint 4 early.

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
| **Safeguards vs. ad-hoc debugging (verified):** a bare `kubectl run` pod is **denied** (no resource requests; missing probes only warn); `kubectl debug --profile=general` is **denied** by AKS's baseline policy (`SYS_PTRACE`). `kubectl debug <pod> --profile=baseline` (or `restricted`) and `kubectl run ... --overrides` with resource requests work. Every apply prints "anti-affinity and topology spread constraints added" warnings. | Participants reaching for a debug pod hit a wall. | Walkthroughs use `kubectl exec` into existing pods; tips in [begin-challenge/README.md](begin-challenge/README.md). |
| **Managed system node pools + node auto-provisioning** are always on. | No node pools to size; workload nodes appear on demand. | Nothing to configure; C3 uses a dedicated NodePool. Observed footprint per environment: 2–3 NAP nodes (`Standard_D4als_v6`) plus the system-surge node. |
| **Local accounts disabled, Azure RBAC for Kubernetes** – `kubectl` needs *Azure Kubernetes Service RBAC Cluster Admin* (Owner is not enough). | Students and scoring scripts need the data-plane role. | All approaches grant it on the resource group *before* creating the cluster (worked first time; no propagation wait). |
| **LocalDNS on by default** (pods resolve via `169.254.10.11`, `serveStale: Immediate` for 1 h). Cilium treats it as the `host` entity. | A1's classic fixes don't apply; after a Service is re-created (challenge reset) the first lookup on a node can return its **old** IP – nginx front ends kept proxying to a dead address (HTTP 504). | A1 redesigned (see its README); `warm-dns-cache` init container in store-front/store-admin. |
| **Gateway API is on by default only for Automatic ≥ 1.36**; clusters created earlier (1.35 was the default in October) don't have it. | C2 needs the managed CRDs and the `approuting-istio` class. | Enabled explicitly in all approaches (`--enable-gateway-api --enable-app-routing-istio` / azapi `ingressProfile`). |
| **Application routing NGINX:** enabling it is allowed, but Microsoft-supported security patches end in **November 2026** (the event month). The gateway names its Deployment/Service `<gateway>-approuting-istio`, so a Gateway named after the IngressClass (as `ingress2gateway` does) is never programmed. | C2's migration source could stop being deployable; the tool's draft needs adapting. | All approaches enable NGINX explicitly (`--enable-app-routing` / `az aks approuting enable` / azapi `webAppRouting`); re-check before the event. The adaptation is part of the challenge (hint 2). |
| **Foundry (`AIServices`) accounts answer requests addressed to a bare model name**, even for models that aren't deployed. | C4's original fault (model name instead of deployment name) didn't reproduce. | C4 now starts with a retired deployment name; scoring requires the provisioned deployment. |
| **Regional SKU restrictions differ per subscription** (the test subscription can't use v5/v6 x64 sizes in eastus2). | NAP picks from what's allowed; C3's fix must name allowed sizes. | Default region westus3; C3 end state spans v5/v6/v7. Check Skillable subscriptions the same way (`az vm list-skus`). |
| **`az aks create --sku automatic` (CLI)**: sends `~/.ssh/id_rsa.pub` when present (rejected for hosted system pools) and turns on Container Insights and Managed Prometheus itself – by default with workspaces in `DefaultResourceGroup-<region>`, outside the lab RG. The Terraform (azapi) cluster gets no monitoring unless the data collection resources are declared. | First CLI deployment failed; extra RG to clean up; monitoring differed by approach. | `--no-ssh-key` added. Since 2026-11-03 the CLI deployments pass lab-RG workspaces (`amw-ctf-<id>`, `law-ctf-<id>`) and Terraform declares Managed Prometheus (workspace, DCE/DCR/DCRA, recording rules) – A2 uses it in every approach. |
| **Viewing Managed Prometheus data** (portal dashboards, Prometheus explorer) needs read access to the Azure Monitor workspace's data. A subscription Owner (via group, no extra role) could query it; the documented role for narrower access is *Monitoring Data Reader* on the workspace. | A Skillable lab user with a restricted role may see no data. | Documented in A2 and the prerequisites; `kubectl top` and `/stats` remain as fallbacks. |
| **Images**: store v2.2.0 from GHCR, fixtures on MCR Azure Linux images; RabbitMQ 4.x only on Docker Hub. | Anonymous Docker Hub pulls (3 per environment). | Acceptable for testing; for Skillable consider importing to ACR. |
| **Store demo `order-service` doesn't reconnect to RabbitMQ** when RabbitMQ is rescheduled after it (node auto-upgrade, NAP consolidation). Orders then hang – the storefront returns HTTP 504 on `POST /api/orders` – while `/health` stays green. Seen on the long-running end environment (2026-11-03) after the 30 Oct auto-upgrade, and NAP consolidation moved pods again during testing. | C1's order check (and any manual order in C2/C4) can fail hours after a correct fix, through no fault of the participant. | Workaround: `kubectl rollout restart deployment/order-service -n <namespace>`. **Open:** consider `karpenter.sh/do-not-disrupt: "true"` on the RabbitMQ and order-service pods for the event, or a check that restarts order-service when its broker moves. |
| **`aks-preview` extension** (installed on the test workstation) overrides `az aks` with preview behaviour. | Possible preview-only errors. | Scripts bypass extensions for `az aks create/update`. |

## Pilot gates – results of the first Azure deployment (2026-10-14, westus3, AKS Automatic 1.35.8)

- [x] **AKS Automatic creation** (hosted system pool, Gateway API, App Routing Istio): Terraform/azapi 9m44s; CLI
  ~10 min plus ~1.5–5 min of client-side monitoring setup. CLI needed `--no-ssh-key` (fixed). Whole environment
  (cluster + Azure services + ten challenges): ~15–20 min per approach.
- [x] **Safeguards**: every challenge workload accepted. Bare `kubectl run` pods are denied (no resource requests);
  `kubectl debug` works with `--profile=baseline`/`restricted` – documented as participant tips.
- [x] **C2** (the original "broken route" version, replaced on 2026-11-03): gateway IP + DNS label work; the Istio
  controller reports the bad route as `Accepted`/`ResolvedRefs=True`; gateway answers HTTP 500 (`server: istio-envoy`);
  access log shows `cluster_not_found` / `NC`.
- [x] **C3**: begin – NodePool `READY=True`, event `NoCompatibleInstanceTypes`; pod events from the scheduler and a
  misleading Karpenter hint (`label "kubecon.lab/pool" does not have known values (typo of "karpenter.sh/nodepool"?)`).
  End – node launched and batch finished ~2 min after the fix. The finished pod disappears with its node after
  `consolidateAfter` (10 min); scoring handles it.
- [x] **C4**: end-to-end call with `gpt-6-luna` and API version `2024-12-01-preview` works; no role propagation wait.
  **Original fault invalid** (model names resolve) → redesigned to a retired deployment name.
- [x] **A1**: the seeded policy blocks DNS; the original end-state rule did **not** restore it (LocalDNS = Cilium
  `host` entity) → end state changed to a port-only DNS rule; `CiliumNetworkPolicy` `toEntities: [host]` documented as
  the least-privilege option. Both verified.
- [x] **A2**: begin p95 ≈ 1.7 s, end p95 ≈ 175–185 ms on `Standard_D4als_v6` – the 300 ms objective needs no change.
- [x] **A4**: `invalid_client: AADSTS700213 ... subject 'system:serviceaccount:a4-config:config-reader'`; end state reads
  the secret; negative test holds.
- [x] **A6**: seed Job including disk provisioning ~1.5 min; records-api Ready 21 s after the fix.
- [x] **Footprint**: 2–3 NAP nodes (`Standard_D4als_v6`) + 1 system-surge node per environment (managed system pool
  not counted), plus a transient C3 node.
- [ ] Skillable: repeat the region/SKU/model-quota checks for the Skillable subscriptions. The lab now stays inside
  one resource group with every approach (CLI monitoring workspaces moved into the lab RG on 2026-11-03).

## Changes after the team review (2026-11-03)

Pilot feedback: the challenges were good Kubernetes troubleshooting but showed little of AKS itself. Suggested and
implemented:

| Change | What was built | Azure validation (westus3, AKS Automatic 1.36.4) |
|---|---|---|
| **C2 → Ingress-NGINX to Gateway API migration** with the application routing add-on, `ingress2gateway` (Kubernetes SIG Network) and an AI assistant | Begin: the storefront behind an Ingress on the add-on's managed NGINX; the public name reserved but unpublished. End: Gateway `store-gateway` (`approuting-istio`) + HTTPRoute, DNS label on the gateway, Ingress removed. New scoring discovers participant-named objects and checks DNS cutover and decommissioning. | Full participant walkthrough on the begin environment: translation (live cluster and `--input-file`), both draft pitfalls reproduced (unchanged draft: "Waiting for controller"; dotted name: `AddressNotUsable`), gateway programmed in 16 s, public DNS pointing at the gateway 18 s after the cutover (a resolver that had cached the earlier NXDOMAIN needed ~5 min), 6/9 → 8/9 → 9/9 checks along the way, bash and PowerShell scorers identical. Begin state re-deployed with bash and PowerShell (NOT PASSED); end-state PowerShell script applied in place (prunes the Ingress) → 9/9; Terraform end state (in-place cluster update) → 9/9. |
| **Application routing add-on (managed NGINX)** enabled in all approaches | `--enable-app-routing` on create; `az aks approuting enable` for existing clusters; azapi `webAppRouting.nginx`. | Enabled on the existing begin cluster (≈ 4 min). **Fresh create** in a temporary resource group with every new flag (PowerShell script) succeeded: NGINX, `approuting-istio`, Managed Prometheus and Container Insights all reporting to workspaces in the lab RG, nothing new in `DefaultResourceGroup-westus3`; C2/A2 begin state as expected; the bash cleanup removed it. |
| **A2 → Managed Prometheus dashboards** instead of only `kubectl top` | Steady background traffic (~1 checkout/s) from `loadgen`; README/SOLUTION lead with *Dashboards with Grafana*; Terraform now declares Managed Prometheus; CLI keeps the workspace in the lab RG. | Begin: `kubectl top` 27m vs 62% of CPU periods throttled in Prometheus (82% on the fresh cluster); load test p95 2.3–2.6 s (FAIL). End: p95 158–187 ms (PASS) and 0% throttled between tests (Terraform environment). PromQL confirmed the throttling/usage series and the recording rules the dashboard panels use in all three workspaces (CLI default, CLI lab-RG, Terraform). The portal dashboard layout itself still needs a visual check by a reviewer. |

Not changed (noted for a follow-up): C1 feedback – participants without Fastify knowledge may not connect
`FASTIFY_ADDRESS` with the port, and `last-applied-configuration` shows only the current (broken) value, not a
"last known good" one.

**Leaderboard (added 2026-11-03).** An optional projected leaderboard: `scoring/verify.*` on a lab VM registered by a
Skillable life cycle action records each result in a locked-down storage account (create-only token, no anonymous
access, no account keys); the instructor's laptop reads it with an Entra sign-in. Attendees need no Azure role, only
outbound HTTPS to the storage account – confirm that egress in the Skillable pilot. See
[leaderboard/README.md](leaderboard/README.md).

## Method

* Requirements and review comments from the design document (pricing sections ignored as instructed).
* Platform facts researched from Microsoft Learn, the Azure CLI/REST specs, Karpenter and aks-store-demo sources;
  key behaviours reproduced locally (Docker, kind with an enforcing CNI).
* Each challenge implemented with begin/end manifests, three deployment approaches and automated scoring
  (`scoring/verify.*`) that encodes the success criteria from the document, including the "what doesn't count"
  bypasses.
