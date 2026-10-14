#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - applying challenge manifests (kubectl).
# -----------------------------------------------------------------------------

# Placeholders used in the challenge manifests (replaced at deploy time).
CTF_TOKEN_PATTERN='__(AZURE_OPENAI_ENDPOINT|AZURE_OPENAI_DEPLOYMENT|AZURE_OPENAI_MODEL_NAME|AI_SERVICE_CLIENT_ID|KEY_VAULT_URI|CONFIG_READER_CLIENT_ID|STOREFRONT_DNS_LABEL|STOREFRONT_HOSTNAME)__'

# Writes the challenge manifests with placeholders replaced to $RENDER_DIR/<id>.
ctf_render_challenge() {
  local id=$1 src out f
  case "$id" in
    c4) [ -n "${AZURE_OPENAI_ENDPOINT:-}" ] && [ -n "${AI_SERVICE_CLIENT_ID:-}" ] || die "C4 Azure values are missing" ;;
    a4) [ -n "${KEY_VAULT_URI:-}" ] && [ -n "${CONFIG_READER_CLIENT_ID:-}" ] || die "A4 Azure values are missing" ;;
  esac
  src="$(ctf_challenge_dir "$id")/manifests"
  out="$RENDER_DIR/$id"
  rm -rf "$out"
  mkdir -p "$out"
  for f in "$src"/*.yaml; do
    sed -e "s|__AZURE_OPENAI_ENDPOINT__|${AZURE_OPENAI_ENDPOINT:-}|g" \
        -e "s|__AZURE_OPENAI_DEPLOYMENT__|${AOAI_DEPLOYMENT_NAME}|g" \
        -e "s|__AZURE_OPENAI_MODEL_NAME__|${AOAI_MODEL_NAME}|g" \
        -e "s|__AI_SERVICE_CLIENT_ID__|${AI_SERVICE_CLIENT_ID:-}|g" \
        -e "s|__KEY_VAULT_URI__|${KEY_VAULT_URI:-}|g" \
        -e "s|__CONFIG_READER_CLIENT_ID__|${CONFIG_READER_CLIENT_ID:-}|g" \
        -e "s|__STOREFRONT_DNS_LABEL__|${STOREFRONT_DNS_LABEL}|g" \
        -e "s|__STOREFRONT_HOSTNAME__|${STOREFRONT_HOSTNAME}|g" \
        "$f" | tr -d '\r' > "$out/$(basename "$f")"
  done
  if grep -E -l "$CTF_TOKEN_PATTERN" "$out"/*.yaml >/dev/null 2>&1; then
    die "Unresolved placeholders in $out"
  fi
  CTF_RENDERED="$out"
}

# Deletes a challenge's namespace and cluster-scoped objects so it can be re-created from scratch.
ctf_reset_challenge() {
  local id=$1
  log_info "Reset: deleting existing objects for $id (namespace $(ctf_namespace "$id"))"
  if [ "$id" = "c3" ]; then
    # Deleting the NodePool also removes any nodes it provisioned in an earlier run.
    k delete nodepools.karpenter.sh -l "kubecon.lab/challenge=c3" --ignore-not-found --wait=true --timeout=10m || true
  fi
  k delete namespace -l "kubecon.lab/challenge=$id" --ignore-not-found --wait=true --timeout=10m \
    || die "Timed out deleting the $id namespace"
}

# Waits until every Job labelled kubecon.lab/phase=setup in <namespace> has succeeded.
ctf_wait_setup_jobs() {
  local ns=$1 jobs job status i
  jobs=$(k get jobs -n "$ns" -l kubecon.lab/phase=setup -o name 2>/dev/null | tr -d '\r')
  for job in $jobs; do
    log_info "Waiting for $job (setup phase; includes disk provisioning) ..."
    i=0
    while :; do
      status=$(k get "$job" -n "$ns" -o jsonpath='{.status.succeeded}|{.status.conditions[?(@.type=="Failed")].status}' | tr -d '\r')
      case "$status" in
        1\|*)    log_ok "$job completed"; break ;;
        *\|True) die "$job failed - see: kubectl --context $KUBE_CONTEXT logs -n $ns $job" ;;
      esac
      i=$((i + 1))
      [ "$i" -ge 80 ] && die "$job did not complete within 20 minutes"
      sleep 15
    done
  done
}

ctf_apply_challenge() {
  local id=$1 ns
  ns=$(ctf_namespace "$id")
  log_step "Challenge $id -> namespace $ns ($LAB_STATE state)"
  ctf_render_challenge "$id"
  [ "$CTF_RESET" = true ] && ctf_reset_challenge "$id"
  k apply -f "$(ctf_path "$CTF_RENDERED/00-namespace.yaml")" >/dev/null
  # Phase 1: objects labelled kubecon.lab/phase=setup (for example seeding data
  # onto a disk) must finish before the rest of the challenge is applied.
  if grep -q 'kubecon.lab/phase: setup' "$CTF_RENDERED"/*.yaml; then
    k apply -f "$(ctf_path "$CTF_RENDERED")" -l kubecon.lab/phase=setup
    ctf_wait_setup_jobs "$ns"
  fi
  # Phase 2: everything.
  k apply -f "$(ctf_path "$CTF_RENDERED")"
  log_ok "applied $(ctf_challenge_dir "$id" | sed "s|^$REPO_ROOT/||")/manifests"
}

ctf_print_summary() {
  local id ns dir ip
  log_step "Done - ${LAB_STATE_TITLE} deployed"
  log_info "kubectl context : $KUBE_CONTEXT   (kubectl config use-context $KUBE_CONTEXT)"
  log_info "Resource group  : $RESOURCE_GROUP ($LOCATION)"
  printf '\n    %-4s %-16s %s\n' "ID" "NAMESPACE" "INSTRUCTIONS"
  for id in $CTF_CHALLENGES; do
    ns=$(ctf_namespace "$id")
    dir=$(ctf_challenge_dir "$id" | sed "s|^$REPO_ROOT/||")
    printf '    %-4s %-16s %s\n' "$id" "$ns" "$dir/README.md"
  done
  if ctf_selected c2; then
    log_info ""
    log_info "C2 storefront: waiting up to 5 minutes for the gateway's public IP ..."
    k wait --for=condition=Programmed gateway/store-gateway -n c2-storefront --timeout=300s >/dev/null 2>&1 || true
    ip=$(k get gateway store-gateway -n c2-storefront -o jsonpath='{.status.addresses[0].value}' 2>/dev/null | tr -d '\r')
    log_info "C2 storefront URL: http://$STOREFRONT_HOSTNAME/  (gateway IP: ${ip:-pending})"
  fi
  if ctf_selected c4; then
    log_info "C4 store admin  : kubectl --context $KUBE_CONTEXT port-forward -n c4-assistant svc/store-admin 8081:80  ->  http://localhost:8081"
  fi
  log_info ""
  log_info "Check a challenge against its success criteria:"
  log_info "  scoring/verify.sh --context $KUBE_CONTEXT --challenges $(printf '%s' "$CTF_CHALLENGES" | tr ' ' ',')"
}
