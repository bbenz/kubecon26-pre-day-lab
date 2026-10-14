# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - BEGIN state (challenges with their seeded
# faults), deployed with Terraform.
#
#   terraform init
#   terraform apply -var="subscription_id=$(az account show --query id -o tsv)"
#
# Participant instructions: ../challenges/<id>-*/README.md
# -----------------------------------------------------------------------------

locals {
  lab_state      = "begin"
  challenges_dir = "${path.module}/../challenges"
  all_challenges = ["c1", "c2", "c3", "c4", "a1", "a2", "a3", "a4", "a5", "a6"]
  selected       = contains([for c in var.challenges : lower(c)], "all") ? local.all_challenges : [for c in var.challenges : lower(c)]

  # c1 -> c1-the-store-wont-start, ...
  challenge_dirs = {
    for d in distinct([for f in fileset(local.challenges_dir, "*/manifests/*.yaml") : split("/", f)[0]]) :
    split("-", d)[0] => d
  }

  # A4's federated credential subject lives next to the challenge (seeded fault here).
  a4_federated_subject = trimspace(regex("(?m)^A4_FEDERATED_SUBJECT=(.+)$", file("${local.challenges_dir}/${local.challenge_dirs["a4"]}/azure.env"))[0])

  cluster_name = coalesce(var.cluster_name, "aks-${trimprefix(var.resource_group_name, "rg-")}")
}

module "platform" {
  source = "../../shared/terraform/modules/lab-platform"

  lab_state            = local.lab_state
  location             = var.location
  resource_group_name  = var.resource_group_name
  cluster_name         = local.cluster_name
  challenges           = toset(local.selected)
  aoai_location        = coalesce(var.aoai_location, var.location)
  aoai_model_name      = var.aoai_model_name
  aoai_model_version   = var.aoai_model_version
  aoai_deployment_name = var.aoai_deployment_name
  aoai_capacity        = var.aoai_capacity
  a4_federated_subject = local.a4_federated_subject
}

module "challenge" {
  source   = "../../shared/terraform/modules/lab-challenge"
  for_each = toset(local.selected)

  challenge_id  = each.key
  manifests_dir = "${local.challenges_dir}/${local.challenge_dirs[each.key]}/manifests"
  tokens        = module.platform.manifest_tokens

  depends_on = [module.platform]
}
