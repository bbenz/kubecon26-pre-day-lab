#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - removing a lab environment.
# -----------------------------------------------------------------------------

ctf_cleanup_usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deletes the lab environment created by deploy.sh: the resource group (AKS
cluster, Foundry account, Key Vault, identities), then purges the soft-deleted
Key Vault and Foundry account so the names can be reused, and removes the
kubectl context.

Options:
  -g, --resource-group RG  Resource group [RESOURCE_GROUP] (default: ${DEFAULT_RESOURCE_GROUP})
  -n, --cluster-name NAME  Cluster name, for the kubectl context (default: aks-<resource group without rg->)
  -y, --yes                Do not ask for confirmation
      --no-wait            Start the deletion and return (skips the purge step)
  -h, --help               Show this help
EOF
}

ctf_cleanup() {
  local assume_yes=false wait=true answer deleted id loc
  RESOURCE_GROUP="${RESOURCE_GROUP:-$DEFAULT_RESOURCE_GROUP}"
  CLUSTER_NAME="${CLUSTER_NAME:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -g|--resource-group) RESOURCE_GROUP="${2:?missing value for $1}"; shift 2 ;;
      -n|--cluster-name)   CLUSTER_NAME="${2:?missing value for $1}"; shift 2 ;;
      -y|--yes)            assume_yes=true; shift ;;
      --no-wait)           wait=false; shift ;;
      -h|--help)           ctf_cleanup_usage; exit 0 ;;
      *)                   die "Unknown option '$1' (see --help)" ;;
    esac
  done
  CLUSTER_NAME="${CLUSTER_NAME:-aks-${RESOURCE_GROUP#rg-}}"
  az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"
  SUBSCRIPTION_ID=$(az_tsv account show --query id)
  CTF_SUFFIX=$(printf '%s' "${SUBSCRIPTION_ID}/${RESOURCE_GROUP}" | ctf_sha1 | cut -c1-6)
  KEY_VAULT_NAME="kv-ctf-${CTF_SUFFIX}"
  AOAI_ACCOUNT="aoai-ctf-${CTF_SUFFIX}"

  log_step "Cleaning up $RESOURCE_GROUP (subscription $SUBSCRIPTION_ID)"
  if az group show -n "$RESOURCE_GROUP" -o none 2>/dev/null; then
    if [ "$assume_yes" != true ]; then
      printf '    Delete resource group %s and everything in it? [y/N] ' "$RESOURCE_GROUP"
      read -r answer
      case "$answer" in y|Y|yes|YES) ;; *) die "Cancelled" ;; esac
    fi
    if [ "$wait" = true ]; then
      log_info "Deleting resource group (typically 5-15 minutes) ..."
      az group delete -n "$RESOURCE_GROUP" --yes --only-show-errors
      log_ok "resource group deleted"
    else
      az group delete -n "$RESOURCE_GROUP" --yes --no-wait --only-show-errors
      log_ok "deletion started (no purge of soft-deleted resources with --no-wait)"
    fi
  else
    log_info "Resource group $RESOURCE_GROUP does not exist"
  fi

  if [ "$wait" = true ]; then
    deleted=$(az_tsv keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME'].name | [0]" 2>/dev/null || true)
    if [ -n "$deleted" ]; then
      log_info "Purging soft-deleted Key Vault $KEY_VAULT_NAME ..."
      az keyvault purge -n "$KEY_VAULT_NAME" --only-show-errors -o none && log_ok "Key Vault purged"
    fi
    id=$(az_tsv cognitiveservices account list-deleted --query "[?name=='$AOAI_ACCOUNT'].id | [0]" 2>/dev/null || true)
    if [ -n "$id" ]; then
      loc=$(printf '%s' "$id" | sed -n 's|.*/locations/\([^/]*\)/.*|\1|p')
      log_info "Purging soft-deleted Foundry account $AOAI_ACCOUNT ..."
      az cognitiveservices account purge -n "$AOAI_ACCOUNT" -g "$RESOURCE_GROUP" -l "$loc" --only-show-errors -o none \
        && log_ok "Foundry account purged"
    fi
  fi

  if command -v kubectl >/dev/null 2>&1; then
    kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
    kubectl config delete-cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
    kubectl config unset "users.clusterUser_${RESOURCE_GROUP}_${CLUSTER_NAME}" >/dev/null 2>&1 || true
    log_ok "removed kubectl context $CLUSTER_NAME"
  fi
  rm -rf "$REPO_ROOT/.lab/rendered/$RESOURCE_GROUP"
}
