#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - create (or refresh) the event leaderboard
# and the create-only token that lab VMs use to record results.
#
# Creates, in its own resource group, a storage account with anonymous access
# and account keys disabled (HTTPS/TLS 1.2 only, results deleted automatically
# after --retention-days), a container for the event, and "Storage Blob Data
# Contributor" on the account for you. Then issues a create-only token (user
# delegation SAS signed with your Microsoft Entra ID, at most 7 days) and tests
# it. Re-run to issue a fresh token, e.g. the day before the event.
#
# Writes .lab/leaderboard/ (ignored by git - never commit the token):
# settings.env, submit-url.txt and the Skillable life cycle actions with the
# token filled in. See leaderboard/README.md.
#
#   ./leaderboard/setup.sh
#   ./leaderboard/setup.sh -g rg-ctf-leaderboard --container kubecon-na-2026 --hours 36
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../shared/azure-cli-bash/lib.sh
. "$REPO_ROOT/shared/azure-cli-bash/lib.sh"

RESOURCE_GROUP=rg-kubecon-ctf-leaderboard
LOCATION=westus3
ACCOUNT=""
CONTAINER=ctf
HOURS=48
ALLOWED_IP=""
RETENTION_DAYS=14
SHOW_TOKEN=false
PURPOSE=kubecon-ctf-leaderboard
OUT_DIR="$REPO_ROOT/.lab/leaderboard"

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  -g, --resource-group NAME  resource group (default: $RESOURCE_GROUP)
  -l, --location REGION      region (default: $LOCATION)
  --account NAME             storage account (default: ctflb + 8 hex characters from subscription/resource group)
  --container NAME           container, one per event (default: $CONTAINER)
  --hours N                  token lifetime in hours, 1-168 (default: $HOURS)
  --ip IP[-IP]               only accept submissions from this IP address or range
  --retention-days N         delete results N days after they were recorded (default: $RETENTION_DAYS)
  --show-token               also print the submit URL (it contains the token)
  -h, --help                 show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP=${2:?}; shift 2 ;;
    -l|--location)       LOCATION=${2:?}; shift 2 ;;
    --account)           ACCOUNT=${2:?}; shift 2 ;;
    --container)         CONTAINER=${2:?}; shift 2 ;;
    --hours)             HOURS=${2:?}; shift 2 ;;
    --ip)                ALLOWED_IP=${2:?}; shift 2 ;;
    --retention-days)    RETENTION_DAYS=${2:?}; shift 2 ;;
    --show-token)        SHOW_TOKEN=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "Unknown option $1 (see --help)" ;;
  esac
done
case "$HOURS" in ''|*[!0-9]*) die "--hours must be a number" ;; esac
if [ "$HOURS" -lt 1 ] || [ "$HOURS" -gt 168 ]; then die "--hours must be 1-168 (a user delegation SAS lasts at most 7 days)"; fi
case "$RETENTION_DAYS" in ''|*[!0-9]*) die "--retention-days must be a number" ;; esac
printf '%s' "$CONTAINER" | grep -Eq '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' \
  || die "--container: 3-63 lowercase letters, digits and hyphens"

# Copies a template, replacing __SUBMIT_URL__ literally (the token contains
# characters such as & that sed or bash replacements would interpret).
fill_template() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *__SUBMIT_URL__*) printf '%s%s%s\n' "${line%%__SUBMIT_URL__*}" "$SUBMIT_URL" "${line#*__SUBMIT_URL__}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$1"
}

log_step "Checking prerequisites"
command -v az >/dev/null 2>&1 || die "The Azure CLI (az) is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
az account show -o none 2>/dev/null || die "Not signed in to Azure. Run: az login"
SUBSCRIPTION_ID=$(az_tsv account show --query id)
log_info "Subscription $(az_tsv account show --query name) ($SUBSCRIPTION_ID)"
[ -n "$ACCOUNT" ] || ACCOUNT="ctflb$(printf '%s' "$SUBSCRIPTION_ID/$RESOURCE_GROUP" | ctf_sha1 | cut -c1-8)"
printf '%s' "$ACCOUNT" | grep -Eq '^[a-z0-9]{3,24}$' || die "Storage account names are 3-24 lowercase letters and digits: $ACCOUNT"
ctf_signed_in_principal

log_step "Resource group $RESOURCE_GROUP"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags "purpose=$PURPOSE" --only-show-errors -o none
log_ok "ready"

log_step "Storage account $ACCOUNT (no anonymous access, no account keys, HTTPS/TLS 1.2 only)"
SECURE=(--allow-blob-public-access false --allow-shared-key-access false --min-tls-version TLS1_2 --https-only true)
if az storage account show -n "$ACCOUNT" -g "$RESOURCE_GROUP" -o none 2>/dev/null; then
  az storage account update -n "$ACCOUNT" -g "$RESOURCE_GROUP" "${SECURE[@]}" --only-show-errors -o none
  log_ok "exists - security settings enforced"
else
  az storage account create -n "$ACCOUNT" -g "$RESOURCE_GROUP" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --tags "purpose=$PURPOSE" "${SECURE[@]}" --only-show-errors -o none \
    || die "Could not create storage account $ACCOUNT (names are global - pass --account to choose another)"
  log_ok "created"
fi
ACCOUNT_ID=$(az_tsv storage account show -n "$ACCOUNT" -g "$RESOURCE_GROUP" --query id)
policy=$(mktemp)
printf '{"rules":[{"enabled":true,"name":"delete-results","type":"Lifecycle","definition":{"actions":{"baseBlob":{"delete":{"daysAfterModificationGreaterThan":%s}}},"filters":{"blobTypes":["blockBlob"]}}}]}\n' \
  "$RETENTION_DAYS" > "$policy"
az storage account management-policy create --account-name "$ACCOUNT" -g "$RESOURCE_GROUP" \
  --policy "@$(ctf_path "$policy")" --only-show-errors -o none
rm -f "$policy"
log_ok "results are deleted automatically $RETENTION_DAYS days after they were recorded"

log_step "Data access for you (Storage Blob Data Contributor on the storage account)"
ctf_ensure_role_assignment "$CTF_PRINCIPAL_ID" "$CTF_PRINCIPAL_TYPE" "Storage Blob Data Contributor" "$ACCOUNT_ID"

log_step "Container $CONTAINER"
retry 30 10 az storage container create --account-name "$ACCOUNT" -n "$CONTAINER" --auth-mode login \
  --only-show-errors -o none 2>/dev/null \
  || die "Could not create container $CONTAINER - data access may still be propagating; re-run in a few minutes."
log_ok "ready"

log_step "Create-only token for the lab VMs (valid $HOURS hours)"
EXPIRY=$(date -u -d "+$HOURS hours" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -v+"$HOURS"H '+%Y-%m-%dT%H:%MZ')
IP_ARGS=()
[ -z "$ALLOWED_IP" ] || IP_ARGS=(--ip "$ALLOWED_IP")
TOKEN=$(az storage container generate-sas --account-name "$ACCOUNT" -n "$CONTAINER" --permissions c --expiry "$EXPIRY" \
  --auth-mode login --as-user --https-only ${IP_ARGS[@]+"${IP_ARGS[@]}"} --only-show-errors -o tsv | tr -d '\r')
case "$TOKEN" in *sig=*) ;; *) die "Could not create the token" ;; esac
SUBMIT_URL="https://$ACCOUNT.blob.core.windows.net/$CONTAINER?$TOKEN"
if [ -n "$ALLOWED_IP" ]; then
  log_info "Token test skipped: the token only accepts requests from $ALLOWED_IP"
else
  probe="https://$ACCOUNT.blob.core.windows.net/$CONTAINER/health/setup-$(date -u +%Y%m%dT%H%M%SZ).txt?$TOKEN"
  # A real file for the response body: with MSYS_NO_PATHCONV, curl in Git Bash can't write to /dev/null.
  body=$(mktemp)
  status=000
  for attempt in $(seq 1 18); do
    [ "$attempt" -eq 1 ] || sleep 10
    status=$(curl -s -o "$(ctf_path "$body")" -w '%{http_code}' -m 15 -X PUT -H 'x-ms-blob-type: BlockBlob' \
      --data-binary 'setup probe' "$probe" || true)
    [ "$status" = 201 ] && break
  done
  [ "$status" = 201 ] || die "The new token could not record a test entry (HTTP $status). Data access may still be propagating - re-run in a few minutes."
  status=$(curl -s -o "$(ctf_path "$body")" -w '%{http_code}' -m 15 "$probe" || true)
  rm -f "$body"
  [ "$status" = 403 ] || die "The token can read entries (HTTP $status) - expected a create-only token"
  log_ok "tested: it can record an entry and cannot read one"
fi

log_step "Writing .lab/leaderboard/ (ignored by git - never commit the token)"
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/settings.env" <<EOF
# Written by leaderboard/setup - read by leaderboard/board.* and leaderboard/cleanup.*
LB_SUBSCRIPTION=$SUBSCRIPTION_ID
LB_RESOURCE_GROUP=$RESOURCE_GROUP
LB_STORAGE_ACCOUNT=$ACCOUNT
LB_CONTAINER=$CONTAINER
LB_TOKEN_EXPIRES=$EXPIRY
EOF
printf '%s\n' "$SUBMIT_URL" > "$OUT_DIR/submit-url.txt"
fill_template "$SCRIPT_DIR/skillable/lca-windows.ps1" > "$OUT_DIR/skillable-lca-windows.ps1"
fill_template "$SCRIPT_DIR/skillable/lca-linux.sh" > "$OUT_DIR/skillable-lca-linux.sh"
log_ok "$OUT_DIR"

log_step "Leaderboard ready"
log_info "Storage account : $ACCOUNT (resource group $RESOURCE_GROUP)"
log_info "Container       : $CONTAINER"
log_info "Token expires   : $EXPIRY UTC - re-run this script to issue a new one"
log_info "Submit URL      : $OUT_DIR/submit-url.txt"
if [ "$SHOW_TOKEN" = true ]; then log_info "                  $SUBMIT_URL"; fi
log_info ""
log_info "Next:"
log_info "  Skillable   : add $OUT_DIR/skillable-lca-windows.ps1 as a life cycle action (leaderboard/README.md)"
log_info "  Try it      : ./leaderboard/join.sh --name 'Your N.'   then   scoring/verify.sh --challenges c1"
log_info "  Projector   : ./leaderboard/board.sh"
log_info "  Kill switch : ./leaderboard/cleanup.sh --revoke-only    (invalidates every token at once)"
