#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - register this machine for the event
# leaderboard (outside Skillable). Writes ~/.kubecon-ctf/leaderboard.env with
# the submit URL, a player ID and the name shown on the board; scoring/verify.*
# then records every result. On Skillable lab VMs the life cycle action
# registers the lab instead (leaderboard/README.md).
#
#   ./leaderboard/join.sh --name "Brian B."      # submit URL from .lab/leaderboard/submit-url.txt
#   ./leaderboard/join.sh --name "Team Kube" --url 'https://<account>.blob.core.windows.net/ctf?<token>'
#   ./leaderboard/join.sh --remove               # stop recording results from this machine
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="$HOME/.kubecon-ctf/leaderboard.env"
NAME=""
URL=""
ID=""
REMOVE=false

usage() {
  sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  --name NAME   name shown on the leaderboard: letters, digits, spaces and . ' - (24 characters at most)
  --url URL     submit URL (default: .lab/leaderboard/submit-url.txt, written by leaderboard/setup.*)
  --id ID       player ID (default: the ID already registered on this machine, or a new random one)
  --remove      stop recording results from this machine
  -h, --help    show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME=${2:?}; shift 2 ;;
    --url)     URL=${2:?}; shift 2 ;;
    --id)      ID=${2:?}; shift 2 ;;
    --remove)  REMOVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "Unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ "$REMOVE" = true ]; then
  if [ -f "$FILE" ]; then rm -f "$FILE"; echo "Removed $FILE - results are no longer recorded from this machine."
  else echo "Nothing to remove ($FILE not found)."; fi
  exit 0
fi
[ -n "$NAME" ] || { echo "Pass --name (see --help)" >&2; exit 2; }
CLEAN=$(printf '%s' "$NAME" | tr -d '\000-\037"\\<>&;$`|{}[]()*?!#%^=+~/:,@' | tr -s ' ' | sed 's/^ //; s/ $//')
CLEAN=${CLEAN:0:24}
[ -n "$CLEAN" ] || { echo "The name must contain letters or digits" >&2; exit 2; }
if [ -z "$URL" ]; then
  saved="$SCRIPT_DIR/../.lab/leaderboard/submit-url.txt"
  [ -f "$saved" ] || { echo "Pass --url (the organizer has it in .lab/leaderboard/submit-url.txt after running leaderboard/setup)" >&2; exit 2; }
  URL=$(tr -d '\r\n' < "$saved")
fi
printf '%s' "$URL" | grep -Eq '^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/[a-z0-9-]{3,63}\?[^[:space:]]*sig=' \
  || { echo "The submit URL must look like https://<account>.blob.core.windows.net/<container>?<token>" >&2; exit 2; }
if [ -z "$ID" ] && [ -f "$FILE" ]; then ID=$(sed -n 's/^CTF_PLAYER_ID=//p' "$FILE" | tr -d '\r' | head -n 1); fi
[ -n "$ID" ] || ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s' "$ID" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || { echo "--id: 1-64 letters, digits, . _ -" >&2; exit 2; }
mkdir -p "$(dirname "$FILE")"
(
  umask 077
  {
    echo "# KubeCon CTF leaderboard registration - written by leaderboard/join.sh"
    echo "CTF_LEADERBOARD_URL=$URL"
    echo "CTF_PLAYER_ID=$ID"
    echo "CTF_PLAYER_NAME=$CLEAN"
  } > "$FILE"
)
echo "Registered as '$CLEAN' (player ID $ID) in $FILE"
echo "scoring/verify.* now records each result on the leaderboard (--no-report / -NoReport skips a run)."
