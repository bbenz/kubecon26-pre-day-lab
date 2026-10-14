# -----------------------------------------------------------------------------
# Challenge C4: Microsoft Foundry (Azure OpenAI) model deployment and the
# workload identity used by the store's ai-service. Created only when c4 is
# selected. Mirrors ctf_ensure_c4_azure in shared/azure-cli-bash/lib/azure.sh.
# -----------------------------------------------------------------------------

resource "azurerm_cognitive_account" "foundry" {
  count                 = local.enable_c4 ? 1 : 0
  name                  = local.aoai_account
  location              = var.aoai_location
  resource_group_name   = azurerm_resource_group.lab.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = local.aoai_account
  # Keys off: the app must authenticate with Microsoft Entra ID (workload identity).
  local_auth_enabled = false
  tags               = local.tags
}

resource "azurerm_cognitive_deployment" "store_assistant" {
  count                = local.enable_c4 ? 1 : 0
  name                 = var.aoai_deployment_name
  cognitive_account_id = azurerm_cognitive_account.foundry[0].id

  model {
    format  = "OpenAI"
    name    = var.aoai_model_name
    version = var.aoai_model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.aoai_capacity
  }
}

resource "azurerm_user_assigned_identity" "ai_service" {
  count               = local.enable_c4 ? 1 : 0
  name                = "id-ctf-ai-service"
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "ai_service_openai_user" {
  count                = local.enable_c4 ? 1 : 0
  scope                = azurerm_cognitive_account.foundry[0].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.ai_service[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_federated_identity_credential" "ai_service" {
  count                     = local.enable_c4 ? 1 : 0
  name                      = "ai-service"
  user_assigned_identity_id = azurerm_user_assigned_identity.ai_service[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azapi_resource.aks.output.oidc_issuer_url
  subject                   = "system:serviceaccount:c4-assistant:ai-service"
}
