# -----------------------------------------------------------------------------
# Challenge C4: Microsoft Foundry (Azure OpenAI) model deployment and the
# workload identity used by the store's ai-service. Created only when c4 is
# selected. Mirrors ctf_ensure_c4_azure in shared/azure-cli-bash/lib/azure.sh.
# -----------------------------------------------------------------------------

locals {
  # The Foundry account goes to the cluster's region when that region offers the model as Global Standard, and
  # otherwise to the first of these that does: westus3, where the lab was tested, then eastus2 and swedencentral,
  # which offer the most models. Some regions offer no OpenAI models at all (westcentralus, for one).
  # aoai_location overrides it.
  aoai_fallback_locations = ["westus3", "eastus2", "swedencentral"]
  aoai_candidates         = local.enable_c4 && var.aoai_location == null ? distinct(concat([lower(replace(var.location, " ", ""))], local.aoai_fallback_locations)) : []
}

# The subscription's model catalog for each candidate region: the Global Standard SKU of the model, if offered.
data "azapi_resource_list" "aoai_models" {
  for_each  = toset(local.aoai_candidates)
  type      = "Microsoft.CognitiveServices/locations/models@2024-10-01"
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.CognitiveServices/locations/${each.key}"
  response_export_values = {
    skus = "value[?kind=='AIServices' && model.format=='OpenAI' && model.name=='${var.aoai_model_name}' && model.version=='${var.aoai_model_version}'].model.skus[].name"
  }
}

locals {
  aoai_offering = [for l in local.aoai_candidates : l if try(contains(data.azapi_resource_list.aoai_models[l].output.skus, "GlobalStandard"), false)]
  aoai_location = var.aoai_location != null ? var.aoai_location : try(local.aoai_offering[0], var.location)
}

resource "azurerm_cognitive_account" "foundry" {
  count                 = local.enable_c4 ? 1 : 0
  name                  = local.aoai_account
  location              = local.aoai_location
  resource_group_name   = azurerm_resource_group.lab.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = local.aoai_account
  # Keys off: the app must authenticate with Microsoft Entra ID (workload identity).
  local_auth_enabled = false
  tags               = local.tags

  lifecycle {
    precondition {
      condition     = var.aoai_location != null || length(local.aoai_offering) > 0
      error_message = "None of ${join(", ", local.aoai_candidates)} offers ${var.aoai_model_name} ${var.aoai_model_version} as Global Standard to this subscription. Set aoai_location to a region that does, choose another model with aoai_model_name and aoai_model_version, or leave c4 out."
    }
  }
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
