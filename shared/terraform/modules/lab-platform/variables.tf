variable "lab_state" {
  description = "Which lab state this environment represents: begin or end (used for tags)."
  type        = string
  validation {
    condition     = contains(["begin", "end"], var.lab_state)
    error_message = "lab_state must be begin or end."
  }
}

variable "location" {
  description = "Azure region for the resource group, AKS Automatic cluster, Key Vault and identities."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the lab environment."
  type        = string
}

variable "cluster_name" {
  description = "AKS Automatic cluster name (also used as the kubectl context name)."
  type        = string
}

variable "challenges" {
  description = "Selected challenge IDs. Azure services for C4 (Foundry) and A4 (Key Vault) are only created when selected."
  type        = set(string)
}

variable "aoai_location" {
  description = "Region for the Microsoft Foundry (Azure OpenAI) account used by C4."
  type        = string
}

variable "aoai_model_name" {
  description = "Model for the C4 store assistant deployment."
  type        = string
}

variable "aoai_model_version" {
  description = "Model version for the C4 store assistant deployment."
  type        = string
}

variable "aoai_deployment_name" {
  description = "Name of the model deployment the store assistant should use (C4 starts with the stale name store-assistant-gpt41)."
  type        = string
}

variable "aoai_capacity" {
  description = "GlobalStandard capacity in thousands of tokens per minute."
  type        = number
}

variable "a4_federated_subject" {
  description = "Subject of the A4 federated identity credential (the seeded fault in the begin state, the fix in the end state)."
  type        = string
}

variable "rbac_propagation_wait" {
  description = "Extra wait after cluster creation so the Kubernetes RBAC role assignment is in effect before manifests are applied."
  type        = string
  default     = "90s"
}
