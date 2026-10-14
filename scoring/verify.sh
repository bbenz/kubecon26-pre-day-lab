#!/usr/bin/env bash
# shellcheck disable=SC2329  # helpers below are called from the sourced check modules
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - scoring / verification (bash).
#
# Checks each challenge against the success criteria from the lab design.
# Against a BEGIN-state deployment the checks fail (the fault is present);
# after the expected repair - or against an END-state deployment - they pass.
#
#   scoring/verify.sh                                   # all challenges found in the current context
#   scoring/verify.sh --context aks-kubecon-ctf-begin-bash --challenges c1,a3
#   scoring/verify.sh --quick                           # shorter observation windows
#
# Needs only kubectl (with access to the cluster) and curl. Exit code 0 when
# every selected challenge passes.
# -----------------------------------------------------------------------------
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

SCORING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_CHALLENGES="c1 c2 c3 c4 a1 a2 a3 a4 a5 a6"
KUBE_CONTEXT=""
CHALLENGES=""
QUICK=false

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  --context NAME        kubectl context (default: current context)
  -c, --challenges LIST comma-separated IDs (default: every challenge namespace found)
  --quick               shorter waits/observation windows (less strict, for fast iteration)
  -h, --help            show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --context)         KUBE_CONTEXT="${2:?}"; shift 2 ;;
    -c|--challenges)   CHALLENGES="${2:?}"; shift 2 ;;
    --quick)           QUICK=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "Unknown option $1" >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 2; }
[ -n "$KUBE_CONTEXT" ] || KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null | tr -d '\r')
[ -n "$KUBE_CONTEXT" ] || { echo "No kubectl context; pass --context" >&2; exit 2; }

if [ "$QUICK" = true ]; then OBSERVE_SECONDS=15; LONG_WAIT=90; RT=45; else OBSERVE_SECONDS=60; LONG_WAIT=420; RT=240; fi

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'; else G=""; R=""; B=""; N=""; fi

# ---------- helpers shared by the check modules ----------
k()  { kubectl --context "$KUBE_CONTEXT" "$@"; }
kj() { k "$@" 2>/dev/null | tr -d '\r'; }   # captured output without CR / errors
# Local file path for native tools (Git Bash on Windows needs C:/... paths).
npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
CH_PASS=0; CH_FAIL=0
pass()   { printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; CH_PASS=$((CH_PASS + 1)); }
fail()   { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; CH_FAIL=$((CH_FAIL + 1)); }
detail() { printf '%s\n' "$*" | sed 's/^/          /' | head -n 8; }
check()  { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; detail "expected '$2', got '$3'"; fi; }
first_pod() { kj get pods -n "$1" -l "$2" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
restarts()  { kj get pods -n "$1" -l "$2" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.restartCount}{"\n"}{end}{end}' | awk '{s+=$1} END {print s+0}'; }
svc_get()   { kj get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"; }
# wait_job <ns> <job> <timeout-seconds> -> 0 succeeded, 1 failed/timeout
wait_job() {
  local i=0 st
  while [ "$i" -lt "$3" ]; do
    st=$(kj get job "$2" -n "$1" -o jsonpath='{.status.succeeded}|{.status.conditions[?(@.type=="Failed")].status}')
    case "$st" in 1\|*) return 0 ;; *\|True) return 1 ;; esac
    sleep 5; i=$((i + 5))
  done
  return 1
}

# shellcheck source=lib/verify-core.sh
. "$SCORING_DIR/lib/verify-core.sh"
# shellcheck source=lib/verify-alternates.sh
. "$SCORING_DIR/lib/verify-alternates.sh"

title() {
  case "$1" in
    c1) echo "C1 The store won't start" ;;            c2) echo "C2 Healthy pods, broken storefront" ;;
    c3) echo "C3 Capacity that never arrives" ;;      c4) echo "C4 The AI assistant is up, but not working" ;;
    a1) echo "A1 Where did DNS go?" ;;                a2) echo "A2 Fast yesterday, slow today" ;;
    a3) echo "A3 Ready for maintenance?" ;;           a4) echo "A4 Identity without secrets" ;;
    a5) echo "A5 Running is not ready" ;;             a6) echo "A6 The data survived, the application didn't" ;;
  esac
}

if [ -z "$CHALLENGES" ]; then
  CHALLENGES=$(kj get namespaces -l kubecon.lab/challenge -o jsonpath='{range .items[*]}{.metadata.labels.kubecon\.lab/challenge}{" "}{end}')
  [ -n "$CHALLENGES" ] || { echo "No challenge namespaces found in context $KUBE_CONTEXT" >&2; exit 2; }
fi
CHALLENGES=$(printf '%s' "$CHALLENGES" | tr ',' ' ' | tr '[:upper:]' '[:lower:]')

echo "${B}KubeCon AKS CTF - verification against context '$KUBE_CONTEXT'${N}"
SUMMARY=""; OVERALL=0
for id in $ALL_CHALLENGES; do
  case " $CHALLENGES " in *" $id "*) ;; *) continue ;; esac
  CH_PASS=0; CH_FAIL=0
  printf '\n%s[%s] %s%s\n' "$B" "$id" "$(title "$id")" "$N"
  if ! kj get namespace "$(case $id in c1) echo c1-store;; c2) echo c2-storefront;; c3) echo c3-processing;; c4) echo c4-assistant;; a1) echo a1-inventory;; a2) echo a2-checkout;; a3) echo a3-maintenance;; a4) echo a4-config;; a5) echo a5-releases;; a6) echo a6-records;; esac)" >/dev/null; then
    fail "challenge namespace not found - is $id deployed in this context?"
  else
    "verify_$id"
  fi
  if [ "$CH_FAIL" -eq 0 ]; then res="PASSED"; else res="NOT PASSED"; OVERALL=1; fi
  SUMMARY="$SUMMARY$(printf '  %-4s %-11s %2d/%-2d checks  %s' "$id" "$res" "$CH_PASS" "$((CH_PASS + CH_FAIL))" "$(title "$id" | cut -d' ' -f2-)")
"
done

printf '\n%sSummary%s\n%s' "$B" "$N" "$SUMMARY"
exit "$OVERALL"
