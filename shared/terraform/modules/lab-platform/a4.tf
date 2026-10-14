# -----------------------------------------------------------------------------
# Challenge A4: Key Vault with a harmless lab value, and the managed identity
# the config-reader app federates with. Created only when a4 is selected.
# The federated credential subject is the seeded fault (begin) or the fix (end).
# Mirrors ctf_ensure_a4_azure in shared/azure-cli-bash/lib/azure.sh.
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "lab" {
  count                      = local.enable_a4 ? 1 : 0
  name                       = local.key_vault_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.lab.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# Written through Azure Resource Manager (control plane), so the deploying user
# needs no Key Vault data-plane role.
resource "azapi_resource" "lab_secret" {
  count     = local.enable_a4 ? 1 : 0
  type      = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  name      = "lab-config"
  parent_id = azurerm_key_vault.lab[0].id
  body = {
    properties = {
      value = "kubecon-ctf-a4: identity without secrets works"
    }
  }
}

resource "azurerm_user_assigned_identity" "config_reader" {
  count               = local.enable_a4 ? 1 : 0
  name                = "id-ctf-config-reader"
  location            = var.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

# Least privilege: read access to this one secret only.
resource "azurerm_role_assignment" "config_reader_secret" {
  count                = local.enable_a4 ? 1 : 0
  scope                = azapi_resource.lab_secret[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.config_reader[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_federated_identity_credential" "config_reader" {
  count                     = local.enable_a4 ? 1 : 0
  name                      = "config-reader"
  user_assigned_identity_id = azurerm_user_assigned_identity.config_reader[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azapi_resource.aks.output.oidc_issuer_url
  subject                   = var.a4_federated_subject
}
