#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - leaderboard reporting for scoring/verify.sh.
#
# When this machine is registered for an event leaderboard (by the Skillable
# life cycle action or leaderboard/join.sh), every challenge that verify.sh
# checks is recorded on the leaderboard: one small, write-once record per
# challenge and run, sent with a create-only token. Needs only curl.
# Nothing happens on machines that aren't registered. See leaderboard/README.md.
#
# Registration (first match wins):
#   1. environment: CTF_LEADERBOARD_URL, CTF_PLAYER_ID, CTF_PLAYER_NAME
#   2. the file named by CTF_LEADERBOARD_CONFIG
#   3. ~/.kubecon-ctf/leaderboard.env                (leaderboard/join.sh)
#   4. %ProgramData%\kubecon-ctf\leaderboard.env     (Skillable, Windows VM)
#      /etc/kubecon-ctf/leaderboard.env              (Skillable, Linux VM)
# -----------------------------------------------------------------------------

LB_ENABLED=false
LB_URL=""
LB_PLAYER_ID=""
LB_PLAYER_NAME=""

# lb_conf_value <file> <KEY> - value of KEY=value (the file is parsed, never sourced)
lb_conf_value() { sed -n "s/^$2=//p" "$1" | tr -d '\r' | head -n 1; }

lb_config_file() {
  local f pd=""
  if [ -n "${PROGRAMDATA:-}" ]; then
    if command -v cygpath >/dev/null 2>&1; then pd=$(cygpath -u "$PROGRAMDATA"); else pd=$PROGRAMDATA; fi
  fi
  for f in "${CTF_LEADERBOARD_CONFIG:-}" "${HOME:-}/.kubecon-ctf/leaderboard.env" \
           "${pd:+$pd/kubecon-ctf/leaderboard.env}" /etc/kubecon-ctf/leaderboard.env; do
    if [ -n "$f" ] && [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# lb_init <disabled:true|false> <quick:true|false>
lb_init() {
  local file
  LB_URL=${CTF_LEADERBOARD_URL:-}
  LB_PLAYER_ID=${CTF_PLAYER_ID:-}
  LB_PLAYER_NAME=${CTF_PLAYER_NAME:-}
  if [ -z "$LB_URL" ] && file=$(lb_config_file); then
    LB_URL=$(lb_conf_value "$file" CTF_LEADERBOARD_URL)
    [ -n "$LB_PLAYER_ID" ] || LB_PLAYER_ID=$(lb_conf_value "$file" CTF_PLAYER_ID)
    [ -n "$LB_PLAYER_NAME" ] || LB_PLAYER_NAME=$(lb_conf_value "$file" CTF_PLAYER_NAME)
  fi
  [ -n "$LB_URL" ] || return 0     # this machine isn't registered for a leaderboard
  if [ "$1" = true ]; then echo "Leaderboard: not recording this run (--no-report)"; return 0; fi
  if [ "$2" = true ]; then echo "Leaderboard: --quick runs are not recorded - run without --quick to record your result"; return 0; fi
  case "$LB_URL" in
    https://*\?*) ;;
    *) echo "Leaderboard: CTF_LEADERBOARD_URL must be https://<account>.blob.core.windows.net/<container>?<token> - not recording" >&2; return 0 ;;
  esac
  if ! printf '%s' "$LB_PLAYER_ID" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'; then
    echo "Leaderboard: missing or invalid CTF_PLAYER_ID - not recording" >&2; return 0
  fi
  [ -n "$LB_PLAYER_NAME" ] || LB_PLAYER_NAME="Player ${LB_PLAYER_ID: -4}"
  LB_PLAYER_NAME=${LB_PLAYER_NAME:0:40}
  if ! command -v curl >/dev/null 2>&1; then echo "Leaderboard: curl not found - not recording" >&2; return 0; fi
  LB_ENABLED=true
  echo "Leaderboard: recording results for '$LB_PLAYER_NAME' (--no-report to skip)"
}

# lb_submit <challenge-id> <PASSED|NOT PASSED> <checks-passed> <checks-total>
# Never fails the verification: problems are reported as a single line.
lb_submit() {
  [ "$LB_ENABLED" = true ] || return 0
  local id=$1 passed=false stamp blob base token name64 body tmp code="" err try
  [ "$2" = PASSED ] && passed=true
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  # Write-once: every run creates a new record; the token can't overwrite or delete anything.
  blob="results/$LB_PLAYER_ID/$id/$stamp-$RANDOM$RANDOM.json"
  base=${LB_URL%%\?*}; base=${base%/}; token=${LB_URL#*\?}
  name64=$(printf '%s' "$LB_PLAYER_NAME" | base64 | tr -d '\r\n')
  body=$(printf '{"player":"%s","challenge":"%s","passed":%s,"checks":"%s/%s","client_time":"%s","verifier":"bash"}' \
    "$LB_PLAYER_ID" "$id" "$passed" "$3" "$4" "$stamp")
  tmp=$(mktemp)
  for try in 1 2 3; do
    code=$(curl -sS -o "$(npath "$tmp")" -w '%{http_code}' -m 15 -X PUT \
      -H 'x-ms-blob-type: BlockBlob' -H 'Content-Type: application/json' \
      -H "x-ms-meta-player: $name64" -H "x-ms-meta-passed: $passed" -H "x-ms-meta-checks: $3/$4" \
      --data-binary "$body" "$base/$blob?$token" 2>/dev/null)
    case "$code" in
      000|408|429|5??) [ "$try" -lt 3 ] && sleep $((try * 2)) ;;
      *) break ;;
    esac
  done
  if [ "$code" = 201 ]; then
    if [ "$passed" = true ]; then
      printf '  %s>> leaderboard:%s flag recorded for %s\n' "$G" "$N" "$LB_PLAYER_NAME"
    else
      printf '  >> leaderboard: progress recorded for %s (%s/%s checks)\n' "$LB_PLAYER_NAME" "$3" "$4"
    fi
  else
    err=$(sed -n 's/.*<Code>\([^<]*\)<\/Code>.*/\1/p' "$tmp" 2>/dev/null | head -n 1)
    printf '  %s>> leaderboard: not recorded (HTTP %s%s)%s - your result above still stands; tell a proctor if this keeps happening\n' \
      "$R" "${code:-000}" "${err:+ $err}" "$N"
  fi
  rm -f "$tmp"
  return 0
}
