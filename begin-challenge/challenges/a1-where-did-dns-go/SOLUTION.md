# A1 · Walkthrough to the end state (facilitators)

> Spoilers. The AKS Automatic DNS path (LocalDNS + Cilium) must be confirmed in the Azure pilot – update
> step 3/4 with the observed behaviour.

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
* `/etc/resolv.conf` shows the DNS server the pod uses: on AKS Automatic the **LocalDNS** node-local address
  (169.254.10.x); on other clusters the kube-dns Service IP (CoreDNS pods `k8s-app=kube-dns` in `kube-system`).

## 4. Allow DNS – only to the DNS path

Add a second egress rule to `inventory-sync-egress` (keep the existing one):

```yaml
    - to:
        - ipBlock:
            cidr: 169.254.10.10/32
        - ipBlock:
            cidr: 169.254.10.11/32
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```bash
kubectl edit networkpolicy inventory-sync-egress -n a1-inventory
# or: kubectl apply -f challenge-end-state/challenges/a1-where-did-dns-go/manifests/30-network-policies.yaml
```

Common mistakes: only UDP (large responses fall back to TCP), `namespaceSelector` and `podSelector` as two
separate list items (that means "OR" – all of kube-system *or* any kube-dns pod in this namespace), or
`k8s-app: coredns` (the label is `kube-dns`).

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
destination on those ports – including exfiltration over DNS to arbitrary resolvers – and defeats the isolation
requirement. The secure fix is the narrowest rule: port 53 (UDP+TCP) only to the cluster's DNS endpoints.
