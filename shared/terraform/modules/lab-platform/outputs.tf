output "resource_group_name" {
  description = "Lab resource group."
  value       = azurerm_resource_group.lab.name
}

output "cluster_name" {
  description = "AKS Automatic cluster name."
  value       = azapi_resource.aks.name
}

output "cluster_id" {
  description = "AKS Automatic cluster resource ID."
  value       = azapi_resource.aks.id
}

output "kubernetes_version" {
  description = "Kubernetes version the cluster runs."
  value       = azapi_resource.aks.output.kubernetes_version
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer (workload identity federation)."
  value       = azapi_resource.aks.output.oidc_issuer_url
}

output "kube_host" {
  description = "Kubernetes API server URL. Available once RBAC propagation wait is over."
  value       = local.kubeconfig.clusters[0].cluster.server
  depends_on  = [time_sleep.rbac_propagation]
}

output "kube_cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = local.kubeconfig.clusters[0].cluster["certificate-authority-data"]
  sensitive   = true
}

output "storefront_hostname" {
  description = "Public hostname of the C2 storefront gateway."
  value       = local.storefront_hostname
}

# Values substituted into the challenge manifests (placeholders __NAME__).
output "manifest_tokens" {
  description = "Placeholder values for the challenge manifests."
  value = {
    AZURE_OPENAI_ENDPOINT   = local.enable_c4 ? "https://${local.aoai_account}.openai.azure.com/" : ""
    AZURE_OPENAI_DEPLOYMENT = var.aoai_deployment_name
    AZURE_OPENAI_MODEL_NAME = var.aoai_model_name
    AI_SERVICE_CLIENT_ID    = local.enable_c4 ? azurerm_user_assigned_identity.ai_service[0].client_id : ""
    KEY_VAULT_URI           = local.enable_a4 ? azurerm_key_vault.lab[0].vault_uri : ""
    CONFIG_READER_CLIENT_ID = local.enable_a4 ? azurerm_user_assigned_identity.config_reader[0].client_id : ""
    STOREFRONT_DNS_LABEL    = local.storefront_dns_label
    STOREFRONT_HOSTNAME     = local.storefront_hostname
  }
}

# Anything the workloads need from Azure must exist before manifests are applied.
output "ready" {
  description = "Depend on this to wait for every Azure dependency of the challenges."
  value       = "ready"
  depends_on = [
    time_sleep.rbac_propagation,
    azurerm_cognitive_deployment.store_assistant,
    azurerm_role_assignment.ai_service_openai_user,
    azurerm_federated_identity_credential.ai_service,
    azurerm_role_assignment.config_reader_secret,
    azurerm_federated_identity_credential.config_reader,
  ]
}
