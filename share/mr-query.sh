# The GraphQL for merge requests, shared by the two lists that ask for them:
# git-mr-list (gmr) and otis-list (the dashboard). They go through
# git-cached-json under the same cache names, so whichever picker you open
# first warms the other, and a field added here lands in both.
#
#   mr_fields        the node body of an MR in a list you did not author
#   mr_review_query  the MRs requesting your review
#   mr_mine_query    your open MRs, with their pipelines and jobs
#   mr_all_query     every open MR in the project, most recently updated first
mr_fields='nodes { iid title author { username } sourceBranch targetBranch webUrl detailedMergeStatus updatedAt description
  resolvableDiscussionsCount resolvedDiscussionsCount approved approvalsLeft autoMergeEnabled diffRefs { headSha baseSha startSha }
  approvedBy { nodes { username } } headPipeline { id status path }
  reviewers { nodes { username mergeRequestInteraction { reviewState } } } }'

mr_review_query='query($repo: String!) { currentUser { username
  reviewRequestedMergeRequests(state: opened, first: 100, projectPath: $repo) { '"$mr_fields"' } } }'

mr_all_query='query($repo: ID!) { currentUser { username } project(fullPath: $repo) {
  mergeRequests(state: opened, first: 100, sort: UPDATED_DESC) { count '"$mr_fields"' } } }'

mr_mine_query='query($repo: String!) { currentUser { username authoredMergeRequests(state: opened, first: 100, projectPath: $repo, sort: UPDATED_DESC) { nodes {
  iid title draft sourceBranch targetBranch webUrl approved approvalsRequired approvalsLeft autoMergeEnabled mergeUser { username }
  detailedMergeStatus updatedAt resolvableDiscussionsCount resolvedDiscussionsCount diffRefs { headSha baseSha startSha }
  reviewers { nodes { username mergeRequestInteraction { reviewState } } }
  labels { nodes { title } }
  headPipeline { id status path createdAt finishedAt
    jobs(statuses: [FAILED, RUNNING, PENDING, CREATED, SUCCESS], retried: false, first: 200) { nodes { name status allowFailure stage { name } } } } } } } }'
