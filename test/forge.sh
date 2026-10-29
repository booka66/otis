#!/bin/sh
. "$(dirname "$0")/lib.sh"

# --- git-main-forward: the board keeps your local main up with origin's, a
# fast-forward wherever that is safe and nothing anywhere else. origin is a
# bare repo, and main lands there from a second clone (mf_land).
here=$PWD mf=$tmp/mf
git init -q --bare -b main "$mf/origin.git"
git init -q -b main "$mf/repo" && cd "$mf/repo" && git config user.email t@t && git config user.name t
printf 'a\n' > f && git add f && git commit -qm a && git remote add origin "$mf/origin.git" && git push -q origin main
git clone -q "$mf/origin.git" "$mf/gitlab" && git -C "$mf/gitlab" config user.email g@g && git -C "$mf/gitlab" config user.name g
mf_land() { (cd "$mf/gitlab" && git pull -q && echo landed >> f && git commit -qam landed && git push -q origin main) >/dev/null 2>&1; }
# mf_run: as the board does, a minute after the last time.
mf_run() { rm -f "$mf/repo/.git/main-forwarded"; git-main-forward; }
mf_origin() { git --git-dir="$mf/origin.git" rev-parse main; }
git switch -qc feat
mf_land; mf_run
expect main-forward/not-checked-out "$(git rev-parse main)" "$(mf_origin)"
mf_land; git-main-forward
expect main-forward/once-a-minute "$(git rev-list --count main..origin/main; git rev-parse origin/main | grep -cxF "$(mf_origin)")" "0
0"
git worktree add -q "$mf/wt" main
mf_run
expect main-forward/checked-out-clean "$(git rev-parse main; git -C "$mf/wt" status --porcelain)" "$(mf_origin)"
mf_land; echo mine >> "$mf/wt/f"; mf_run
expect main-forward/checked-out-changed "$(git rev-list --count main..origin/main)" "1"
git -C "$mf/wt" checkout -q f
# A main being rebased is checked out nowhere, its checkout detached, and git
# refuses to move it all the same.
git -C "$mf/wt" rebase -q --exec false HEAD~1 >/dev/null 2>&1
mf_run
expect main-forward/being-rebased "$(git rev-list --count main..origin/main)" "1"
git -C "$mf/wt" rebase --abort
(cd "$mf/wt" && echo mine > g && git add g && git commit -qm mine)
mf_land; mf_run
expect main-forward/own-commits-left "$(git log -1 --format=%s main)" "mine"
git worktree remove --force "$mf/wt"
cd "$here"

# --- git-forge: GitLab's calls pass to glab untouched; on GitHub the same
# calls are answered from gh in GitLab's shapes. gh is a stub answering from
# fixtures, and the repo is a local one set to GitHub, so nothing is fetched.
here=$PWD fg=$tmp/forge
git init -q "$fg" && cd "$fg" && git config user.email t@t && git config user.name t
printf 'a\n' > f.ts && git add f.ts && git commit -qm base && git branch -qM main && git checkout -qb feat
printf 'b\n' > f.ts && git commit -qam change
b=$(git rev-parse main) h=$(git rev-parse feat)
git remote add origin "$tmp/repo"
mkdir -p "$tmp/fgstub"
cat > "$tmp/fgstub/glab" <<'STUB'
#!/bin/sh
printf '%s|' "$@"
STUB
chmod +x "$tmp/fgstub/glab"
expect forge/gitlab-passes-through "$(PATH=$tmp/fgstub:$PATH git-forge api -X PUT 'projects/:fullpath/x?a=1' -f 'body=two words')" "api|-X|PUT|projects/:fullpath/x?a=1|-f|body=two words|"
expect forge/gitlab-head-ref "$(git-forge head-ref 7)" "refs/merge-requests/7/head"
expect forge/gitlab-can "$(git-forge can deploys; echo $?)" "0"
expect forge/gitlab-lacks "$(git-forge lacks)" "main-builds"
expect forge/gitlab-mr-update "$(PATH=$tmp/fgstub:$PATH git-forge mr-update 7 --ready --label x)" "mr|update|7|--ready|--label|x|"
expect forge/gitlab-approve "$(PATH=$tmp/fgstub:$PATH git-forge approve 7 abc)" "mr|approve|7|--sha|abc|"
# A list says CONFLICT of an MR whose conflict GitLab found before a push it
# has not looked at since (conflicts false): the list asks GitLab to look,
# and says what it finds. GitLab is a stub: its list is $FM/list, and its REST
# list notes what was asked and answers $FM/rest, the recheck done by then
# ($FM/next becomes the list). One GitLab does not get to is unchecked; a
# conflict it has checked is a conflict, and nothing is asked.
fm=$tmp/fm
mkdir -p "$fm/stub"
cat > "$fm/stub/glab" <<'STUB'
#!/bin/sh
case $2 in
  graphql) cat "$FM/list" ;;
  *) printf '%s\n' "$2" >> "$FM/asked"
     [ -e "$FM/rest" ] || exit 1
     cat "$FM/rest"
     [ ! -e "$FM/next" ] || mv "$FM/next" "$FM/list" ;;
esac
STUB
chmod +x "$fm/stub/glab"
fm_list() { printf '{"data": {"currentUser": {"authoredMergeRequests": {"nodes": [{"iid": "7", "detailedMergeStatus": "%s", "conflicts": %s}, {"iid": "8", "detailedMergeStatus": "NOT_APPROVED", "conflicts": false}]}}}}\n' "$1" "$2"; }
fm_mrs() { PATH=$fm/stub:$PATH FM=$fm git-forge mrs mine | jq -c '[.data.currentUser.authoredMergeRequests.nodes[] | [.iid, .detailedMergeStatus]]'; }
fm_list CONFLICT false > "$fm/list"; fm_list MERGEABLE false > "$fm/next"; echo '[{"merge_status": "can_be_merged"}]' > "$fm/rest"
expect forge/gitlab-stale-conflict-rechecked "$(fm_mrs; cat "$fm/asked")" '[["7","MERGEABLE"],["8","NOT_APPROVED"]]
projects/:fullpath/merge_requests?per_page=100&with_merge_status_recheck=true&iids[]=7'
fm_list CONFLICT false > "$fm/list"; rm -f "$fm/rest" "$fm/asked"
expect forge/gitlab-stale-conflict-unchecked "$(fm_mrs)" '[["7","UNCHECKED"],["8","NOT_APPROVED"]]'
fm_list CONFLICT true > "$fm/list"; rm -f "$fm/asked"
expect forge/gitlab-conflict-kept "$(fm_mrs; [ -e "$fm/asked" ] || echo not asked)" '[["7","CONFLICT"],["8","NOT_APPROVED"]]
not asked'
git config otis.forge github; git config otis.host github.com; git config otis.project o/r
pr='{"number":5,"title":"T","body":"d","url":"https://github.com/o/r/pull/5","isDraft":false,"createdAt":"2026-09-01T00:00:00Z",
 "updatedAt":"2026-09-02T00:00:00Z","headRefName":"feat","baseRefName":"main","headRefOid":"'$h'","baseRefOid":"'$b'",
 "author":{"login":"kim"},"additions":1,"deletions":1,"changedFiles":1,"mergeStateStatus":"BEHIND","reviewDecision":"CHANGES_REQUESTED",
 "autoMergeRequest":null,"mergedBy":null,"labels":{"nodes":[{"name":"bug"}]},
 "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"sam","databaseId":2}}]},
 "latestReviews":{"nodes":[{"author":{"login":"lee","databaseId":3},"state":"CHANGES_REQUESTED"}]},
 "reviewThreads":{"totalCount":2,"nodes":[{"isResolved":true},{"isResolved":false}]},
 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
   {"__typename":"CheckRun","databaseId":11,"name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-02T00:00:00Z",
    "completedAt":"2026-09-02T00:05:00Z","checkSuite":{"workflowRun":{"databaseId":900,"workflow":{"name":"CI"}}}},
   {"__typename":"StatusContext","context":"deploy/preview","state":"PENDING","createdAt":"2026-09-02T00:00:00Z"}]}}}}]}}'
cat > "$tmp/fgstub/gh" <<STUB
#!/bin/sh
case "\$*" in
  "api user") echo '{"login":"sam","name":"Sam"}' ;;
  *"reviewThreads(first: 100) { nodes { id"*) cat <<J
{"data":{"repository":{"pullRequest":{"id":"PR_1","headRefOid":"$h","baseRefOid":"$b","reviewThreads":{"nodes":[
  {"id":"PRRT_1","isResolved":false,"isOutdated":false,"path":"f.ts","subjectType":"LINE","diffSide":"RIGHT","startDiffSide":null,"line":1,"startLine":null,"originalLine":1,"originalStartLine":null,
   "comments":{"nodes":[{"id":"PRRC_21","databaseId":21,"body":"why?","createdAt":"2026-09-02T00:00:00Z","state":"SUBMITTED","author":{"login":"lee"},"originalCommit":{"oid":"$h"}},
                        {"id":"PRRC_23","databaseId":23,"body":"my reply","createdAt":"2026-09-03T00:00:00Z","state":"PENDING","author":{"login":"sam"},"originalCommit":{"oid":"$h"}}]}},
  {"id":"PRRT_2","isResolved":true,"isOutdated":true,"path":"f.ts","subjectType":"LINE","diffSide":"LEFT","startDiffSide":null,"line":null,"startLine":null,"originalLine":1,"originalStartLine":null,
   "comments":{"nodes":[{"id":"PRRC_22","databaseId":22,"body":"gone","createdAt":"2026-09-02T00:00:00Z","state":"SUBMITTED","author":{"login":"sam"},"originalCommit":{"oid":"0ld"}}]}},
  {"id":"PRRT_3","isResolved":false,"isOutdated":false,"path":"f.ts","subjectType":"LINE","diffSide":"RIGHT","startDiffSide":"RIGHT","line":1,"startLine":1,"originalLine":1,"originalStartLine":1,
   "comments":{"nodes":[{"id":"PRRC_24","databaseId":24,"body":"my draft","createdAt":"2026-09-03T00:00:00Z","state":"PENDING","author":{"login":"sam"},"originalCommit":{"oid":"$h"}}]}}]},
 "comments":{"nodes":[{"databaseId":31,"body":"thanks","createdAt":"2026-09-02T00:00:00Z","author":{"login":"kim"}}]}}}}}
J
    ;;
  *"reviews(states: PENDING"*) echo '{"data":{"repository":{"pullRequest":{"id":"PR_1","headRefOid":"$h","reviews":{"nodes":[{"id":"PRR_9","viewerDidAuthor":true}]}}}}}' ;;
  "api graphql --input -") { echo "\$*"; cat; echo; } >> "$tmp/gh.posted"; echo '{"data":{"addPullRequestReviewThread":{"thread":{"comments":{"nodes":[{"id":"PRRC_25"}]}}}}}' ;;
  *"mutation"*) printf '%s\n' "\$*" >> "$tmp/gh.posted"; echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}' ;;
  "api -X POST repos/o/r/pulls/5/comments --input -"|"api -X POST repos/o/r/pulls/5/reviews --input -") { echo "\$*"; cat; echo; } >> "$tmp/gh.posted"; echo '{}' ;;
  *"review-requested:@me"*) echo '{"data":{"viewer":{"login":"sam"},"asked":{"nodes":[$pr]},"seen":{"nodes":[$pr]}}}' ;;
  "api repos/o/r/actions/runs/900 --jq .head_sha") echo "$h" ;;
  "api --paginate repos/o/r/commits/$h/check-runs?per_page=100") echo '{"check_runs":[{"id":11,"name":"test","status":"completed","conclusion":"failure",
    "started_at":"2026-09-02T00:00:00Z","completed_at":"2026-09-02T00:05:00Z","html_url":"u","app":{"name":"GitHub Actions"}},
    {"id":12,"name":"lint","status":"in_progress","conclusion":null,"started_at":"2026-09-02T00:00:00Z","completed_at":null,"html_url":"v","app":{"name":"GitHub Actions"}}]}' ;;
  "api -X PUT repos/o/r/"*" --input -") { echo "\$*"; cat; echo; } >> "$tmp/gh.posted"; echo '{"merged":true}' ;;
  "pr "*) echo "\$*" >> "$tmp/gh.posted" ;;
  *"author:@me"*) echo '{"data":{"viewer":{"login":"sam"},"search":{"nodes":[$pr]}}}' ;;
  *"pullRequest(number"*) echo '{"data":{"repository":{"pullRequest":$pr}}}' ;;
  *"pullRequests(states"*) echo '{"data":{"viewer":{"login":"sam"},"repository":{"pullRequests":{"totalCount":1,"nodes":[$pr]}}}}' ;;
  *) echo "gh stub: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/fgstub/gh"
ghp=$tmp/fgstub:$PATH
expect forge/mine "$(PATH=$ghp git-forge mrs mine | jq -c '.data.currentUser | [.username, (.authoredMergeRequests.nodes[0] | .iid, .diffRefs.baseSha == "'$b'",
  .headPipeline.status, .headPipeline.id, (.headPipeline.jobs.nodes | map(.status) | join(",")), .detailedMergeStatus, .approvalsLeft,
  (.reviewers.nodes | map(.username + ":" + .mergeRequestInteraction.reviewState) | join(",")), .resolvedDiscussionsCount)]')" \
  '["sam","5",true,"FAILED","900","FAILED,PENDING","need_rebase",1,"lee:REQUESTED_CHANGES,sam:UNREVIEWED",1]'
expect forge/review-once "$(PATH=$ghp git-forge mrs review | jq '.data.currentUser.reviewRequestedMergeRequests.nodes | length')" "1"
expect forge/all "$(PATH=$ghp git-forge mrs all | jq -c '.data.project.mergeRequests | [.count, .nodes[0].sourceBranch]')" '[1,"feat"]'
expect forge/rest-mr "$(PATH=$ghp git-forge api "projects/:fullpath/merge_requests/5" | jq -c '[.iid, .source_branch, .diff_refs.base_sha == "'$b'", .labels, .reviewers[0].username]')" '[5,"feat",true,["bug"],"lee"]'
expect forge/user "$(PATH=$ghp git-forge api user | jq -r .username)" "sam"
# Threads as discussions, placed as GitLab's are: submitted comments only, an
# outdated one at the commit it was made on; your pending review's the drafts.
expect forge/discussions "$(PATH=$ghp git-mr-pages "projects/:fullpath/merge_requests/5/discussions?per_page=100" |
  jq -c 'map([.id, .resolved, (.notes | length), .notes[0].position.new_line, .notes[0].position.old_line, .notes[0].position.head_sha == "'$h'", .resolvable])')" \
  '[["PRRT_1",false,1,1,null,true,true],["PRRT_2",true,1,null,1,false,true],["comment-31",false,1,null,null,false,false]]'
expect forge/drafts "$(PATH=$ghp git-mr-pages "projects/:fullpath/merge_requests/5/draft_notes?per_page=100" |
  jq -c 'map([.id, .note, .discussion_id, .position.new_line, .position.base_sha == "'$b'"])')" \
  '[["PRRC_23","my reply","PRRT_1",null,false],["PRRC_24","my draft",null,1,true]]'
expect forge/placed "$(PATH=$ghp git-mr-threads --fetch 5 "$b..$h" | jq -c 'map([.id, .where.state, (.notes | map(.draft // false))])')" \
  '[["PRRT_1","line",[false,true]],["PRRT_2","outdated",[false]],["comment-31","overview",[false]],["draft-PRRC_24","line",[true]]]'
# A comment where git-mr-position puts it, on GitHub's line and side; a draft
# into your pending review; a thread resolved.
rm -f "$tmp/gh.posted"
PATH=$ghp git-forge api -X POST "projects/:fullpath/merge_requests/5/discussions" -H 'Content-Type: application/json' --input - >/dev/null <<J
{"body":"hm","position":$(git-mr-position "$b" "$b" "$h" f.ts new 1 1)}
J
expect forge/comment-posted "$(sed 1d "$tmp/gh.posted" | jq -c '[.body, .path, .line, .side, .commit_id == "'$h'", has("start_line")]')" '["hm","f.ts",1,"RIGHT",true,false]'
rm -f "$tmp/gh.posted"
expect forge/draft-id "$(printf '%s' '{"note":"d","position":'"$(git-mr-position "$b" "$b" "$h" f.ts old 1 1)"'}' |
  PATH=$ghp git-forge api -X POST "projects/:fullpath/merge_requests/5/draft_notes" --input - | jq -r .id)" "PRRC_25"
expect forge/draft-into-review "$(sed 1d "$tmp/gh.posted" | jq -c '.variables.input | [.pullRequestReviewId, .path, .line, .side]')" '["PRR_9","f.ts",1,"LEFT"]'
rm -f "$tmp/gh.posted"
PATH=$ghp git-forge api -X PUT "projects/:fullpath/merge_requests/5/discussions/PRRT_1?resolved=true" >/dev/null
expect forge/resolve "$(grep -c 'resolveReviewThread.*t=PRRT_1' "$tmp/gh.posted")" "1"
expect forge/head-ref "$(git-forge head-ref 5)" "refs/pull/5/head"
expect forge/mr-url "$(git-mr-url 5)" "https://github.com/o/r/pull/5"
expect forge/lacks "$(git-forge can stack; echo $?)" "1"
expect forge/says-what-it-lacks "$(PATH=$ghp git-forge api -X POST 'projects/:fullpath/merge_requests/5/pipelines' 2>&1; echo $?)" "not on GitHub: POST projects/:fullpath/merge_requests/5/pipelines
1"
# CI: a pipeline is the head commit's checks, a job a check run.
expect forge/jobs "$(PATH=$ghp git-mr-pages "projects/:fullpath/pipelines/900/jobs?per_page=100" | jq -c 'map([.id, .name, .status, .duration])')" \
  '[[11,"test","failed",300],[12,"lint","running",null]]'
# The REST MR says why it cannot merge in GitLab's words, and merging it sends
# the head you read.
expect forge/merge-status "$(PATH=$ghp git-forge api "projects/:fullpath/merge_requests/5" | jq -r .detailed_merge_status)" "need_rebase"
rm -f "$tmp/gh.posted"
expect forge/merge "$(PATH=$ghp git-forge api -X PUT "projects/:fullpath/merge_requests/5/merge?sha=$h" | jq -r .state)" "merged"
expect forge/merge-sent "$(sed 1d "$tmp/gh.posted" | jq -c '[.sha == "'$h'", .merge_method]')" '[true,"merge"]'
rm -f "$tmp/gh.posted"
PATH=$ghp git-forge api -X PUT "projects/:fullpath/merge_requests/5" -f "labels=bug,ready" >/dev/null
expect forge/labels "$(head -1 "$tmp/gh.posted"; sed 1d "$tmp/gh.posted" | jq -c .labels)" "api -X PUT repos/o/r/issues/5/labels --input -
[\"bug\",\"ready\"]"
rm -f "$tmp/gh.posted"
PATH=$ghp git-forge mr-update 5 --ready --label ready
expect forge/mr-update "$(cat "$tmp/gh.posted")" "pr ready 5 -R o/r
pr edit 5 -R o/r --add-label ready"
expect forge/lacks-all "$(git-forge lacks)" "stack run-pipeline stage-graph upload"
# The board lists the pull request as yours, from the same JSON (otis-list,
# then otis-board). The prefetch is held off (its lock taken), so nothing is
# left running behind the test. The rows never wait for the forge, not even
# the first time in a repo: the first list is what is here alone, the forge
# asked behind it, and the list made again once it has answered has the
# pull request.
gst=$tmp/forge-state && mkdir -p "$gst" "$(git rev-parse --git-common-dir)/gmr-prefetch.lock"
PATH=$ghp GIT_FZF_STATE=$gst otis-list > "$gst/rows"
expect forge/board-first-is-local "$(PATH=$ghp GIT_FZF_STATE=$gst otis-board | awk -F'\t' '$18 == "mine" { print $9, $12 }')" ""
for _ in $(seq 1 40); do [ -s "$(git rev-parse --git-common-dir)/git-alias-cache/ci-mine.json" ] && break; sleep 0.25; done
expect forge/board-row "$(PATH=$ghp GIT_FZF_STATE=$gst otis-list > "$gst/rows"; PATH=$ghp GIT_FZF_STATE=$gst otis-board | awk -F'\t' '$18 == "mine" { print $9, $12 }')" "5 feat"
cd "$here"

