#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab: join the event's leaderboard from this
# machine. At an event with a leaderboard, scoring/verify.sh and verify.ps1
# record each check that they run without --quick on it.
#
# Gets the leaderboard's submit URL from the event's registration link
# (https://aka.ms/aksctfsecrets), a small text file that's read, never run;
# checks that it's an Azure Storage address with a token that can only add
# results, and hasn't expired; tests it with one write that the leaderboard
# doesn't show; and saves it with your player ID and the name that the
# leaderboard shows in ~/.kubecon-ctf/leaderboard.env, or in the file that
# CTF_LEADERBOARD_CONFIG names. Needs curl.
#
#   scoring/join-leaderboard.sh --first-name Brian --last-name Benz
#   scoring/join-leaderboard.sh --name "Team Kube"
#   scoring/join-leaderboard.sh --remove
#
# Exit codes: 0 joined (or removed), 1 couldn't join, 2 an option isn't
# valid, 3 no leaderboard is open.
# -----------------------------------------------------------------------------
set -uo pipefail

FILE=${CTF_LEADERBOARD_CONFIG:-$HOME/.kubecon-ctf/leaderboard.env}
FROM=https://aka.ms/aksctfsecrets
FIRST=""
LAST=""
NAME=""
ID=""
URL=""
REMOVE=false

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  --first-name NAME, --last-name NAME
                 the leaderboard shows your first name and last initial
  --name NAME    the name that the leaderboard shows instead: letters, digits,
                 spaces, and . ' - (24 characters at most)
  --id ID        player ID (default: the ID already registered here, or a new one)
  --from URL     the event's registration link (default: $FROM)
  --url URL      the submit URL itself, instead of the registration link
  --remove       leave the leaderboard
  -h, --help     show this help
EOF
}

stop() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
need() { [ "$1" -ge 2 ] || stop "$2 needs a value (see --help)" 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --first-name) need $# "$1"; FIRST=$2; shift 2 ;;
    --last-name)  need $# "$1"; LAST=$2; shift 2 ;;
    --name)       need $# "$1"; NAME=$2; shift 2 ;;
    --id)         need $# "$1"; ID=$2; shift 2 ;;
    --from)       need $# "$1"; FROM=$2; shift 2 ;;
    --url)        need $# "$1"; URL=$2; shift 2 ;;
    --remove)     REMOVE=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            stop "Unknown option $1 (see --help)" 2 ;;
  esac
done

# A value that a Skillable replacement token didn't fill in (@lab....) counts as missing.
given() { case "$1" in ""|@lab.*|"@ lab."*) return 1 ;; *) return 0 ;; esac; }
clean_name() {
  printf '%s' "$1" | tr -d '\000-\037"\\<>&;$`|{}[]()*?!#%^=+~/:,@_' | tr -s ' ' | sed 's/^ //; s/ $//'
}
# fetch <url>: the text at an address, after redirects such as the registration link's, in BODY; the HTTP status
# and the final address in STATUS and FINAL.
fetch() {
  local out last
  out=$(curl -sSL -m 20 -w '\n%{http_code} %{url_effective}' "$1" 2>/dev/null) || return 1
  last=${out##*$'\n'}
  BODY=${out%$'\n'*}
  STATUS=${last%% *}
  FINAL=${last#* }
}
has_registration() { printf '%s\n' "$BODY" | grep -q '^CTF_LEADERBOARD_URL='; }

if [ "$REMOVE" = true ]; then
  if [ -f "$FILE" ]; then rm -f "$FILE"; echo "Left the leaderboard: removed $FILE. Your checks are no longer recorded."
  else echo "This machine isn't registered for a leaderboard ($FILE doesn't exist)."; fi
  exit 0
fi

# 1. The name that the leaderboard shows, and the player ID
if ! given "$NAME"; then
  NAME=""
  if given "$FIRST"; then NAME=$FIRST; fi
  if [ -n "$NAME" ] && given "$LAST"; then
    initial=$(clean_name "$LAST" | tr -d " .'-")
    [ -z "$initial" ] || NAME="$NAME ${initial:0:1}."
  fi
fi
BOARD_NAME=$(clean_name "$NAME")
if [ -z "$BOARD_NAME" ]; then
  [ -t 0 ] || stop "Pass --name, or --first-name and --last-name." 2
  read -r -p "Name to show on the leaderboard, such as your first name and last initial: " NAME
  BOARD_NAME=$(clean_name "$NAME")
  [ -n "$BOARD_NAME" ] || stop "The name must have letters or digits." 2
fi
BOARD_NAME=${BOARD_NAME:0:24}
BOARD_NAME=${BOARD_NAME% }
if given "$ID"; then ID=$(printf '%s' "$ID" | tr -cd 'A-Za-z0-9._-'); else ID=""; fi
if [ -z "$ID" ] && [ -f "$FILE" ]; then ID=$(sed -n 's/^CTF_PLAYER_ID=//p' "$FILE" | tr -d '\r' | head -n 1); fi
[ -n "$ID" ] || ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s' "$ID" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || stop "The player ID must be 1 to 64 letters, digits, and . _ -" 2

# 2. The submit URL, from the registration link
if [ -z "$URL" ]; then
  case "$FROM" in https://*) ;; *) stop "The registration link must start with https://: $FROM" 2 ;; esac
  command -v curl >/dev/null 2>&1 || stop "curl isn't installed."
  fetch "$FROM" || stop "Couldn't read the leaderboard's registration link, $FROM. Check this machine's internet connection, or ask a proctor."
  # A link to a gist's page instead of its file: read the file.
  if ! has_registration && printf '%s' "$FINAL" | grep -Eq '^https://gist\.github\.com/[^/?#]+/[0-9a-fA-F]+/?$'; then
    fetch "${FINAL%/}/raw" || stop "Couldn't read $FINAL/raw. Ask a proctor."
  fi
  # GitHub caches a gist's file for up to 5 minutes: a unique query string reads the newest version.
  if printf '%s' "$FINAL" | grep -Eq '^https://gist\.githubusercontent\.com/[^?#]+$'; then
    fetch "$FINAL?nocache=$RANDOM$RANDOM$(date +%s)" || stop "Couldn't read $FINAL. Ask a proctor."
  fi
  if ! has_registration; then
    case "$FINAL" in
      https://www.bing.com/*shorturl=*) stop "The leaderboard's registration link, $FROM, isn't set up yet. Ask a proctor." 3 ;;
    esac
    stop "$FROM doesn't have the leaderboard's registration (HTTP $STATUS from $FINAL). Ask a proctor."
  fi
  URL=$(printf '%s\n' "$BODY" | tr -d '\r' | sed -n 's/^CTF_LEADERBOARD_URL=//p' | head -n 1 | sed 's/[[:space:]]*$//')
  [ -n "$URL" ] || stop "No leaderboard is open right now. Your checks work the same. If your proctor says that one is open, run this again in a few minutes." 3
fi

# 3. Only a create-only token for Azure Storage, that hasn't expired
printf '%s' "$URL" | grep -Eq '^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/[a-z0-9-]{3,63}\?[^[:space:]]*sig=' \
  || stop "The leaderboard's submit URL isn't an Azure Storage address with a token, so this machine isn't registered. Ask a proctor."
query=${URL#*\?}
param() { printf '%s' "$query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
sp=$(param sp)
[ "$sp" = c ] || stop "The leaderboard's token can do more than add results (permissions '$sp'), so this machine isn't registered. Ask a proctor."
se=$(param se | sed 's/%3[Aa]/:/g')
if [ -n "$se" ]; then
  # Compare the digits of yyyy-MM-ddTHH:mm: no date parsing, which differs between GNU and BSD date.
  se_digits=$(printf '%s' "${se:0:16}" | tr -cd '0-9')
  [ ${#se_digits} -ge 12 ] || se_digits=$(printf '%-12s' "$se_digits" | tr ' ' 0)
  if [ "$se_digits" -le "$(date -u +%Y%m%d%H%M)" ]; then
    stop "The leaderboard's token expired at $se, so this machine isn't registered. Ask a proctor."
  fi
fi

# 4. One test write, to health/, which the leaderboard doesn't show
base=${URL%%\?*}
base=${base%/}
token=${URL#*\?}
out=$(curl -sS -m 15 -w '\n%{http_code}' -X PUT -H 'x-ms-blob-type: BlockBlob' -H 'Content-Type: text/plain' \
  --data-binary join "$base/health/join-$ID-$(date -u +%Y%m%dT%H%M%SZ).txt?$token" 2>/dev/null) || out=$'\n000'
code=${out##*$'\n'}
err=$(printf '%s' "$out" | sed -n 's/.*<Code>\([^<]*\)<\/Code>.*/\1/p' | head -n 1)
[ "$code" = 201 ] || stop "The leaderboard didn't accept a test entry (HTTP $code${err:+ $err}), so this machine isn't registered. Your checks work the same. Tell a proctor."

# 5. Save the registration, which scoring/verify.sh and verify.ps1 read
mkdir -p "$(dirname "$FILE")"
(
  umask 077
  {
    echo "# KubeCon CTF leaderboard registration - written by scoring/join-leaderboard.sh"
    echo "CTF_LEADERBOARD_URL=$URL"
    echo "CTF_PLAYER_ID=$ID"
    echo "CTF_PLAYER_NAME=$BOARD_NAME"
  } > "$FILE"
)
echo "Joined the leaderboard as '$BOARD_NAME'."
echo "Each check that you run without --quick now records your result there. --no-report keeps a check off it, and --remove leaves."
