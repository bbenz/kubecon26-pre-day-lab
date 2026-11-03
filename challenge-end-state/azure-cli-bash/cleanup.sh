#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by the shared library
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - delete an END-state environment.
#   ./cleanup.sh                 # asks for confirmation
#   ./cleanup.sh -g my-rg -y
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_RESOURCE_GROUP="rg-kubecon-ctf-end-bash"

# shellcheck source=../../shared/azure-cli-bash/lib.sh
. "$REPO_ROOT/shared/azure-cli-bash/lib.sh"

ctf_cleanup "$@"
