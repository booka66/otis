# GitHub's answers in GitLab's shapes, for share/forge/github: a pull request
# as the MR node share/mr-query.sh asks for and as the REST MR, its checks as
# a pipeline, its review threads as discussions. Where GitHub has nothing to
# say, the field GitLab would fill is left null rather than made up.

# A commit's checks, as the GraphQL asks for them.
def rollup_fields: "statusCheckRollup { state contexts(first: 100) { nodes {
    __typename
    ... on CheckRun { databaseId name status conclusion startedAt completedAt checkSuite { workflowRun { databaseId workflow { name } } } }
    ... on StatusContext { context state createdAt } } } }";

# The GraphQL a pull request is asked with, the fields the defs below read.
def pr_fields: "
  id number state title body url isDraft createdAt updatedAt headRefName baseRefName headRefOid baseRefOid
  author { login } additions deletions changedFiles mergeStateStatus reviewDecision
  baseRepository { viewerDefaultMergeMethod deleteBranchOnMerge }
  autoMergeRequest { enabledAt } mergedBy { login }
  labels(first: 30) { nodes { name } }
  reviewRequests(first: 30) { nodes { requestedReviewer { ... on User { login databaseId } ... on Team { slug } } } }
  latestReviews(first: 30) { nodes { author { login ... on User { databaseId } } state } }
  reviewThreads(first: 100) { totalCount nodes { isResolved } }
  commits(last: 1) { nodes { commit { \(rollup_fields) } } }";

# A check, as a GitLab job: {name, status, allowFailure, stage}.
def job_status:
  if .__typename == "StatusContext" then
    {SUCCESS: "SUCCESS", FAILURE: "FAILED", ERROR: "FAILED", PENDING: "PENDING", EXPECTED: "PENDING"}[.state] // "PENDING"
  elif .status == "COMPLETED" then
    {SUCCESS: "SUCCESS", NEUTRAL: "SUCCESS", SKIPPED: "SKIPPED", FAILURE: "FAILED", TIMED_OUT: "FAILED",
     STARTUP_FAILURE: "FAILED", CANCELLED: "CANCELED", STALE: "CANCELED", ACTION_REQUIRED: "MANUAL"}[.conclusion // ""] // "FAILED"
  elif .status == "IN_PROGRESS" then "RUNNING"
  else "PENDING" end;
def job:
  {name: (.name // .context), status: job_status, allowFailure: false,
   stage: {name: (.checkSuite.workflowRun.workflow.name // "status")},
   id: (.databaseId // null), startedAt: (.startedAt // .createdAt), finishedAt: (.completedAt // null)};

# A commit's checks ($c, its statusCheckRollup), as its pipeline: the newest
# workflow run's id, so a key that acts on the pipeline acts on that run.
def checks($c; $path):
  if $c == null then null else
    [$c.contexts.nodes[] | job] as $jobs |
    ([$c.contexts.nodes[] | .checkSuite.workflowRun.databaseId // empty] | max) as $run |
    {id: (if $run then $run | tostring else null end),
     status: ({SUCCESS: "SUCCESS", FAILURE: "FAILED", ERROR: "FAILED", PENDING: "RUNNING", EXPECTED: "PENDING"}[$c.state] // "PENDING"),
     path: $path,
     createdAt: ([$jobs[].startedAt // empty] | min), finishedAt: ([$jobs[].finishedAt // empty] | max),
     stages: {nodes: ([$jobs[].stage.name] | unique | map({name: .}))},
     jobs: {nodes: $jobs}}
  end;
# A pull request's head commit's checks.
def pipeline($repo; $n): checks(.commits.nodes[0].commit.statusCheckRollup // null; "/\($repo)/pull/\($n)/checks");

# A GitHub deployment as GitLab's REST one of the deploy job ($job): started
# when it first went in progress, finished when it first said it was done (a
# host can repeat itself days later). INACTIVE is one a later deploy
# replaced: live before that if it ever succeeded, else canceled on its way.
def deployment($job):
  [.statuses.nodes[] | {state, createdAt}] as $s |
  ([$s[] | select(.state | IN("SUCCESS", "FAILURE", "ERROR"))] | min_by(.createdAt)) as $done |
  (.latestStatus.state // "PENDING") as $last |
  (if $last == "INACTIVE" then
     (if $done == null then "canceled" elif $done.state == "SUCCESS" then "success" else "failed" end)
   else {SUCCESS: "success", FAILURE: "failed", ERROR: "failed", IN_PROGRESS: "running",
     QUEUED: "created", PENDING: "created", WAITING: "created"}[$last] // "created" end) as $status |
  ([$s[] | select(.state == "IN_PROGRESS") | .createdAt] | min // .createdAt) as $started |
  ($done.createdAt // null) as $finished |
  {id: .databaseId, iid: .databaseId, status: $status, sha: .commitOid, created_at: .createdAt,
   user: {username: (.creator.login // "")},
   deployable: {name: $job, id: .databaseId, status: $status, started_at: $started, finished_at: $finished,
     duration: (if $finished then ($finished | fromdateiso8601) - ($started | fromdateiso8601) else 0 end),
     pipeline: {id: .databaseId}, web_url: (.latestStatus.logUrl // .latestStatus.environmentUrl // "")}};

# A reviewer's latest word, in GitLab's reviewState.
def review_state:
  {APPROVED: "APPROVED", CHANGES_REQUESTED: "REQUESTED_CHANGES", COMMENTED: "REVIEWED",
   DISMISSED: "UNREVIEWED", PENDING: "REVIEW_STARTED"}[.] // "UNREVIEWED";

# Why it can or cannot merge, in GitLab's detailed_merge_status. GitHub's
# BLOCKED says only that a rule stands in the way; which one is read off the
# reviews, the checks and the threads.
def merge_status:
  (.commits.nodes[0].commit.statusCheckRollup.state // null) as $checks |
  if .state != null and .state != "OPEN" then "not_open"
  elif .isDraft then "draft_status"
  elif .mergeStateStatus == "BLOCKED" then
    if .reviewDecision == "CHANGES_REQUESTED" then "requested_changes"
    elif $checks == "FAILURE" or $checks == "ERROR" then "ci_must_pass"
    elif $checks == "PENDING" or $checks == "EXPECTED" then "ci_still_running"
    elif .reviewDecision == "REVIEW_REQUIRED" then "not_approved"
    elif any(.reviewThreads.nodes[]; .isResolved | not) then "discussions_not_resolved"
    else "blocked" end
  else
    {CLEAN: "mergeable", HAS_HOOKS: "mergeable", UNSTABLE: "mergeable", BEHIND: "need_rebase",
     DIRTY: "conflict", DRAFT: "draft_status", UNKNOWN: "checking"}[.mergeStateStatus // ""] // "checking"
  end;

# A pull request as the MR node of share/mr-query.sh, its iid a string as
# GitLab's GraphQL has it (the REST one's is a number). $bases maps a head
# sha to its merge base where it could be worked out here; GitLab's baseSha,
# which GitHub does not send.
def mr($repo; $bases):
  . as $p |
  [.latestReviews.nodes[] | {username: .author.login, id: .author.databaseId, mergeRequestInteraction: {reviewState: (.state | review_state)}}] as $reviewed |
  [.reviewRequests.nodes[] | .requestedReviewer | select(.login // .slug) | {username: (.login // .slug), id: .databaseId}
    | select(.username | IN($reviewed[].username) | not) | .mergeRequestInteraction = {reviewState: "UNREVIEWED"}] as $asked |
  {iid: (.number | tostring), title, description: (.body // ""), draft: .isDraft, webUrl: .url,
   author: {username: .author.login}, sourceBranch: .headRefName, targetBranch: .baseRefName,
   createdAt, updatedAt,
   detailedMergeStatus: merge_status,
   resolvableDiscussionsCount: .reviewThreads.totalCount,
   resolvedDiscussionsCount: ([.reviewThreads.nodes[] | select(.isResolved)] | length),
   approved: (.reviewDecision == "APPROVED"),
   approvalsRequired: (if .reviewDecision == null then 0 else 1 end),
   approvalsLeft: (if .reviewDecision == "REVIEW_REQUIRED" or .reviewDecision == "CHANGES_REQUESTED" then 1 else 0 end),
   autoMergeEnabled: (.autoMergeRequest != null),
   mergeUser: (if .mergedBy then {username: .mergedBy.login} else null end),
   diffRefs: {headSha: .headRefOid, baseSha: ($bases[.headRefOid] // null), startSha: .baseRefOid},
   diffStatsSummary: {additions, deletions, fileCount: .changedFiles},
   approvedBy: {nodes: [$reviewed[] | select(.mergeRequestInteraction.reviewState == "APPROVED") | {username}]},
   reviewers: {nodes: ($reviewed + $asked)},
   labels: {nodes: [.labels.nodes[] | {title: .name}]},
   headPipeline: pipeline($repo; .number)};

# The same pull request as GitLab's REST MR (GET merge_requests/:iid).
# How it merges is the repository's default for you (merge, squash or
# rebase), as the merge button's is.
def rest_mr($repo; $bases):
  mr($repo; $bases) as $m | (.baseRepository.viewerDefaultMergeMethod // "MERGE" | ascii_downcase) as $how |
  {iid: .number, id: .id, title: $m.title, description: $m.description, draft: $m.draft, web_url: $m.webUrl,
   state: ({OPEN: "opened", CLOSED: "closed", MERGED: "merged"}[.state // "OPEN"]), author: $m.author,
   source_branch: $m.sourceBranch, target_branch: $m.targetBranch,
   sha: $m.diffRefs.headSha, created_at: $m.createdAt, updated_at: $m.updatedAt,
   detailed_merge_status: $m.detailedMergeStatus, merge_status: $m.detailedMergeStatus,
   merge_when_pipeline_succeeds: $m.autoMergeEnabled, merge_method: $how, squash_on_merge: ($how == "squash"),
   should_remove_source_branch: (.baseRepository.deleteBranchOnMerge // false), force_remove_source_branch: null,
   rebase_in_progress: false,
   head_pipeline: (if $m.headPipeline then {id: ($m.headPipeline.id | tonumber? // null), status: ($m.headPipeline.status | ascii_downcase)} else null end),
   diff_refs: {head_sha: $m.diffRefs.headSha, base_sha: $m.diffRefs.baseSha, start_sha: $m.diffRefs.startSha},
   labels: [$m.labels.nodes[].title],
   reviewers: [$m.reviewers.nodes[] | select(.id) | {id, username, name: .username}]};

# A GitHub REST pull request (GET pulls, which the GraphQL is not needed for)
# as a REST MR, as much of one as that list says.
def rest_pull:
  {iid: .number, title, description: (.body // ""), draft, web_url: .html_url,
   state: (if .merged_at then "merged" elif .state == "open" then "opened" else "closed" end),
   author: {username: .user.login}, source_branch: .head.ref, target_branch: .base.ref, sha: .head.sha,
   created_at, updated_at, labels: [.labels[].name],
   diff_refs: {head_sha: .head.sha, base_sha: null, start_sha: .base.sha},
   reviewers: [.requested_reviewers[] | {id, username: .login, name: .login}]};

# A check run, as a GitLab REST job.
def rest_job:
  {id, name, stage: (.app.name // "checks"), allow_failure: false, web_url: .html_url,
   started_at, finished_at: .completed_at,
   duration: (if .started_at and .completed_at then [(.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601), 0] | max else null end),
   status: (if .status == "completed" then
       {success: "success", neutral: "success", skipped: "skipped", failure: "failed", timed_out: "failed",
        startup_failure: "failed", cancelled: "canceled", stale: "canceled", action_required: "manual"}[.conclusion // ""] // "failed"
     elif .status == "in_progress" then "running" else "pending" end)};

# The GraphQL a pull request's threads are asked with: its review threads,
# submitted and pending (your drafts), and its comments.
def thread_fields: "
  id headRefOid baseRefOid
  reviewThreads(first: 100) { nodes { id isResolved isOutdated path subjectType diffSide startDiffSide line startLine originalLine originalStartLine
    comments(first: 100) { nodes { id databaseId body createdAt state author { login } originalCommit { oid } } } } }
  comments(first: 100) { nodes { databaseId body createdAt author { login } } }";

# Where a thread is, as a GitLab position: its line on the head's side
# (new_line) or the base's (old_line), and the commits it was made against,
# which is how git-mr-threads tells a line from an outdated one. An outdated
# thread keeps the commit it was made on, so it reads as outdated there too.
def position($head; $base):
  (if .isOutdated then (.comments.nodes[0].originalCommit.oid // "") else $head end) as $h |
  (if .isOutdated then "" else ($base // "") end) as $b |
  (.line // .originalLine) as $l | (.startLine // .originalStartLine) as $s |
  def at($side; $n): if $side == "LEFT" then {type: "old", old_line: $n, new_line: null} else {type: "new", old_line: null, new_line: $n} end;
  {new_path: .path, old_path: .path, head_sha: $h, base_sha: $b, start_sha: $b, position_type: "text"} +
  if .subjectType == "FILE" or $l == null then {position_type: "file"}
  else
    (at(.diffSide; $l) | del(.type)) as $end |
    {new_line: $end.new_line, old_line: $end.old_line} +
    (if $s != null and $s != $l then {line_range: {start: at(.startDiffSide // .diffSide; $s), end: at(.diffSide; $l)}} else {} end)
  end;

def note:
  {id: .databaseId, body, author: {username: (.author.login // "ghost")}, created_at: .createdAt, system: false};

# Review threads as GitLab discussions, a thread's submitted comments its
# notes, its position on the first. Comments on the pull request itself are
# one-note discussions that cannot be resolved, as GitLab's are.
def discussions:
  .data.repository.pullRequest as $pr | ($pr.base // null) as $base |
  ([$pr.reviewThreads.nodes[] | position($pr.headRefOid; $base) as $pos |
     [.comments.nodes[] | select(.state != "PENDING")] as $sent | select($sent | length > 0) |
     {id, resolvable: true, resolved: .isResolved, individual_note: false,
      notes: ([$sent[] | note] | .[0].position = $pos)}]) +
  ([$pr.comments.nodes[] |
     {id: ("comment-\(.databaseId)"), resolvable: false, resolved: false, individual_note: true, notes: [note | .position = null]}]);

# Your pending review's comments as GitLab draft notes: a reply to a thread
# names it (discussion_id), a new thread carries its position. Their ids are
# the comments' node ids, which is what editing or deleting one takes.
def drafts:
  .data.repository.pullRequest as $pr | ($pr.base // null) as $base |
  [$pr.reviewThreads.nodes[] | position($pr.headRefOid; $base) as $pos |
    ([.comments.nodes[] | select(.state != "PENDING")] | length > 0) as $sent | .id as $thread |
    .comments.nodes[] | select(.state == "PENDING") |
    {id, note: .body, discussion_id: (if $sent then $thread else null end), position: (if $sent then null else $pos end)}];

# A GitLab position as where a GitHub review comment goes: its last line, and
# its first where it spans several.
def github_line:
  (if (.line_range.end.type // "") == "old" or (.new_line == null and .old_line != null)
   then {side: "LEFT", line: (.line_range.end.old_line // .old_line)}
   else {side: "RIGHT", line: (.line_range.end.new_line // .new_line)} end) as $end |
  (if .line_range.start then
     (if .line_range.start.type == "old" then {start_side: "LEFT", start_line: .line_range.start.old_line}
      else {start_side: "RIGHT", start_line: .line_range.start.new_line} end)
   else {} end) as $start |
  {path: (.new_path // .old_path)} + $end +
  (if $start.start_line and $start.start_line != 0 and ($start.start_line != $end.line or $start.start_side != $end.side) then $start else {} end);
