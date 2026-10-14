# Authentication: the Azure CLI sign-in (az login). azurerm 4.x+ needs the
# subscription explicitly: set var.subscription_id or ARM_SUBSCRIPTION_ID.
provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

# Kubernetes access to the lab cluster. AKS Automatic only accepts Microsoft
# Entra ID tokens, obtained here with kubelogin from the Azure CLI sign-in
# (requires kubelogin on PATH: az aks install-cli).
provider "kubectl" {
  host                   = module.platform.kube_host
  cluster_ca_certificate = base64decode(module.platform.kube_cluster_ca_certificate)
  load_config_file       = false
  # The cluster does not exist yet during the first plan: connect only when needed.
  lazy_load = true
  # Retries absorb short delays right after cluster creation (RBAC propagation).
  apply_retry_count = 6

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    # 6dae42f8-... is the well-known AKS Microsoft Entra server application ID.
    args = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}
