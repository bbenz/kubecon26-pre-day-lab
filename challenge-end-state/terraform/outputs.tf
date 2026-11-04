output "resource_group_name" {
  value = module.platform.resource_group_name
}

output "cluster_name" {
  value = module.platform.cluster_name
}

output "kubernetes_version" {
  value = module.platform.kubernetes_version
}

output "challenges" {
  description = "Deployed challenges and their namespaces/instructions."
  value = {
    for id in local.selected : id => "${local.challenge_dirs[id]} (end state: challenge-end-state/challenges/${local.challenge_dirs[id]}/README.md)"
  }
}

output "connect" {
  description = "Commands to point kubectl at the lab cluster."
  value       = "az aks get-credentials -g ${module.platform.resource_group_name} -n ${module.platform.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli --tenant-id ${module.platform.tenant_id} --context ${module.platform.cluster_name}"
}

output "storefront_url" {
  description = "C2 storefront through the Gateway API gateway (when c2 is deployed). New DNS labels can take a few minutes to resolve."
  value       = contains(local.selected, "c2") ? "http://${module.platform.storefront_hostname}/" : null
}

output "a2_dashboards" {
  description = "A2: where to see CPU throttling (Managed Prometheus)."
  value       = contains(local.selected, "a2") ? "Azure portal > ${module.platform.cluster_name} > Monitoring > Dashboards with Grafana > Kubernetes / Compute Resources / Pod (namespace a2-checkout)" : null
}

output "verify" {
  description = "Check challenges against their success criteria (bash or PowerShell)."
  value       = "scoring/verify.sh --context ${module.platform.cluster_name}   |   ./scoring/verify.ps1 -Context ${module.platform.cluster_name}"
}
