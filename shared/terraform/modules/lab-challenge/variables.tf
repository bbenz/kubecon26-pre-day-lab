variable "challenge_id" {
  description = "Challenge ID, e.g. c1 or a4."
  type        = string
}

variable "manifests_dir" {
  description = "Folder with the challenge's Kubernetes manifests (*.yaml)."
  type        = string
}

variable "tokens" {
  description = "Values for the __PLACEHOLDER__ tokens used in the manifests (see shared/terraform/modules/lab-platform outputs)."
  type        = map(string)
}

variable "setup_timeout" {
  description = "How long to wait for setup-phase Jobs (kubecon.lab/phase=setup) to complete."
  type        = string
  default     = "20m"
}
