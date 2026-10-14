# -----------------------------------------------------------------------------
# Shared platform for the KubeCon AKS capture-the-flag lab:
# resource group, AKS Automatic cluster and Kubernetes data-plane access.
# Mirrors the Azure CLI deployment (shared/azure-cli-bash/lib/azure.sh).
# -----------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

locals {
  # Deterministic, globally unique names - same algorithm as the bash and
  # PowerShell deployments: first 6 hex chars of sha1("<subscription>/<rg>").
  suffix               = substr(sha1("${data.azurerm_client_config.current.subscription_id}/${var.resource_group_name}"), 0, 6)
  aoai_account         = "aoai-ctf-${local.suffix}"
  key_vault_name       = "kv-ctf-${local.suffix}"
  storefront_dns_label = "ctf-store-${local.suffix}"
  storefront_hostname  = "${local.storefront_dns_label}.${var.location}.cloudapp.azure.com"
  enable_c4            = contains(var.challenges, "c4")
  enable_a4            = contains(var.challenges, "a4")
  tags = {
    purpose     = "kubecon-ctf"
    "lab-state" = var.lab_state
  }
  aks_api_version = "2026-05-01"
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# AKS Automatic disables local accounts and uses Azure RBAC for Kubernetes
# authorization, so kubectl (and the kubectl Terraform provider) needs this
# role - subscription Owner is not enough. It is granted on the resource group
# *before* the cluster exists, so it has propagated by the time the cluster is
# ready (and it cannot collide with an assignment AKS makes on the cluster).
resource "azurerm_role_assignment" "cluster_admin" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The AKS Automatic cluster. azapi is used so the request mirrors the Azure CLI
# flags exactly: az aks create --sku automatic --enable-hosted-system
#   --enable-gateway-api --enable-app-routing-istio
resource "azapi_resource" "aks" {
  type      = "Microsoft.ContainerService/managedClusters@${local.aks_api_version}"
  name      = var.cluster_name
  parent_id = azurerm_resource_group.lab.id
  location  = var.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      name = "Automatic"
      tier = "Standard"
    }
    properties = {
      # Managed system node pool: system components run on AKS-managed nodes.
      hostedSystemProfile = {
        enabled = true
      }
      ingressProfile = {
        # Managed Gateway API CRDs (challenge C2).
        gatewayAPI = {
          installation = "Standard"
        }
        # Istio-based Gateway API implementation of the application routing add-on
        # (GatewayClass "approuting-istio").
        webAppRouting = {
          enabled = true
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  response_export_values = {
    oidc_issuer_url    = "properties.oidcIssuerProfile.issuerUrl"
    fqdn               = "properties.fqdn"
    kubernetes_version = "properties.currentKubernetesVersion"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

# User kubeconfig (Microsoft Entra ID / kubelogin format): only the API server
# address and CA certificate are used - authentication goes through kubelogin.
resource "azapi_resource_action" "user_credentials" {
  type                             = "Microsoft.ContainerService/managedClusters@${local.aks_api_version}"
  resource_id                      = azapi_resource.aks.id
  action                           = "listClusterUserCredential"
  method                           = "POST"
  sensitive_response_export_values = ["kubeconfigs"]
}

locals {
  kubeconfig = yamldecode(base64decode(azapi_resource_action.user_credentials.sensitive_output.kubeconfigs[0].value))
}

resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.cluster_admin, azapi_resource_action.user_credentials]
  create_duration = var.rbac_propagation_wait
}
