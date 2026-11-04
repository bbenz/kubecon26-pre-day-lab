#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - show the live leaderboard (projector view).
#
# Reads the event's results with your Microsoft Entra sign-in - you need
# Storage Blob Data Reader (or Contributor) on the storage account; no token is
# involved - and writes board-data.js next to a copy of leaderboard.html every
# few seconds, then opens the page in your browser. F11 = full screen;
# double-click a player to hide them, press U to show hidden players again.
# Stop with Ctrl+C. See leaderboard/README.md.
#
#   ./leaderboard/board.sh            # storage account/container/subscription from .lab/leaderboard/settings.env
#   ./leaderboard/board.sh --account ctflb1a2b3c4d --container ctf --challenges c1,c2,a2,c4 --start 2026-11-10T09:00
# -----------------------------------------------------------------------------
set -uo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS="$REPO_ROOT/.lab/leaderboard/settings.env"
ACCOUNT=""
CONTAINER=""
SUBSCRIPTION=""
CHALLENGES="c1,c2,c3,c4,a1,a2,a3,a4,a5,a6"
TITLE="KubeCon AKS Capture the Flag"
REFRESH=10
MAX_ROWS=20
START=""
OUT_DIR="$REPO_ROOT/.lab/leaderboard/board"
ONCE=false
NO_BROWSER=false

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  --account NAME        storage account (default: from .lab/leaderboard/settings.env)
  --container NAME      container (default: from .lab/leaderboard/settings.env)
  --subscription ID     subscription of the storage account (default: from .lab/leaderboard/settings.env,
                        else the Azure CLI default) - needed when your default is in another tenant
  --challenges LIST     challenges shown and scored, in column order (default: $CHALLENGES)
  --title TEXT          heading (default: $TITLE)
  --refresh SECONDS     refresh interval, 5-300 (default: $REFRESH)
  --max-rows N          players shown, 5-200 (default: $MAX_ROWS)
  --start TIME          event start, e.g. 2026-11-10T09:00 (local): capture times shown as time since the start
  --out-dir DIR         where the page and its data are written (default: .lab/leaderboard/board)
  --once                write the data once and exit
  --no-browser          don't open the browser
  -h, --help            show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --account)     ACCOUNT=${2:?}; shift 2 ;;
    --container)   CONTAINER=${2:?}; shift 2 ;;
    --subscription) SUBSCRIPTION=${2:?}; shift 2 ;;
    --challenges)  CHALLENGES=${2:?}; shift 2 ;;
    --title)       TITLE=${2:?}; shift 2 ;;
    --refresh)     REFRESH=${2:?}; shift 2 ;;
    --max-rows)    MAX_ROWS=${2:?}; shift 2 ;;
    --start)       START=${2:?}; shift 2 ;;
    --out-dir)     OUT_DIR=${2:?}; shift 2 ;;
    --once)        ONCE=true; shift ;;
    --no-browser)  NO_BROWSER=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

setting() { [ -f "$SETTINGS" ] && sed -n "s/^$1=//p" "$SETTINGS" | tr -d '\r' | head -n 1; }
[ -n "$ACCOUNT" ] || ACCOUNT=$(setting LB_STORAGE_ACCOUNT)
[ -n "$CONTAINER" ] || CONTAINER=$(setting LB_CONTAINER)
[ -n "$SUBSCRIPTION" ] || SUBSCRIPTION=$(setting LB_SUBSCRIPTION)
if [ -z "$ACCOUNT" ] || [ -z "$CONTAINER" ]; then
  echo "Pass --account and --container (or run leaderboard/setup.sh on this machine first)" >&2; exit 2
fi
command -v az >/dev/null 2>&1 || { echo "The Azure CLI (az) is required" >&2; exit 2; }
# The sign-in is for the storage account's tenant even when the Azure CLI default subscription is elsewhere.
SUB_ARGS=()
[ -z "$SUBSCRIPTION" ] || SUB_ARGS=(--subscription "$SUBSCRIPTION")
for n in "$REFRESH" "$MAX_ROWS"; do
  case "$n" in ''|*[!0-9]*) echo "--refresh and --max-rows must be numbers" >&2; exit 2 ;; esac
done
[ "$REFRESH" -ge 5 ] || REFRESH=5

# JSON string literal for a short text value.
json_str() { printf '"%s"' "$(printf '%s' "$1" | tr '\r\n\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
IDS_JSON=""
for c in $(printf '%s' "$CHALLENGES" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
  case "$c" in [ac][0-9]) ;; *) echo "Unknown challenge ID: $c" >&2; exit 2 ;; esac
  IDS_JSON="$IDS_JSON${IDS_JSON:+,}\"$c\""
done
START_JSON=null
[ -z "$START" ] || START_JSON=$(json_str "$START")

mkdir -p "$OUT_DIR"
PAGE="$OUT_DIR/leaderboard.html"
DATA_FILE="$OUT_DIR/board-data.js"
cp "$SCRIPT_DIR/leaderboard.html" "$PAGE"
ENTRIES='[]'
DATA_TIME=null

# Reads every result record (name, creation time, metadata) and rewrites board-data.js.
update_board() {
  local raw err problem="" error_json=null
  err=$(mktemp)
  if ! raw=$(az storage blob list --account-name "$ACCOUNT" --container-name "$CONTAINER" --auth-mode login \
      ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} \
      --prefix results/ --include m --num-results '*' --query '[].{n:name,t:properties.creationTime,m:metadata}' \
      -o json --only-show-errors 2>"$err"); then
    problem=$(tr '\r\n' '  ' < "$err" | sed 's/  */ /g; s/^ //; s/ $//')
  else
    raw=$(printf '%s' "$raw" | tr -d '\r')
    case "$raw" in
      \[*\]) ENTRIES=$raw; DATA_TIME=$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)") ;;
      *) problem="unexpected output from az storage blob list" ;;
    esac
  fi
  rm -f "$err"
  [ -z "$problem" ] || error_json=$(json_str "$problem")
  # az prints valid JSON; it is embedded as is (the page treats every value as untrusted text).
  {
    printf 'window.CTF_BOARD = {"generated":"%s","dataTime":%s,"title":%s,"challenges":[%s],"refresh":%s,"maxRows":%s,"start":%s,"error":%s,"entries":' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DATA_TIME" "$(json_str "$TITLE")" "$IDS_JSON" "$REFRESH" "$MAX_ROWS" "$START_JSON" "$error_json"
    printf '%s' "$ENTRIES"
    printf '};\n'
  } > "$DATA_FILE.tmp" && mv -f "$DATA_FILE.tmp" "$DATA_FILE"
  if [ -n "$problem" ]; then echo "$(date +%H:%M:%S) can't read results: $problem" >&2; return 1; fi
  return 0
}

open_page() {
  if command -v cygpath >/dev/null 2>&1; then cmd.exe /c start "" "$(cygpath -w "$PAGE")" >/dev/null 2>&1 && return 0; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$PAGE" >/dev/null 2>&1 & return 0; fi
  if command -v open >/dev/null 2>&1; then open "$PAGE" && return 0; fi
  echo "Open $PAGE in a browser."
}

echo "Leaderboard: $ACCOUNT/$CONTAINER -> $PAGE"
update_board || echo "You need an az login session with Storage Blob Data Reader (or Contributor) on the storage account." >&2
[ "$NO_BROWSER" = true ] || open_page
[ "$ONCE" = true ] && exit 0
echo "Refreshing every $REFRESH seconds - press Ctrl+C to stop."
while :; do
  sleep "$REFRESH"
  update_board || true
done
