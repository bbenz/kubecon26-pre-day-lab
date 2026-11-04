#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by the shared library
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - deploy the BEGIN state with the Azure CLI.
#
# Creates (or reuses) an AKS Automatic cluster plus the Azure services the
# selected challenges need, then deploys each challenge with its seeded fault.
#
#   ./deploy.sh                          # all challenges in westus3
#   ./deploy.sh -c c1,c3 -l centralus    # only C1 and C3, another region
#   ./deploy.sh -g rg-my-ctf -n aks-my-ctf -c c1   # reset C1 in an existing environment
#   ./deploy.sh --help
#
# Run it again to reset challenges: it deletes the selected challenges and
# deploys them again with their faults.
# Challenge instructions: ../challenges/<id>-*/README.md
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB_STATE="begin"
LAB_STATE_TITLE="BEGIN state (challenges with their seeded faults)"
LAB_STATE_DIR="$REPO_ROOT/begin-challenge"
DEFAULT_RESOURCE_GROUP="rg-kubecon-ctf-begin-bash"
# Re-running always starts the selected challenges again from a clean, broken state.
CTF_RESET_DEFAULT=true

# shellcheck source=../../shared/azure-cli-bash/lib.sh
. "$REPO_ROOT/shared/azure-cli-bash/lib.sh"

ctf_parse_args "$@"
ctf_preflight
ctf_compute_names

# Shared platform
ctf_ensure_resource_group
ctf_ensure_cluster_admin    # before the cluster exists, so RBAC has propagated when it is ready
ctf_ensure_cluster
ctf_get_credentials

# Azure services needed by individual challenges
ctf_ensure_app_routing   # C2: application routing add-on - managed NGINX + Gateway API (approuting-istio)
ctf_ensure_prometheus    # A2: Managed Prometheus for the Grafana dashboards
ctf_ensure_c4_azure      # C4: Foundry model deployment + ai-service workload identity
ctf_ensure_a4_azure      # A4: Key Vault + identity; federated subject from challenges/a4-*/azure.env

# Kubernetes objects for each challenge
for id in $CTF_CHALLENGES; do
  ctf_apply_challenge "$id"
done

ctf_print_summary
