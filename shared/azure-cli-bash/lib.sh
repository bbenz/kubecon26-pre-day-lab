#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - shared bash library entry point.
# Usage (from a deploy/cleanup script):
#   . "$REPO_ROOT/shared/azure-cli-bash/lib.sh"
# -----------------------------------------------------------------------------
CTF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
. "$CTF_LIB_DIR/common.sh"
# shellcheck source=lib/azure.sh
. "$CTF_LIB_DIR/azure.sh"
# shellcheck source=lib/challenges.sh
. "$CTF_LIB_DIR/challenges.sh"
# shellcheck source=lib/cleanup.sh
. "$CTF_LIB_DIR/cleanup.sh"
