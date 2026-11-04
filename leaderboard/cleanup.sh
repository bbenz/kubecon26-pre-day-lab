#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - leaderboard kill switch and clean-up.
#
# --revoke-only: invalidates every token issued for the storage account at once
# - lab VMs can no longer record results, the leaderboard keeps showing what is
# there. Run leaderboard/setup.sh to issue a new token.
# Default: revokes the tokens, deletes the leaderboard's resource group (storage
# account and every result) and the local files in .lab/leaderboard/. Only
# resource groups created by leaderboard/setup are deleted.
#
#   ./leaderboard/cleanup.sh --revoke-only
#   ./leaderboard/cleanup.sh                  # asks for confirmation
# -----------------------------------------------------------------------------
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.lab/leaderboard"
RESOURCE_GROUP=""
ACCOUNT=""
SUBSCRIPTION=""
REVOKE_ONLY=false
YES=false

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  -g, --resource-group NAME  default: from .lab/leaderboard/settings.env
  --account NAME             storage account (default: from .lab/leaderboard/settings.env)
  --subscription ID          subscription of the leaderboard (default: from .lab/leaderboard/settings.env,
                             else the Azure CLI default)
  --revoke-only              only invalidate the tokens; keep the leaderboard
  -y, --yes                  don't ask for confirmation
  -h, --help                 show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP=${2:?}; shift 2 ;;
    --account)           ACCOUNT=${2:?}; shift 2 ;;
    --subscription)      SUBSCRIPTION=${2:?}; shift 2 ;;
    --revoke-only)       REVOKE_ONLY=true; shift ;;
    -y|--yes)            YES=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   echo "Unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
setting() { [ -f "$OUT_DIR/settings.env" ] && sed -n "s/^$1=//p" "$OUT_DIR/settings.env" | tr -d '\r' | head -n 1; }
[ -n "$RESOURCE_GROUP" ] || RESOURCE_GROUP=$(setting LB_RESOURCE_GROUP)
[ -n "$ACCOUNT" ] || ACCOUNT=$(setting LB_STORAGE_ACCOUNT)
[ -n "$SUBSCRIPTION" ] || SUBSCRIPTION=$(setting LB_SUBSCRIPTION)
if [ -z "$RESOURCE_GROUP" ] || [ -z "$ACCOUNT" ]; then
  echo "Pass --resource-group and --account (or run this where leaderboard/setup.sh ran)" >&2; exit 2
fi
# Act on the leaderboard's own subscription, whatever the Azure CLI default is.
SUB_ARGS=()
if [ -n "$SUBSCRIPTION" ]; then SUB_ARGS=(--subscription "$SUBSCRIPTION"); echo "Leaderboard subscription: $SUBSCRIPTION"; fi

echo "Revoking every token issued for $ACCOUNT ..."
if az storage account revoke-delegation-keys -n "$ACCOUNT" -g "$RESOURCE_GROUP" ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} --only-show-errors -o none; then
  echo "OK - tokens revoked: lab VMs can no longer record results."
elif [ "$REVOKE_ONLY" = true ]; then
  echo "Could not revoke the tokens for $ACCOUNT" >&2; exit 1
else
  echo "WARNING: could not revoke the tokens (continuing with the deletion)" >&2
fi
if [ "$REVOKE_ONLY" = true ]; then
  echo "To accept results again: ./leaderboard/setup.sh (new token), then update the Skillable life cycle action."
  exit 0
fi

exists=$(az group exists -n "$RESOURCE_GROUP" ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} --only-show-errors 2>/dev/null | tr -d '\r')
case "$exists" in
  true|false) ;;
  *) echo "Could not check resource group $RESOURCE_GROUP (sign-in or subscription problem?) - nothing was deleted" >&2; exit 1 ;;
esac
if [ "$exists" = false ]; then
  echo "Resource group $RESOURCE_GROUP not found."
else
  purpose=$(az group show -n "$RESOURCE_GROUP" ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} --query tags.purpose -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
  if [ "$purpose" != kubecon-ctf-leaderboard ]; then
    echo "Resource group $RESOURCE_GROUP was not created by leaderboard/setup (tag purpose=$purpose) - not deleting it" >&2; exit 1
  fi
  if [ "$YES" != true ]; then
    printf 'Delete resource group %s with storage account %s and every result? (yes/no) ' "$RESOURCE_GROUP" "$ACCOUNT"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
  fi
  echo "Deleting resource group $RESOURCE_GROUP (a few minutes) ..."
  az group delete -n "$RESOURCE_GROUP" ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} --yes --only-show-errors \
    || { echo "Could not delete resource group $RESOURCE_GROUP" >&2; exit 1; }
  echo "OK - leaderboard deleted."
fi
rm -rf "$OUT_DIR/settings.env" "$OUT_DIR/submit-url.txt" "$OUT_DIR/skillable-lca-windows.ps1" \
  "$OUT_DIR/skillable-lca-linux.sh" "$OUT_DIR/board"
echo "Removed the local files in $OUT_DIR."
