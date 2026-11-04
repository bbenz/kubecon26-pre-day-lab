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
    for id in local.selected : id => "${local.challenge_dirs[id]} (instructions: begin-challenge/challenges/${local.challenge_dirs[id]}/README.md)"
  }
}

output "connect" {
  description = "Commands to point kubectl at the lab cluster."
  value       = "az aks get-credentials -g ${module.platform.resource_group_name} -n ${module.platform.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli --tenant-id ${module.platform.tenant_id} --context ${module.platform.cluster_name}"
}

output "storefront_url" {
  description = "C2: the storefront's public URL after the migration. It resolves once the Gateway API gateway publishes the DNS label (the cutover); until then the storefront is reached through Ingress-NGINX (see the C2 README)."
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
