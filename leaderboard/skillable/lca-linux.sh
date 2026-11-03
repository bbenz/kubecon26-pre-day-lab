#!/bin/bash
# -----------------------------------------------------------------------------
# Skillable life cycle action (Linux lab VM) - register the lab for the
# KubeCon CTF leaderboard, so scoring/verify.* records each result.
#
# Don't paste this template: paste .lab/leaderboard/skillable-lca-linux.sh,
# which leaderboard/setup.* writes with the event's submit URL (create-only
# token) filled in. Lab profile > Life Cycle Actions > Add:
#   Event: Running   Action: Execute Script in Virtual Machine   Language: Bash
#   Blocking: No     Error action: Ignore (the lab works without the leaderboard)
# Skillable replaces the @lab tokens when the lab starts. The token expires
# (7 days at most): after re-running setup, paste the new copy into the lab
# profile. Writes /etc/kubecon-ctf/leaderboard.env (needs root; falls back to
# ~/.kubecon-ctf/leaderboard.env).
# -----------------------------------------------------------------------------
set -eu
SUBMIT_URL='__SUBMIT_URL__'
# The Skillable user ID keeps a player's flags when the lab is relaunched.
PLAYER_ID=$(cat <<'EOF'
@lab.User.Id
EOF
)
FIRST_NAME=$(cat <<'EOF'
@lab.User.FirstName
EOF
)
LAST_NAME=$(cat <<'EOF'
@lab.User.LastName
EOF
)

case "$PLAYER_ID" in
  @lab*|'') echo "The @lab tokens were not replaced - run this as a Skillable life cycle action" >&2; exit 1 ;;
esac
PLAYER_ID=$(printf '%s' "$PLAYER_ID" | tr -cd 'A-Za-z0-9._-')
# Shown on the projected leaderboard: first name and last initial only (no e-mail address).
NAME=$(printf '%s' "$FIRST_NAME" | tr -d '\000-\037"\\<>&;$`|{}[]()*?!#%^=+~/:,@' | tr -s ' ' | sed 's/^ //; s/ $//')
case "$LAST_NAME" in [A-Za-z]*) NAME="$NAME ${LAST_NAME%"${LAST_NAME#?}"}." ;; esac
NAME=$(printf '%s' "$NAME" | cut -c1-24 | sed 's/^ //; s/ $//')
[ -n "$NAME" ] || NAME="Player $PLAYER_ID"

DIR=/etc/kubecon-ctf
if ! mkdir -p "$DIR" 2>/dev/null || [ ! -w "$DIR" ]; then DIR="$HOME/.kubecon-ctf"; mkdir -p "$DIR"; fi
{
  echo "# KubeCon CTF leaderboard registration - written by the Skillable life cycle action"
  echo "CTF_LEADERBOARD_URL=$SUBMIT_URL"
  echo "CTF_PLAYER_ID=$PLAYER_ID"
  echo "CTF_PLAYER_NAME=$NAME"
} > "$DIR/leaderboard.env"
chmod 644 "$DIR/leaderboard.env"
echo "Registered for the leaderboard as '$NAME'"
