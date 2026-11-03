# -----------------------------------------------------------------------------
# Azure Monitor managed service for Prometheus (challenge A2: CPU throttling in
# the cluster's "Dashboards with Grafana" view).
# AKS Automatic turns Managed Prometheus on when a cluster is created with the
# Azure CLI or the portal; through the API (azapi) the cluster only enables the
# metrics agent (azureMonitorProfile in main.tf) and the data collection
# resources are created here, following the official Terraform onboarding
# template: https://github.com/Azure/prometheus-collector/tree/main/AddonTerraformTemplate
# Recording rules: monitoring-rules.tf. Everything stays in the lab resource group.
# -----------------------------------------------------------------------------

locals {
  amw_name    = "amw-ctf-${local.suffix}"
  msprom_name = "MSProm-${var.location}-${var.cluster_name}"
}

resource "azurerm_monitor_workspace" "lab" {
  name                = local.amw_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = substr(local.msprom_name, 0, 44)
  resource_group_name = azurerm_resource_group.lab.name
  location            = var.location
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = substr(local.msprom_name, 0, 64)
  resource_group_name         = azurerm_resource_group.lab.name
  location                    = var.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  description                 = "DCR for Azure Monitor Metrics Profile (Managed Prometheus)"
  tags                        = local.tags

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.lab.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = local.msprom_name
  target_resource_id      = azapi_resource.aks.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "Association of data collection rule. Deleting this association will break the data collection for this AKS Cluster."
}
