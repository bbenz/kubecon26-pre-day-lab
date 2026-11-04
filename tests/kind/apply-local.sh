#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by the shared library
# -----------------------------------------------------------------------------
# Try the Kubernetes-only challenges without Azure: applies the challenges that
# need no Azure services (C1, A1, A2, A3, A5, A6) to a local kind cluster with
# the same bash library the Azure deployment uses, each with its fault in
# place, and resets them when you run it again.
#
#   kind create cluster --name ctf
#   tests/kind/apply-local.sh begin                 # c1 a1 a2 a3 a5 a6
#   scoring/verify.sh --context kind-ctf --quick    # expect NOT PASSED
#
# C2 (AKS Gateway API), C3 (node auto-provisioning), C4 (Foundry) and A4
# (Entra workload identity) need Azure and are not covered here. A1 behaves
# differently on AKS Automatic - try it on Azure too.
#
# CTF_STATE_DIR applies another folder of challenges, with the same layout as
# begin-challenge (required for any state other than begin).
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE="${1:?usage: apply-local.sh begin|end [challenge ids...]}"
shift
case "$STATE" in
  begin) LAB_STATE_DIR="${CTF_STATE_DIR:-$REPO_ROOT/begin-challenge}" ;;
  end)   LAB_STATE_DIR="${CTF_STATE_DIR:?set CTF_STATE_DIR to the folder with the end state's challenges}" ;;
  *)     echo "state must be begin or end" >&2; exit 2 ;;
esac
LAB_STATE="$STATE"
LAB_STATE_TITLE="$STATE state (local kind cluster)"
DEFAULT_RESOURCE_GROUP="local"
CTF_RESET_DEFAULT=false

# shellcheck source=../../shared/azure-cli-bash/lib.sh
. "$REPO_ROOT/shared/azure-cli-bash/lib.sh"

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-ctf}"
CTF_CHALLENGES="${*:-c1 a1 a2 a3 a5 a6}"
CTF_RESET="${CTF_RESET:-$([ "$STATE" = begin ] && echo true || echo false)}"
RENDER_DIR="$REPO_ROOT/.lab/rendered/kind-$STATE"
AOAI_DEPLOYMENT_NAME=store-assistant
AOAI_MODEL_NAME=gpt-6-luna
STOREFRONT_DNS_LABEL=ctf-store-local
STOREFRONT_HOSTNAME=store.local.test

# kind has no Azure Disk CSI driver: alias the storage class that A6 uses.
kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

for id in $CTF_CHALLENGES; do
  ctf_apply_challenge "$id"
done
log_step "Applied ($STATE): $CTF_CHALLENGES  ->  scoring/verify.sh --context $KUBE_CONTEXT --challenges $(printf '%s' "$CTF_CHALLENGES" | tr ' ' ',')"
