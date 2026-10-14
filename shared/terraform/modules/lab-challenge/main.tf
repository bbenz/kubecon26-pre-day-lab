# -----------------------------------------------------------------------------
# Applies one challenge's Kubernetes manifests (the same YAML files the Azure
# CLI deployments apply with kubectl):
#   1. Namespaces
#   2. Objects labelled kubecon.lab/phase=setup; setup Jobs must complete
#   3. Everything else except workloads (Services, ConfigMaps, policies, ...)
#   4. Workloads (Deployments, StatefulSets, Jobs, ...)
# Step 4 waits for step 3 because Terraform otherwise creates everything in
# parallel: a pod can start before the Service or ConfigMap it needs exists
# (for example store-front's nginx exits with "host not found in upstream").
# The kubectl deployments get the same ordering from the numbered file names.
# Placeholders such as __KEY_VAULT_URI__ are replaced with var.tokens.
# -----------------------------------------------------------------------------

locals {
  files = sort(tolist(fileset(var.manifests_dir, "*.yaml")))

  # Split every file into YAML documents and drop comment-only fragments.
  documents = flatten([
    for f in local.files : [
      for doc in split("\n---", replace(file("${var.manifests_dir}/${f}"), "\r\n", "\n")) :
      trimspace(doc) if length(trimspace(replace(doc, "/(?m)^\\s*#.*$/", ""))) > 0
    ]
  ])

  # Stable keys from the un-rendered documents (known at plan time).
  by_key = {
    for doc in local.documents :
    "${yamldecode(doc).kind}/${try(yamldecode(doc).metadata.namespace, "_")}/${yamldecode(doc).metadata.name}" => {
      kind  = yamldecode(doc).kind
      phase = try(yamldecode(doc).metadata.labels["kubecon.lab/phase"], "")
      yaml = replace(replace(replace(replace(replace(replace(replace(replace(doc,
        "__AZURE_OPENAI_ENDPOINT__", var.tokens["AZURE_OPENAI_ENDPOINT"]),
        "__AZURE_OPENAI_DEPLOYMENT__", var.tokens["AZURE_OPENAI_DEPLOYMENT"]),
        "__AZURE_OPENAI_MODEL_NAME__", var.tokens["AZURE_OPENAI_MODEL_NAME"]),
        "__AI_SERVICE_CLIENT_ID__", var.tokens["AI_SERVICE_CLIENT_ID"]),
        "__KEY_VAULT_URI__", var.tokens["KEY_VAULT_URI"]),
        "__CONFIG_READER_CLIENT_ID__", var.tokens["CONFIG_READER_CLIENT_ID"]),
        "__STOREFRONT_DNS_LABEL__", var.tokens["STOREFRONT_DNS_LABEL"]),
      "__STOREFRONT_HOSTNAME__", var.tokens["STOREFRONT_HOSTNAME"])
    }
  }

  workload_kinds = ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"]

  namespaces = { for k, v in local.by_key : k => v if v.kind == "Namespace" }
  setup      = { for k, v in local.by_key : k => v if v.kind != "Namespace" && v.phase == "setup" }
  main       = { for k, v in local.by_key : k => v if v.kind != "Namespace" && v.phase != "setup" && !contains(local.workload_kinds, v.kind) }
  workloads  = { for k, v in local.by_key : k => v if v.phase != "setup" && contains(local.workload_kinds, v.kind) }
}

resource "kubectl_manifest" "namespace" {
  for_each          = local.namespaces
  yaml_body         = each.value.yaml
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
  validate_schema   = false
}

resource "kubectl_manifest" "setup" {
  for_each          = local.setup
  yaml_body         = each.value.yaml
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
  validate_schema   = false

  # Setup Jobs (for example seeding data onto a disk) must finish first.
  dynamic "wait_for" {
    for_each = each.value.kind == "Job" ? [1] : []
    content {
      condition {
        type   = "Complete"
        status = "True"
      }
    }
  }

  timeouts {
    create = var.setup_timeout
  }

  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "main" {
  for_each          = local.main
  yaml_body         = each.value.yaml
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
  validate_schema   = false

  depends_on = [kubectl_manifest.namespace, kubectl_manifest.setup]
}

resource "kubectl_manifest" "workloads" {
  for_each          = local.workloads
  yaml_body         = each.value.yaml
  server_side_apply = true
  force_conflicts   = true
  # Several challenges start broken on purpose (e.g. CrashLoopBackOff), so never
  # wait for rollouts here.
  wait_for_rollout = false
  validate_schema  = false

  depends_on = [kubectl_manifest.main]
}
