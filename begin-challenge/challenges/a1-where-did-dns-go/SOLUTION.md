# A1 · Walkthrough to the end state (facilitators)

> Spoilers. Steps 3–4 reflect the behaviour observed on AKS Automatic (Kubernetes 1.35, Azure CNI powered by
> Cilium, LocalDNS) during the Azure pilot on 2026-10-14.

## 1. Read the symptom

```bash
kubectl logs -n a1-inventory deploy/inventory-sync --tail=3
# [12:00:01] sync FAILED - could not resolve catalog-api: [Errno -3] Temporary failure in name resolution
kubectl get pods -n a1-inventory        # all Running/Ready - the app is "healthy", the dependency is not reachable
```

## 2. Separate DNS from connectivity

```bash
POD=deploy/inventory-sync
kubectl exec -n a1-inventory $POD -- getent hosts catalog-api                 # fails (after ~2-10 s)
IP=$(kubectl get svc catalog-api -n a1-inventory -o jsonpath='{.spec.clusterIP}')
kubectl exec -n a1-inventory $POD -- curl -s -m 3 http://$IP:8080/items       # works -> connectivity is fine
```

Name resolution fails, direct connectivity works → DNS traffic is being blocked.

## 3. Inspect the effective egress policy and the DNS path

```bash
kubectl get networkpolicy -n a1-inventory
kubectl get networkpolicy inventory-sync-egress -n a1-inventory -o yaml
kubectl exec -n a1-inventory $POD -- cat /etc/resolv.conf
```

* `default-deny-egress` denies all egress for every pod in the namespace.
* `inventory-sync-egress` allows only TCP 8080 to `app=catalog-api` – **no DNS**.
* `/etc/resolv.conf` shows the DNS server the pod uses. On AKS Automatic it is **LocalDNS**, a DNS cache on
  every node: `nameserver 169.254.10.11` – not the kube-dns Service IP.

## 4. Allow DNS

**Why the textbook fixes don't work here.** On AKS Automatic (Azure CNI powered by Cilium ≥ 1.17, LocalDNS),
DNS queries go to the node-local listener, and Cilium classifies that traffic as traffic to the node – the
`host` entity. A Kubernetes NetworkPolicy cannot select the node: neither "allow 53 to the `k8s-app=kube-dns`
pods" nor `ipBlock` `169.254.10.10/32` / `169.254.10.11/32` matches, and DNS stays broken (verified on Azure).
See [Is AKS Local DNS supported with Azure CNI Powered by Cilium?](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium#is-aks-local-dns-supported-with-azure-cni-powered-by-cilium).

**Option A – NetworkPolicy (expected 200-level fix, the end state).** Add a second egress rule to
`inventory-sync-egress` that names the DNS ports without a destination (keep the existing rule):

```yaml
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```bash
kubectl edit networkpolicy inventory-sync-egress -n a1-inventory
# or: kubectl apply -f challenge-end-state/challenges/a1-where-did-dns-go/manifests/30-network-policies.yaml
```

**Option B – least privilege with Cilium (stretch).** Leave the NetworkPolicy as it is and allow DNS only to
the node's LocalDNS listener with a `CiliumNetworkPolicy` (`toCIDR` covers older Cilium versions):

```bash
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: inventory-sync-dns
  namespace: a1-inventory
spec:
  endpointSelector:
    matchLabels:
      app: inventory-sync
  egress:
    - toEntities:
        - host
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    - toCIDR:
        - 169.254.10.0/24
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
EOF
```

Both pass the success criteria. Option A also lets the pod query *any* DNS server (for example `8.8.8.8:53`);
option B does not (verified on Azure) – a good debrief discussion.

Common mistakes: only UDP (large responses fall back to TCP); the textbook kube-dns rule (see above); writing
`namespaceSelector` and `podSelector` as two separate list items (that means "OR"); an egress rule with neither
`to` nor `ports` (allows everything).

## 5. Prove it – positive and negative tests from the pod

```bash
kubectl exec -n a1-inventory $POD -- getent hosts catalog-api                              # resolves
kubectl exec -n a1-inventory $POD -- curl -sf -m 5 http://catalog-api:8080/items >/dev/null && echo ok
kubectl exec -n a1-inventory $POD -- curl -s -m 4 http://ledger-api:8080/   || echo "blocked (good)"
kubectl exec -n a1-inventory $POD -- curl -s -m 4 https://www.microsoft.com || echo "blocked (good)"
scoring/verify.sh --challenges a1
```

## End state

Matches [`challenge-end-state/challenges/a1-where-did-dns-go`](../../../challenge-end-state/challenges/a1-where-did-dns-go/README.md).

## Why the common shortcuts fail

| Shortcut | Why it is rejected |
|---|---|
| Delete `default-deny-egress` | Removes the namespace isolation the change was meant to introduce. |
| `egress: [{}]` / allow all UDP | Allows DNS tunnelling/exfiltration and any UDP service; `ledger-api`/internet tests may also pass through. |
| Edit CoreDNS / kube-system | Cluster-wide change for a namespace problem; affects other teams. |
| Hard-code the catalog IP | Service IPs change; hides the policy bug. |

## Stretch objective – notes

DNS is just another egress flow: opening all UDP (or all egress) makes the symptom disappear but allows any
destination on those ports and defeats the isolation requirement. Option A is port-restricted but still lets the
pod talk DNS to any resolver (DNS tunnelling/exfiltration to an outside server); option B limits DNS to the
node's LocalDNS listener, which is the least-privilege answer on AKS Automatic. Platform detail worth
explaining in the debrief: LocalDNS (a node-local DNS cache) changes *where* DNS traffic goes, and Cilium treats
node-local destinations as the `host` entity – something only Cilium-native policies can express.
