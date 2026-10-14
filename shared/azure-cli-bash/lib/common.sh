#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are used by the other library modules
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - shared bash library (common helpers).
# Sourced by begin-challenge/azure-cli-bash/*.sh and
# challenge-end-state/azure-cli-bash/*.sh. Compatible with bash 3.2+ (macOS),
# Git Bash on Windows, WSL, Linux and Azure Cloud Shell.
# -----------------------------------------------------------------------------

# Git Bash on Windows rewrites arguments that look like POSIX paths
# (/subscriptions/..., /api/v1/...). Turn that off for every az/kubectl call.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

CTF_ALL_CHALLENGES="c1 c2 c3 c4 a1 a2 a3 a4 a5 a6"
CTF_AKS_ADMIN_ROLE="Azure Kubernetes Service RBAC Cluster Admin"
CTF_SECRET_NAME="lab-config"
CTF_SECRET_VALUE="kubecon-ctf-a4: identity without secrets works"
CTF_MIN_AZ_VERSION="2.86.0"

if [ -t 1 ]; then
  _C_BLUE=$'\033[1;34m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_RED=$'\033[31m'; _C_RESET=$'\033[0m'
else
  _C_BLUE=""; _C_GREEN=""; _C_YELLOW=""; _C_RED=""; _C_RESET=""
fi

log_step() { printf '\n%s==> %s%s\n' "$_C_BLUE" "$*" "$_C_RESET"; }
log_info() { printf '    %s\n' "$*"; }
log_ok()   { printf '    %sOK%s  %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
log_warn() { printf '    %sWARNING:%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()      { printf '\n%sERROR:%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }

# az.cmd on Windows emits CRLF; strip CR so captured values are clean.
az_tsv() { az "$@" --only-show-errors -o tsv | tr -d '\r'; }

# Runs "az aks ..." with the core (GA) Azure CLI implementation. When the
# aks-preview extension is installed it replaces az aks commands with preview
# versions; pointing AZURE_EXTENSION_DIR at an empty folder bypasses it for
# this single command without changing the user's installation.
az_core() {
  if [ -n "${CTF_NOEXT_DIR:-}" ]; then
    AZURE_EXTENSION_DIR="$CTF_NOEXT_DIR" az "$@"
  else
    az "$@"
  fi
}

# kubectl against the lab cluster's context only.
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# Local file path for native tools. With MSYS_NO_PATHCONV=1, Git Bash no longer
# translates /c/... or /tmp/... paths for Windows executables (kubectl.exe,
# curl.exe), so convert explicitly. No-op on Linux, macOS and Cloud Shell.
ctf_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# retry <attempts> <delay-seconds> <command...>
retry() {
  local attempts=$1 delay=$2 i=1
  shift 2
  while :; do
    if "$@"; then return 0; fi
    [ "$i" -ge "$attempts" ] && return 1
    i=$((i + 1))
    sleep "$delay"
  done
}

ctf_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi | cut -d' ' -f1
}

ctf_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ctf_version_ge 2.88.0 2.86.0  -> true when $1 >= $2
ctf_version_ge() {
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 0; fi
    if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 1; fi
  done
  return 0
}

ctf_usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deploys the ${LAB_STATE_TITLE} of the KubeCon AKS capture-the-flag challenges
to Microsoft Azure (AKS Automatic) with the Azure CLI.

Options (environment variable in brackets):
  -c, --challenges LIST    Comma-separated challenge IDs or "all" [CHALLENGES]
                           IDs: ${CTF_ALL_CHALLENGES}   (default: all)
  -l, --location REGION    Azure region [LOCATION] (default: westus3)
  -g, --resource-group RG  Resource group [RESOURCE_GROUP] (default: ${DEFAULT_RESOURCE_GROUP})
  -n, --cluster-name NAME  AKS Automatic cluster [CLUSTER_NAME] (default: aks-<resource group without rg->)
      --reset              Delete and re-create the selected challenges first (default: ${CTF_RESET_DEFAULT})
      --no-reset           Re-apply the selected challenges without deleting them first
      --skip-infra         Do not create or update Azure resources; only (re)apply challenges
  -h, --help               Show this help

C4 model settings (environment variables only):
  AOAI_MODEL_NAME (gpt-6-luna)  AOAI_MODEL_VERSION (2026-09-22)  AOAI_CAPACITY (50 = 50K TPM)
  AOAI_DEPLOYMENT_NAME (store-assistant)  AOAI_LOCATION (same as LOCATION)
EOF
}

ctf_parse_args() {
  CHALLENGES="${CHALLENGES:-all}"
  LOCATION="${LOCATION:-westus3}"
  RESOURCE_GROUP="${RESOURCE_GROUP:-$DEFAULT_RESOURCE_GROUP}"
  CLUSTER_NAME="${CLUSTER_NAME:-}"
  CTF_RESET="$CTF_RESET_DEFAULT"
  CTF_SKIP_INFRA=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--challenges)     CHALLENGES="${2:?missing value for $1}"; shift 2 ;;
      -l|--location)       LOCATION="${2:?missing value for $1}"; shift 2 ;;
      -g|--resource-group) RESOURCE_GROUP="${2:?missing value for $1}"; shift 2 ;;
      -n|--cluster-name)   CLUSTER_NAME="${2:?missing value for $1}"; shift 2 ;;
      --reset)             CTF_RESET=true; shift ;;
      --no-reset)          CTF_RESET=false; shift ;;
      --skip-infra)        CTF_SKIP_INFRA=true; shift ;;
      -h|--help)           ctf_usage; exit 0 ;;
      *)                   die "Unknown option '$1' (see --help)" ;;
    esac
  done
  LOCATION=$(ctf_lower "$LOCATION" | tr -d ' ')
  CLUSTER_NAME="${CLUSTER_NAME:-aks-${RESOURCE_GROUP#rg-}}"
  AOAI_LOCATION=$(ctf_lower "${AOAI_LOCATION:-$LOCATION}" | tr -d ' ')
  AOAI_MODEL_NAME="${AOAI_MODEL_NAME:-gpt-6-luna}"
  AOAI_MODEL_VERSION="${AOAI_MODEL_VERSION:-2026-09-22}"
  AOAI_DEPLOYMENT_NAME="${AOAI_DEPLOYMENT_NAME:-store-assistant}"
  AOAI_CAPACITY="${AOAI_CAPACITY:-50}"
  [ "$AOAI_DEPLOYMENT_NAME" = "$AOAI_MODEL_NAME" ] && \
    die "AOAI_DEPLOYMENT_NAME must differ from AOAI_MODEL_NAME, otherwise challenge C4 has no fault"
  ctf_resolve_challenges
}

# Directory of a challenge in the current lab state, e.g. c1 -> .../challenges/c1-the-store-wont-start
ctf_challenge_dir() {
  local d
  for d in "$LAB_STATE_DIR"/challenges/"$1"-*; do
    if [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

ctf_namespace() {
  case "$1" in
    c1) echo c1-store ;;       c2) echo c2-storefront ;;  c3) echo c3-processing ;;
    c4) echo c4-assistant ;;   a1) echo a1-inventory ;;   a2) echo a2-checkout ;;
    a3) echo a3-maintenance ;; a4) echo a4-config ;;      a5) echo a5-releases ;;
    a6) echo a6-records ;;     *) return 1 ;;
  esac
}

ctf_resolve_challenges() {
  local raw id
  raw=$(ctf_lower "$CHALLENGES" | tr ',' ' ')
  [ "$raw" = "all" ] && raw="$CTF_ALL_CHALLENGES"
  CTF_CHALLENGES=""
  for id in $raw; do
    ctf_challenge_dir "$id" >/dev/null || die "Unknown challenge '$id'. Valid IDs: $CTF_ALL_CHALLENGES"
    CTF_CHALLENGES="$CTF_CHALLENGES $id"
  done
  CTF_CHALLENGES="${CTF_CHALLENGES# }"
  [ -n "$CTF_CHALLENGES" ] || die "No challenges selected"
}

ctf_selected() {
  case " $CTF_CHALLENGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

ctf_preflight() {
  log_step "Checking prerequisites"
  local tool azv
  for tool in az kubectl kubelogin; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' was not found on PATH. Install the Azure CLI, then run: az aks install-cli"
  done
  az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"
  azv=$(az version --query '"azure-cli"' -o tsv 2>/dev/null | tr -d '\r')
  ctf_version_ge "${azv:-0.0.0}" "$CTF_MIN_AZ_VERSION" || die "Azure CLI $azv is too old; $CTF_MIN_AZ_VERSION or later is required (az upgrade)"
  SUBSCRIPTION_ID=$(az_tsv account show --query id)
  log_info "Azure CLI $azv, subscription $(az_tsv account show --query name) ($SUBSCRIPTION_ID)"
  if az extension show --name aks-preview >/dev/null 2>&1; then
    CTF_NOEXT_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t ctfnoext)
    log_warn "aks-preview extension detected - az aks create/update will use the core (GA) Azure CLI commands"
  fi
}

ctf_compute_names() {
  CTF_SUFFIX=$(printf '%s' "${SUBSCRIPTION_ID}/${RESOURCE_GROUP}" | ctf_sha1 | cut -c1-6)
  AOAI_ACCOUNT="aoai-ctf-${CTF_SUFFIX}"
  KEY_VAULT_NAME="kv-ctf-${CTF_SUFFIX}"
  AI_IDENTITY_NAME="id-ctf-ai-service"
  CONFIG_IDENTITY_NAME="id-ctf-config-reader"
  STOREFRONT_DNS_LABEL="ctf-store-${CTF_SUFFIX}"
  STOREFRONT_HOSTNAME="${STOREFRONT_DNS_LABEL}.${LOCATION}.cloudapp.azure.com"
  KUBE_CONTEXT="$CLUSTER_NAME"
  RENDER_DIR="$REPO_ROOT/.lab/rendered/$RESOURCE_GROUP"
  log_info "Resource group $RESOURCE_GROUP, cluster $CLUSTER_NAME, region $LOCATION"
  log_info "Challenges ($LAB_STATE state): $CTF_CHALLENGES"
}
