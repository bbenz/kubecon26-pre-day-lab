variable "subscription_id" {
  description = "Azure subscription ID. Leave null to use the ARM_SUBSCRIPTION_ID environment variable."
  type        = string
  default     = null
}

variable "challenges" {
  description = "Challenge IDs to deploy (c1 c2 c3 c4 a1 a2 a3 a4 a5 a6) or [\"all\"]."
  type        = list(string)
  default     = ["all"]
  validation {
    condition     = alltrue([for c in var.challenges : contains(["all", "c1", "c2", "c3", "c4", "a1", "a2", "a3", "a4", "a5", "a6"], lower(c))])
    error_message = "Valid challenge IDs: all, c1, c2, c3, c4, a1, a2, a3, a4, a5, a6."
  }
}

variable "location" {
  description = "Azure region (AKS Automatic must be available; see docs/prerequisites.md)."
  type        = string
  default     = "westus3"
}

variable "resource_group_name" {
  description = "Resource group for this environment. Do not reuse a group managed by another deployment (bash/PowerShell or the other Terraform state)."
  type        = string
  default     = "rg-kubecon-ctf-end-tf"
}

variable "cluster_name" {
  description = "AKS Automatic cluster name; also the kubectl context name. Default: aks-<resource group without rg->."
  type        = string
  default     = null
}

variable "aoai_location" {
  description = "Region for the C4 Microsoft Foundry account. Default: same as location."
  type        = string
  default     = null
}

variable "aoai_model_name" {
  description = "Model for the C4 store assistant."
  type        = string
  default     = "gpt-6-luna"
}

variable "aoai_model_version" {
  description = "Model version for the C4 store assistant."
  type        = string
  default     = "2026-09-22"
}

variable "aoai_deployment_name" {
  description = "Model deployment name (must differ from the model name, otherwise C4 has no fault)."
  type        = string
  default     = "store-assistant"
}

variable "aoai_capacity" {
  description = "GlobalStandard capacity in thousands of tokens per minute."
  type        = number
  default     = 50
}
