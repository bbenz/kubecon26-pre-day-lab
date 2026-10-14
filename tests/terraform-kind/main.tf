# -----------------------------------------------------------------------------
# Local smoke test (no Azure needed) of the Terraform challenge module
# (shared/terraform/modules/lab-challenge) against a kind cluster.
#
#   kind create cluster --name ctf
#   cd tests/terraform-kind && terraform init
#   terraform apply -var state=begin   # then: scoring/verify.sh --context kind-ctf --quick  (NOT PASSED)
#   terraform apply -var state=end     # then: scoring/verify.sh --context kind-ctf --quick  (PASSED)
#   terraform destroy
#
# Covers the Kubernetes-only challenges (C1, A1, A2, A3, A5, A6).
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
  }
}

variable "state" {
  type    = string
  default = "begin"
}

variable "challenges" {
  type    = list(string)
  default = ["c1", "a1", "a2", "a3", "a5", "a6"]
}

variable "kube_context" {
  type    = string
  default = "kind-ctf"
}

provider "kubectl" {
  load_config_file = true
  config_context   = var.kube_context
}

locals {
  challenges_dir = "${path.module}/../../${var.state == "begin" ? "begin-challenge" : "challenge-end-state"}/challenges"
  challenge_dirs = {
    for d in distinct([for f in fileset(local.challenges_dir, "*/manifests/*.yaml") : split("/", f)[0]]) :
    split("-", d)[0] => d
  }
}

# kind has no Azure Disk CSI driver: alias the storage class that A6 uses.
resource "kubectl_manifest" "storage_class" {
  yaml_body = <<-EOF
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: managed-csi
    provisioner: rancher.io/local-path
    volumeBindingMode: WaitForFirstConsumer
    reclaimPolicy: Delete
  EOF
}

module "challenge" {
  source   = "../../shared/terraform/modules/lab-challenge"
  for_each = toset(var.challenges)

  challenge_id  = each.key
  manifests_dir = "${local.challenges_dir}/${local.challenge_dirs[each.key]}/manifests"
  tokens = {
    AZURE_OPENAI_ENDPOINT   = ""
    AZURE_OPENAI_DEPLOYMENT = "store-assistant"
    AZURE_OPENAI_MODEL_NAME = "gpt-6-luna"
    AI_SERVICE_CLIENT_ID    = ""
    KEY_VAULT_URI           = ""
    CONFIG_READER_CLIENT_ID = ""
    STOREFRONT_DNS_LABEL    = "ctf-store-local"
    STOREFRONT_HOSTNAME     = "store.local.test"
  }

  depends_on = [kubectl_manifest.storage_class]
}
