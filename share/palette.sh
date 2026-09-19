# The palette for sh scripts: . "$share/palette.sh". The same names as
# share/rowfmt.awk and share/otis.jq, named for the job each color does; the
# hues are the theme's (otis-theme), loaded here if nothing above loaded it.
#
# Each value is printf's escape form, not the bytes, so it is for a printf
# FORMAT string: printf "${GK_CONTEXT}%s${GK_R}\n" "$text". Passed as an
# argument to %s it would print literally; use %b there.
[ -n "$OTIS_T_NAME" ] || eval "$(otis-theme --env)"
GK_ATTENTION="\033[${OTIS_T_ATTENTION}m"  # look here: keys, ids, something waiting
GK_GOOD="\033[${OTIS_T_GOOD}m"            # passed, approved, safe to remove
GK_BAD="\033[${OTIS_T_BAD}m"              # failed, deleted, in the way
GK_ELSEWHERE="\033[${OTIS_T_ELSEWHERE}m"  # somewhere other than here: a worktree, a thread
GK_YOURS="\033[${OTIS_T_YOURS}m"          # waiting on you: drafts, fixes, unresolved
GK_TEXT="\033[${OTIS_T_TEXT}m"            # what the row is about
GK_CONTEXT="\033[${OTIS_T_CONTEXT}m"      # true, but not why you are looking
GK_FAINT="\033[${OTIS_T_FAINT}m"          # structure: rules, separators, empty slots
GK_MAIN="\033[${OTIS_T_MAIN}m"            # main, and things that are not yours to move
GK_R='\033[0m'
