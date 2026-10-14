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
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags purpose=kubecon-ctf "lab-state=$LAB_STATE" \
    --only-show-errors -o none
  log_ok "resource group ready"
}

ctf_ensure_cluster() {
  log_step "AKS Automatic cluster $CLUSTER_NAME"
  if az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o none 2>/dev/null; then
    log_ok "cluster exists"
  elif [ "$CTF_SKIP_INFRA" = true ]; then
    die "Cluster $CLUSTER_NAME not found (remove --skip-infra)"
  else
    log_info "Creating the cluster - this typically takes 10-15 minutes ..."
    # --sku automatic          : AKS Automatic (NAP, Cilium, Azure RBAC, deployment safeguards, ...)
    # --enable-hosted-system   : managed system node pool (system components run on AKS-managed nodes)
    # --enable-gateway-api     : managed Gateway API CRDs (challenge C2)
    # --enable-app-routing-istio: Istio-based Gateway API implementation of the application routing add-on
    # --no-ssh-key             : otherwise the CLI sends ~/.ssh/id_rsa.pub when it exists, which AKS rejects
    #                            for Automatic clusters with managed system node pools (BadRequest)
    az_core aks create -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -l "$LOCATION" \
      --sku automatic --enable-hosted-system --no-ssh-key \
      --enable-gateway-api --enable-app-routing-istio \
      --tags purpose=kubecon-ctf "lab-state=$LAB_STATE" \
      --only-show-errors -o none \
      || die "az aks create failed. Check region support for AKS Automatic and vCPU quota (see docs/prerequisites.md)."
    log_ok "cluster created"
  fi
  AKS_ID=$(az_tsv aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query id)
  OIDC_ISSUER=$(az_tsv aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl)
}

# Sets CTF_PRINCIPAL_ID / CTF_PRINCIPAL_TYPE for the signed-in user or service principal.
ctf_signed_in_principal() {
  local type app_id
  type=$(az_tsv account show --query user.type)
  if [ "$type" = "user" ]; then
    CTF_PRINCIPAL_ID=$(az_tsv ad signed-in-user show --query id)
    CTF_PRINCIPAL_TYPE=User
  else
    app_id=$(az_tsv account show --query user.name)
    CTF_PRINCIPAL_ID=$(az_tsv ad sp show --id "$app_id" --query id)
    CTF_PRINCIPAL_TYPE=ServicePrincipal
  fi
  [ -n "$CTF_PRINCIPAL_ID" ] || die "Could not determine the object ID of the signed-in principal"
}

# ctf_ensure_role_assignment <principal-object-id> <principal-type> <role> <scope>
ctf_ensure_role_assignment() {
  local principal=$1 ptype=$2 role=$3 scope=$4 count
  count=$(az_tsv role assignment list --assignee "$principal" --role "$role" --scope "$scope" --query "length(@)" 2>/dev/null || echo 0)
  if [ "${count:-0}" != "0" ]; then
    log_ok "'$role' already assigned"
    return 0
  fi
  # New managed identities can take a few seconds to replicate - retry.
  retry 10 15 az role assignment create --assignee-object-id "$principal" --assignee-principal-type "$ptype" \
    --role "$role" --scope "$scope" --only-show-errors -o none \
    || die "Could not assign '$role' on $scope"
  log_ok "assigned '$role'"
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
  kubelogin convert-kubeconfig -l azurecli --context "$KUBE_CONTEXT"
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

ctf_ensure_gateway_api() {
  ctf_selected c2 || return 0
  log_step "Gateway API (application routing add-on, Istio implementation)"
  if ! k get gatewayclass approuting-istio >/dev/null 2>&1; then
    [ "$CTF_SKIP_INFRA" = true ] && die "GatewayClass approuting-istio is missing (remove --skip-infra)"
    log_info "Enabling managed Gateway API CRDs and the approuting-istio GatewayClass (a few minutes) ..."
    az_core aks update -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --enable-gateway-api --enable-app-routing-istio \
      --only-show-errors -o none || die "az aks update --enable-gateway-api --enable-app-routing-istio failed"
  fi
  retry 40 15 k get gatewayclass approuting-istio >/dev/null 2>&1 || die "GatewayClass approuting-istio did not appear"
  log_ok "GatewayClass approuting-istio available"
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
ctf_ensure_c4_azure() {
  ctf_selected c4 || return 0
  log_step "C4: Microsoft Foundry model deployment and ai-service identity"
  if ! az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" -o none 2>/dev/null; then
    [ "$CTF_SKIP_INFRA" = true ] && die "Foundry account $AOAI_ACCOUNT not found (remove --skip-infra)"
    ctf_purge_deleted_aoai
    az cognitiveservices account create -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" -l "$AOAI_LOCATION" \
      --kind AIServices --sku S0 --custom-domain "$AOAI_ACCOUNT" --yes --only-show-errors -o none
    log_ok "created Foundry account $AOAI_ACCOUNT ($AOAI_LOCATION)"
  fi
  AOAI_ID=$(az_tsv cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" --query id)
  AZURE_OPENAI_ENDPOINT="https://${AOAI_ACCOUNT}.openai.azure.com/"
  if [ "$CTF_SKIP_INFRA" != true ]; then
    # Keys off: the app must authenticate with Microsoft Entra ID (workload identity).
    ctf_az_rest --method patch --url "https://management.azure.com${AOAI_ID}?api-version=2024-10-01" \
      --body '{"properties":{"disableLocalAuth":true}}' \
      || log_warn "could not disable key authentication on $AOAI_ACCOUNT"
    if ! az cognitiveservices account deployment show -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" \
        --deployment-name "$AOAI_DEPLOYMENT_NAME" -o none 2>/dev/null; then
      az cognitiveservices account deployment create -g "$RESOURCE_GROUP" -n "$AOAI_ACCOUNT" \
        --deployment-name "$AOAI_DEPLOYMENT_NAME" --model-name "$AOAI_MODEL_NAME" \
        --model-version "$AOAI_MODEL_VERSION" --model-format OpenAI \
        --sku-name GlobalStandard --sku-capacity "$AOAI_CAPACITY" --only-show-errors -o none \
        || die "Model deployment failed. Check model availability/quota: az cognitiveservices usage list -l $AOAI_LOCATION"
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

# Reads A4_FEDERATED_SUBJECT from <state>/challenges/a4-*/azure.env (the seeded fault / the fix).
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
