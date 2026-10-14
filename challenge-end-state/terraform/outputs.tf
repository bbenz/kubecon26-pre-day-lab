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
  value       = "az aks get-credentials -g ${module.platform.resource_group_name} -n ${module.platform.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli --context ${module.platform.cluster_name}"
}

output "storefront_url" {
  description = "C2 storefront through the Gateway API gateway (when c2 is deployed)."
  value       = contains(local.selected, "c2") ? "http://${module.platform.storefront_hostname}/" : null
}

output "verify" {
  description = "Check challenges against their success criteria (bash or PowerShell)."
  value       = "scoring/verify.sh --context ${module.platform.cluster_name}   |   ./scoring/verify.ps1 -Context ${module.platform.cluster_name}"
}
