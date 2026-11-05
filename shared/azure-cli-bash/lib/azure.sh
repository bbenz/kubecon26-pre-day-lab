#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by the shared library
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - Azure resources (Azure CLI).
# Every function is idempotent: it creates what is missing and reuses what
# already exists, so deploy scripts can be re-run safely.
# -----------------------------------------------------------------------------

ctf_ensure_resource_group() {
  log_step "Resource group $RESOURCE_GROUP"
  if [ "$CTF_SKIP_INFRA" = true ]; then
    az group show -n "$RESOURCE_GROUP" -o none 2>/dev/null || die "Resource group $RESOURCE_GROUP not found (remove --skip-infra)"
    return 0
  fi
  # An existing resource group stays as it is: its region and tags (a lab platform's own tags, for example).
  if az group show -n "$RESOURCE_GROUP" -o none 2>/dev/null; then
    log_ok "resource group exists"
    return 0
  fi
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags purpose=kubecon-ctf "lab-state=$LAB_STATE" \
    --only-show-errors -o none
  log_ok "resource group created"
}

ctf_ensure_cluster() {
  log_step "AKS Automatic cluster $CLUSTER_NAME"
  if az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o none 2>/dev/null; then
    log_ok "cluster exists"
  elif [ "$CTF_SKIP_INFRA" = true ]; then
    die "Cluster $CLUSTER_NAME not found (remove --skip-infra)"
  else
    ctf_ensure_monitor_workspaces
    log_info "Creating the cluster - this typically takes 10-15 minutes ..."
    # --sku automatic          : AKS Automatic (NAP, Cilium, Azure RBAC, deployment safeguards,
    #                            Managed Prometheus, Container Insights, ...)
    # --enable-hosted-system   : managed system node pool (system components run on AKS-managed nodes)
    # --enable-app-routing     : application routing add-on with managed NGINX (C2 starts on Ingress-NGINX)
    # --enable-gateway-api     : managed Gateway API CRDs (C2 migrates to Gateway API)
    # --enable-app-routing-istio: Istio-based Gateway API implementation of the application routing add-on
    # --azure-monitor-workspace-resource-id / --workspace-resource-id: keep Managed Prometheus
    #                            and Container Insights data in the lab resource group (A2 dashboards)
    #                            instead of default workspaces in DefaultResourceGroup-<region>
    # --no-ssh-key             : otherwise the CLI sends ~/.ssh/id_rsa.pub when it exists, which AKS rejects
    #                            for Automatic clusters with managed system node pools (BadRequest)
    az_core aks create -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -l "$LOCATION" \
      --sku automatic --enable-hosted-system --no-ssh-key \
      --enable-app-routing --enable-gateway-api --enable-app-routing-istio \
      --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id "$AMW_ID" \
      --workspace-resource-id "$LAW_ID" \
      --tags purpose=kubecon-ctf "lab-state=$LAB_STATE" \
      --only-show-errors -o none \
      || die "az aks create failed. Check region support for AKS Automatic and vCPU quota (see docs/prerequisites.md)."
    log_ok "cluster created"
  fi
  AKS_ID=$(az_tsv aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query id)
  OIDC_ISSUER=$(az_tsv aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl)
}

# Azure Monitor workspace (Managed Prometheus metrics) and, unless "metrics-only"
# is passed, a Log Analytics workspace (Container Insights) in the lab resource
# group. Sets AMW_ID and LAW_ID. Without explicit workspaces the Azure CLI uses
# default workspaces in DefaultResourceGroup-<region>, outside the lab resource group.
ctf_ensure_monitor_workspaces() {
  if ! az monitor account show -g "$RESOURCE_GROUP" -n "$AMW_NAME" -o none 2>/dev/null; then
    az monitor account create -g "$RESOURCE_GROUP" -n "$AMW_NAME" -l "$LOCATION" --only-show-errors -o none \
      || die "Could not create the Azure Monitor workspace $AMW_NAME"
    log_ok "created Azure Monitor workspace $AMW_NAME (Managed Prometheus)"
  fi
  AMW_ID=$(az_tsv monitor account show -g "$RESOURCE_GROUP" -n "$AMW_NAME" --query id)
  [ "${1:-}" = metrics-only ] && return 0
  if ! az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$LAW_NAME" -o none 2>/dev/null; then
    az monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$LAW_NAME" -l "$LOCATION" \
      --only-show-errors -o none || die "Could not create the Log Analytics workspace $LAW_NAME"
    log_ok "created Log Analytics workspace $LAW_NAME (Container Insights)"
  fi
  LAW_ID=$(az_tsv monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$LAW_NAME" --query id)
}

# Sets CTF_PRINCIPAL_ID / CTF_PRINCIPAL_TYPE for the signed-in user or service principal.
# Object ID of the signed-in identity, from the oid claim of its own access token.
# Needs no Microsoft Graph permission, which a lab service principal (Skillable's
# cloud subscription identity, for example) often doesn't have.
ctf_token_object_id() {
  local payload
  payload=$(az_tsv account get-access-token --query accessToken 2>/dev/null | cut -d. -f2 | tr '_-' '/+')
  case $(( ${#payload} % 4 )) in 2) payload="$payload==" ;; 3) payload="$payload=" ;; esac
  { printf '%s' "$payload" | base64 -d 2>/dev/null || printf '%s' "$payload" | base64 -D 2>/dev/null; } |
    tr ',{}' '\n' | sed -n 's/^ *"oid" *: *"\([0-9a-fA-F-]*\)".*/\1/p' | head -n 1
}

ctf_signed_in_principal() {
  local type
  type=$(az_tsv account show --query user.type)
  if [ "$type" = "user" ]; then CTF_PRINCIPAL_TYPE=User; else CTF_PRINCIPAL_TYPE=ServicePrincipal; fi
  CTF_PRINCIPAL_ID=$(ctf_token_object_id)
  if [ -z "$CTF_PRINCIPAL_ID" ]; then
    if [ "$CTF_PRINCIPAL_TYPE" = User ]; then
      CTF_PRINCIPAL_ID=$(az_tsv ad signed-in-user show --query id)
    else
      CTF_PRINCIPAL_ID=$(az_tsv ad sp show --id "$(az_tsv account show --query user.name)" --query id)
    fi
  fi
  [ -n "$CTF_PRINCIPAL_ID" ] || die "Could not determine the object ID of the signed-in principal"
}

# ctf_ensure_role_assignment <principal-object-id> <principal-type> <role> <scope>
ctf_ensure_role_assignment() {
  local principal=$1 ptype=$2 role=$3 scope=$4 count err code limit attempt=1
  # Listed by scope and role, not --assignee, which needs Microsoft Graph: a lab service principal, or an
  # attendee resetting a challenge, may not be allowed to read it. Inherited assignments count.
  count=$(az_tsv role assignment list --scope "$scope" --role "$role" --include-inherited --fill-principal-name false \
    --query "length([?principalId == '$principal'])" 2>/dev/null || echo 0)
  if [ "${count:-0}" != "0" ]; then
    log_ok "'$role' already assigned"
    return 0
  fi
  # New managed identities can take a few seconds to replicate, and requests can fail on the way: those are
  # retried. A policy denial doesn't go away, and a missing permission rarely does: those stop sooner, with
  # Azure's reason.
  while :; do
    if err=$(az role assignment create --assignee-object-id "$principal" --assignee-principal-type "$ptype" \
        --role "$role" --scope "$scope" --only-show-errors -o none 2>&1); then
      log_ok "assigned '$role'"
      return 0
    fi
    err=$(printf '%s\n' "$err" | tr -d '\r')
    case $err in *RoleAssignmentExists*) log_ok "assigned '$role'"; return 0 ;; esac
    code=$(printf '%s\n' "$err" | sed -n -e '/^ERROR: (/{s/^ERROR: (\([A-Za-z]*\)).*/\1/p;q;}' -e '/^Code: /{s/^Code: \([A-Za-z]*\).*/\1/p;q;}')
    case ${code:=error} in
      RequestDisallowedByPolicy) limit=1 ;;
      AuthorizationFailed|LinkedAuthorizationFailed) limit=3 ;;
      *) limit=10 ;;
    esac
    [ "$attempt" -lt "$limit" ] || die "$(ctf_role_assignment_failure "$role" "$scope" "$code" "$err")"
    log_warn "Assigning '$role' failed with $code (attempt $attempt of $limit) - retrying in 15 seconds ..."
    attempt=$((attempt + 1))
    sleep 15
  done
}

# ctf_role_assignment_failure <role> <scope> <code> <az error output>: why a role assignment failed, and what
# to do about it.
ctf_role_assignment_failure() {
  local role=$1 scope=$2 code=$3 text=$4 role_id policy hint
  role_id=$(az_tsv role definition list --name "$role" --query '[0].name' 2>/dev/null) || role_id=""
  case $code in
    RequestDisallowedByPolicy)
      policy=$(printf '%s\n' "$text" | sed -n '/"policyAssignmentDisplayName"/{s/.*"policyAssignmentDisplayName": *"\([^"]*\)".*/\1/p;q;}')
      [ -n "$policy" ] || policy=$(printf '%s\n' "$text" | sed -n '/"policyAssignmentName"/{s/.*"policyAssignmentName": *"\([^"]*\)".*/\1/p;q;}')
      hint="Azure Policy denied the role assignment"
      [ -z "$policy" ] || hint="$hint (policy assignment '$policy')"
      hint="$hint. The subscription's policies must allow role assignments (Microsoft.Authorization/roleAssignments)"
      hint="$hint of this role: in a Skillable lab, the lab profile's access control policy (ACP)." ;;
    AuthorizationFailed|LinkedAuthorizationFailed)
      hint="The signed-in identity may not create role assignments there: it needs Owner, User Access Administrator,"
      hint="$hint or Role Based Access Control Administrator on that scope, without a condition that excludes this role." ;;
    *)
      hint=$(printf '%s\n' "$text" | sed -n '/^ERROR:/{s/^ERROR: *//p;q;}')
      [ -n "$hint" ] || hint=$(printf '%s\n' "$text" | sed -n '1p') ;;
  esac
  printf "Could not assign '%s' (role definition ID %s) on %s (%s). %s" "$role" "${role_id:-unknown}" "$scope" "$code" "$hint"
}

ctf_ensure_cluster_admin() {
  log_step "Kubernetes data-plane access (Azure RBAC)"
  log_info "AKS Automatic disables local accounts; kubectl needs '$CTF_AKS_ADMIN_ROLE' (subscription Owner is not enough)."
  if [ "$CTF_SKIP_INFRA" = true ]; then return 0; fi
  ctf_signed_in_principal
  # Granted on the resource group *before* the cluster exists: it has propagated
  # by the time the cluster is ready, and it cannot collide with an assignment
  # AKS makes on the cluster itself (same approach as the Terraform deployment).
  ctf_ensure_role_assignment "$CTF_PRINCIPAL_ID" "$CTF_PRINCIPAL_TYPE" "$CTF_AKS_ADMIN_ROLE" \
    "$(az_tsv group show -n "$RESOURCE_GROUP" --query id)"
}

ctf_get_credentials() {
  log_step "kubectl credentials (context: $KUBE_CONTEXT)"
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --context "$KUBE_CONTEXT" \
    --overwrite-existing --only-show-errors
  # Pin the context to this subscription's tenant: kubectl keeps working when
  # the Azure CLI default later points at a subscription in another tenant.
  kubelogin convert-kubeconfig -l azurecli --tenant-id "$TENANT_ID" --context "$KUBE_CONTEXT"
  log_info "Waiting for the Kubernetes RBAC role assignment to take effect (can take up to 5 minutes) ..."
  local i=0
  while [ "$i" -lt 40 ]; do
    if [ "$(k auth can-i '*' '*' --all-namespaces 2>/dev/null | tr -d '\r')" = "yes" ]; then
      log_ok "cluster-admin access confirmed"
      return 0
    fi
    i=$((i + 1))
    sleep 15
  done
  die "kubectl still has no cluster-admin access after 10 minutes. Check the '$CTF_AKS_ADMIN_ROLE' role assignment."
}

# C2: application routing add-on - managed NGINX (the Ingress-NGINX path the
# storefront starts on) and its Istio-based Gateway API implementation
# (approuting-istio, the path participants migrate the storefront to).
ctf_ensure_app_routing() {
  ctf_selected c2 || return 0
  log_step "C2: application routing add-on (managed NGINX + Gateway API with approuting-istio)"
  if ! k get ingressclass webapprouting.kubernetes.azure.com >/dev/null 2>&1; then
    [ "$CTF_SKIP_INFRA" = true ] && die "IngressClass webapprouting.kubernetes.azure.com is missing (remove --skip-infra)"
    log_info "Enabling the application routing add-on with managed NGINX (a few minutes) ..."
    az_core aks approuting enable -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --only-show-errors -o none \
      || die "az aks approuting enable failed"
  fi
  retry 40 15 k get ingressclass webapprouting.kubernetes.azure.com >/dev/null 2>&1 \
    || die "IngressClass webapprouting.kubernetes.azure.com did not appear"
  log_ok "IngressClass webapprouting.kubernetes.azure.com (managed NGINX) available"
  if ! k get gatewayclass approuting-istio >/dev/null 2>&1; then
    [ "$CTF_SKIP_INFRA" = true ] && die "GatewayClass approuting-istio is missing (remove --skip-infra)"
    log_info "Enabling managed Gateway API CRDs and the approuting-istio GatewayClass (a few minutes) ..."
    az_core aks update -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --enable-gateway-api --enable-app-routing-istio \
      --only-show-errors -o none || die "az aks update --enable-gateway-api --enable-app-routing-istio failed"
  fi
  retry 40 15 k get gatewayclass approuting-istio >/dev/null 2>&1 || die "GatewayClass approuting-istio did not appear"
  log_ok "GatewayClass approuting-istio available"
}

# A2: Managed Prometheus, for the "Dashboards with Grafana" CPU throttling view.
# Clusters created by these scripts already send metrics to the lab's Azure
# Monitor workspace; an existing cluster without metrics is connected to it.
ctf_ensure_prometheus() {
  ctf_selected a2 || return 0
  log_step "A2: Azure Monitor managed service for Prometheus"
  if [ "$(az_tsv aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query azureMonitorProfile.metrics.enabled)" = "true" ]; then
    log_ok "Managed Prometheus metrics already enabled"
    return 0
  fi
  [ "$CTF_SKIP_INFRA" = true ] && die "Managed Prometheus is not enabled on $CLUSTER_NAME (remove --skip-infra)"
  ctf_ensure_monitor_workspaces metrics-only
  log_info "Enabling Managed Prometheus (Azure Monitor workspace $AMW_NAME) - a few minutes ..."
  az_core aks update -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --enable-azure-monitor-metrics \
    --azure-monitor-workspace-resource-id "$AMW_ID" --only-show-errors -o none \
    || die "az aks update --enable-azure-monitor-metrics failed"
  log_ok "Managed Prometheus metrics enabled ($AMW_NAME)"
}

# ctf_ensure_identity <name>  -> sets IDENTITY_CLIENT_ID and IDENTITY_PRINCIPAL_ID
ctf_ensure_identity() {
  local name=$1
  if ! az identity show -g "$RESOURCE_GROUP" -n "$name" -o none 2>/dev/null; then
    [ "$CTF_SKIP_INFRA" = true ] && die "Managed identity $name not found (remove --skip-infra)"
    az identity create -g "$RESOURCE_GROUP" -n "$name" -l "$LOCATION" --only-show-errors -o none
    log_ok "created managed identity $name"
  fi
  IDENTITY_CLIENT_ID=$(az_tsv identity show -g "$RESOURCE_GROUP" -n "$name" --query clientId)
  IDENTITY_PRINCIPAL_ID=$(az_tsv identity show -g "$RESOURCE_GROUP" -n "$name" --query principalId)
}

# ctf_ensure_federated_credential <identity> <credential-name> <subject>
ctf_ensure_federated_credential() {
  local identity=$1 name=$2 subject=$3 current
  current=$(az_tsv identity federated-credential show -g "$RESOURCE_GROUP" --identity-name "$identity" -n "$name" \
    --query subject 2>/dev/null || true)
  if [ "$current" = "$subject" ]; then
    log_ok "federated credential $name -> $subject"
    return 0
  fi
  if [ -z "$current" ]; then
    az identity federated-credential create -g "$RESOURCE_GROUP" --identity-name "$identity" -n "$name" \
      --issuer "$OIDC_ISSUER" --subject "$subject" --audiences api://AzureADTokenExchange --only-show-errors -o none
  else
    az identity federated-credential update -g "$RESOURCE_GROUP" --identity-name "$identity" -n "$name" \
      --issuer "$OIDC_ISSUER" --subject "$subject" --audiences api://AzureADTokenExchange --only-show-errors -o none
  fi
  log_ok "federated credential $name -> $subject"
}

# Purges a soft-deleted Foundry/Cognitive Services account that would block re-creating the same name.
ctf_purge_deleted_aoai() {
  local id rg loc
  id=$(az_tsv cognitiveservices account list-deleted --query "[?name=='$AOAI_ACCOUNT'].id | [0]" 2>/dev/null || true)
  [ -n "$id" ] || return 0
  loc=$(printf '%s' "$id" | sed -n 's|.*/locations/\([^/]*\)/.*|\1|p')
  rg=$(printf '%s' "$id" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')
  log_info "Purging soft-deleted account $AOAI_ACCOUNT ($loc/$rg) ..."
  az cognitiveservices account purge -n "$AOAI_ACCOUNT" -g "$rg" -l "$loc" --only-show-errors -o none || true
}

# Challenge C4: Microsoft Foundry (Azure OpenAI) model deployment + workload identity for ai-service.
ctf_aoai_settled() {
  [ "$(az_tsv cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" --query properties.provisioningState)" = Succeeded ]
}

# Prints yes when the subscription's model catalog for region $1 has C4's model and version as Global Standard, no
# when it doesn't, and unknown when the catalog can't be read.
ctf_model_offered() {
  local skus
  if ! skus=$(az cognitiveservices model list -l "$1" \
      --query "[?kind=='AIServices' && model.format=='OpenAI' && model.name=='$AOAI_MODEL_NAME' && model.version=='$AOAI_MODEL_VERSION'].model.skus[].name" \
      --only-show-errors -o tsv 2>/dev/null); then
    echo unknown
    return 0
  fi
  case " $(printf '%s' "$skus" | tr '\r\n\t' '   ') " in
    *" GlobalStandard "*) echo yes ;;
    *) echo no ;;
  esac
}

# The region for C4's Foundry account, in AOAI_LOCATION: AOAI_LOCATION when it's set; otherwise the cluster's region
# when it offers the model, or the first fallback region that does.
ctf_resolve_aoai_location() {
  [ -n "$AOAI_LOCATION" ] && return 0
  local loc offered cluster_offered=unknown tried=""
  for loc in "$LOCATION" $CTF_AOAI_FALLBACK_LOCATIONS; do
    case " $tried " in *" $loc "*) continue ;; esac
    tried="${tried:+$tried, }$loc"
    offered=$(ctf_model_offered "$loc")
    if [ "$loc" = "$LOCATION" ]; then cluster_offered=$offered; fi
    if [ "$offered" = yes ]; then
      if [ "$loc" != "$LOCATION" ]; then
        if [ "$cluster_offered" = unknown ]; then
          log_info "Couldn't read the model catalog for $LOCATION: the Foundry account goes to $loc"
        else
          log_info "$LOCATION doesn't offer $AOAI_MODEL_NAME $AOAI_MODEL_VERSION as Global Standard: the Foundry account goes to $loc"
        fi
      fi
      AOAI_LOCATION=$loc
      return 0
    fi
  done
  if [ "$cluster_offered" = unknown ]; then
    log_warn "Couldn't read the model catalog for $LOCATION: the Foundry account goes there"
    AOAI_LOCATION=$LOCATION
    return 0
  fi
  die "None of $tried offers $AOAI_MODEL_NAME $AOAI_MODEL_VERSION as Global Standard to this subscription. Set AOAI_LOCATION to a region that does, choose another model with AOAI_MODEL_NAME and AOAI_MODEL_VERSION, or leave c4 out. To check a region: az cognitiveservices model list -l <region> --query \"[?model.name=='$AOAI_MODEL_NAME'].model.version\" -o tsv"
}

# Retries while the account is busy with another operation (RequestConflict); other errors fail at once. The last
# error is in CTF_AOAI_ERROR.
ctf_create_aoai_deployment() {
  local attempt=1
  CTF_AOAI_ERROR=""
  while :; do
    if CTF_AOAI_ERROR=$(az cognitiveservices account deployment create -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" \
        --deployment-name "$AOAI_DEPLOYMENT_NAME" --model-name "$AOAI_MODEL_NAME" \
        --model-version "$AOAI_MODEL_VERSION" --model-format OpenAI \
        --sku-name GlobalStandard --sku-capacity "$AOAI_CAPACITY" --only-show-errors -o none 2>&1); then
      return 0
    fi
    case "$CTF_AOAI_ERROR" in
      *RequestConflict*|*"Another operation"*) ;;
      *) printf '%s\n' "$CTF_AOAI_ERROR" >&2; return 1 ;;
    esac
    if [ "$attempt" -ge 6 ]; then printf '%s\n' "$CTF_AOAI_ERROR" >&2; return 1; fi
    log_info "The Foundry account is busy (attempt $attempt of 6) - retrying in 20 seconds ..."
    attempt=$((attempt + 1))
    sleep 20
  done
}

# Fails when this identity can't purge deleted Foundry accounts in region $1, which needs subscription-level access
# (a resource group's Owner, as in a manual Skillable run, doesn't have it): a purge of a name that doesn't exist
# fails with AuthorizationFailed then, and otherwise does nothing.
ctf_can_purge_aoai() {
  local out
  out=$(az cognitiveservices account purge -g "$RESOURCE_GROUP" -n "ctf-purge-probe-$RANDOM$RANDOM" -l "$1" \
    --only-show-errors 2>&1 || true)
  case "$out" in *AuthorizationFailed*) return 1 ;; esac
  return 0
}

ctf_ensure_c4_azure() {
  ctf_selected c4 || return 0
  log_step "C4: Microsoft Foundry model deployment and ai-service identity"
  local account_location
  account_location=$(az_tsv cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" --query location 2>/dev/null || true)
  if [ -n "$account_location" ] && [ "$CTF_SKIP_INFRA" != true ] \
      && ! az cognitiveservices account deployment show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" \
        --deployment-name "$AOAI_DEPLOYMENT_NAME" -o none 2>/dev/null \
      && [ "$(ctf_model_offered "$account_location")" = no ]; then
    # An account without the model deployment, in a region that doesn't offer the model (as a run before the
    # region check left it): delete it, so that it can be created again where the model is.
    ctf_resolve_aoai_location
    if [ "$AOAI_LOCATION" != "$account_location" ]; then
      # The name must be free again: delete, then purge. Without the access to purge, leave the account as it is,
      # rather than delete it and leave its name taken for 48 hours.
      ctf_can_purge_aoai "$account_location" \
        || die "Foundry account $AOAI_ACCOUNT is in $account_location, which doesn't offer $AOAI_MODEL_NAME $AOAI_MODEL_VERSION. To create it in $AOAI_LOCATION, it must be deleted and purged, and purging needs subscription-level access, which this identity doesn't have. With an identity that has it (Owner or Contributor of the subscription), run: az cognitiveservices account delete -g $RESOURCE_GROUP -n $AOAI_ACCOUNT; az cognitiveservices account purge -g $RESOURCE_GROUP -n $AOAI_ACCOUNT -l $account_location. Then run this again."
      log_info "Foundry account $AOAI_ACCOUNT is in $account_location, which doesn't offer $AOAI_MODEL_NAME: re-creating it in $AOAI_LOCATION ..."
      az cognitiveservices account delete -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" --only-show-errors -o none
      az cognitiveservices account purge -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" -l "$account_location" --only-show-errors -o none
      account_location=""
    fi
  fi
  if [ -z "$account_location" ]; then
    [ "$CTF_SKIP_INFRA" = true ] && die "Foundry account $AOAI_ACCOUNT not found (remove --skip-infra)"
    ctf_resolve_aoai_location
    account_location=$AOAI_LOCATION
    ctf_purge_deleted_aoai
    local err
    if ! err=$(az cognitiveservices account create -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" -l "$account_location" \
        --kind AIServices --sku S0 --custom-domain "$AOAI_ACCOUNT" --yes --only-show-errors -o none 2>&1); then
      printf '%s\n' "$err" >&2
      case "$err" in
        *CustomDomainInUse*)
          die "The name $AOAI_ACCOUNT is probably held by a deleted Foundry account (deleted in the last 48 hours), which this identity can't see or purge: that needs subscription-level access. With an identity that has it, run: az cognitiveservices account list-deleted -o table; az cognitiveservices account purge -g $RESOURCE_GROUP -n $AOAI_ACCOUNT -l <its location>. Then run this again." ;;
      esac
      die "Creating the Foundry account $AOAI_ACCOUNT failed: the error is above."
    fi
    log_ok "created Foundry account $AOAI_ACCOUNT ($account_location)"
  fi
  AOAI_ID=$(az_tsv cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" --query id)
  AZURE_OPENAI_ENDPOINT="https://${AOAI_ACCOUNT}.openai.azure.com/"
  if [ "$CTF_SKIP_INFRA" != true ]; then
    # Keys off: the app must authenticate with Microsoft Entra ID (workload identity).
    ctf_az_rest --method patch --url "https://management.azure.com${AOAI_ID}?api-version=2024-10-01" \
      --body '{"properties":{"disableLocalAuth":true}}' \
      || log_warn "could not disable key authentication on $AOAI_ACCOUNT"
    # The update is asynchronous: a model deployment created while it runs fails with RequestConflict.
    retry 30 10 ctf_aoai_settled || log_warn "Foundry account $AOAI_ACCOUNT is still updating after 5 minutes"
    if ! az cognitiveservices account deployment show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" \
        --deployment-name "$AOAI_DEPLOYMENT_NAME" -o none 2>/dev/null; then
      if ! ctf_create_aoai_deployment; then
        case "$CTF_AOAI_ERROR" in
          *SpecialFeatureOrQuotaIdRequired*|*InsufficientQuota*|*DeploymentModelNotSupported*)
            die "This subscription can't deploy $AOAI_MODEL_NAME $AOAI_MODEL_VERSION as Global Standard in $account_location: the region doesn't offer it, or there's no quota (az cognitiveservices usage list -l $account_location -o table). Set AOAI_LOCATION to another region, choose another model with AOAI_MODEL_NAME and AOAI_MODEL_VERSION, or leave c4 out." ;;
        esac
        die "The model deployment failed: the error is above."
      fi
    fi
    log_ok "model deployment '$AOAI_DEPLOYMENT_NAME' ($AOAI_MODEL_NAME $AOAI_MODEL_VERSION, GlobalStandard x$AOAI_CAPACITY)"
  fi
  ctf_ensure_identity "$AI_IDENTITY_NAME"
  AI_SERVICE_CLIENT_ID="$IDENTITY_CLIENT_ID"
  if [ "$CTF_SKIP_INFRA" != true ]; then
    ctf_ensure_role_assignment "$IDENTITY_PRINCIPAL_ID" ServicePrincipal "Cognitive Services OpenAI User" "$AOAI_ID"
    ctf_ensure_federated_credential "$AI_IDENTITY_NAME" ai-service "system:serviceaccount:c4-assistant:ai-service"
  fi
}

# Reads A4_FEDERATED_SUBJECT from <state>/challenges/a4-*/azure.env.
ctf_a4_subject() {
  local env_file
  env_file="$(ctf_challenge_dir a4)/azure.env"
  [ -f "$env_file" ] || die "Missing $env_file"
  sed -n 's/^A4_FEDERATED_SUBJECT=//p' "$env_file" | tr -d '\r' | head -n 1
}

# Challenge A4: Key Vault with a harmless lab value + managed identity federated with the app.
ctf_ensure_a4_azure() {
  ctf_selected a4 || return 0
  log_step "A4: Key Vault, managed identity and federated credential"
  if ! az keyvault show -n "$KEY_VAULT_NAME" -g "$RESOURCE_GROUP" -o none 2>/dev/null; then
    [ "$CTF_SKIP_INFRA" = true ] && die "Key Vault $KEY_VAULT_NAME not found (remove --skip-infra)"
    if [ -n "$(az_tsv keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME'].name | [0]" 2>/dev/null || true)" ]; then
      log_info "Purging soft-deleted vault $KEY_VAULT_NAME ..."
      az keyvault purge -n "$KEY_VAULT_NAME" --only-show-errors -o none || true
    fi
    az keyvault create -n "$KEY_VAULT_NAME" -g "$RESOURCE_GROUP" -l "$LOCATION" \
      --enable-rbac-authorization true --retention-days 7 --only-show-errors -o none
    log_ok "created Key Vault $KEY_VAULT_NAME (Azure RBAC)"
  fi
  KV_ID=$(az_tsv keyvault show -n "$KEY_VAULT_NAME" -g "$RESOURCE_GROUP" --query id)
  KEY_VAULT_URI=$(az_tsv keyvault show -n "$KEY_VAULT_NAME" -g "$RESOURCE_GROUP" --query properties.vaultUri)
  ctf_ensure_identity "$CONFIG_IDENTITY_NAME"
  CONFIG_READER_CLIENT_ID="$IDENTITY_CLIENT_ID"
  [ "$CTF_SKIP_INFRA" = true ] && return 0
  # The secret is written through Azure Resource Manager (control plane), so the
  # deploying user needs no Key Vault data-plane role.
  ctf_az_rest --method put --url "https://management.azure.com${KV_ID}/secrets/${CTF_SECRET_NAME}?api-version=2023-07-01" \
    --body "{\"properties\":{\"value\":\"${CTF_SECRET_VALUE}\"}}" \
    || die "Could not write secret $CTF_SECRET_NAME"
  log_ok "secret '$CTF_SECRET_NAME' written"
  # Least privilege: read access to this one secret only.
  ctf_ensure_role_assignment "$IDENTITY_PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets User" \
    "${KV_ID}/secrets/${CTF_SECRET_NAME}"
  ctf_ensure_federated_credential "$CONFIG_IDENTITY_NAME" config-reader "$(ctf_a4_subject)"
}
