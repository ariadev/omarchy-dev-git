#!/usr/bin/env bash
# Row normalization: every provider is flattened onto one Item shape so the
# panel never branches on which host a row came from.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "items"

# --- authors ---------------------------------------------------------------

# A row in your own queue does not need to tell you who opened it.
assert_eq "" "$(jqlib 'other_author("ariadev"; "ariadev")')" "your own handle is blanked"
assert_eq "" "$(jqlib 'other_author("AriaDev"; "ariadev")')" "the match is case-insensitive"
assert_eq "" "$(jqlib 'other_author(""; "ariadev")')" "a missing author stays empty"
assert_eq "someone" "$(jqlib 'other_author("someone"; "ariadev")')" "another handle is kept"

# --- totals ----------------------------------------------------------------

# The server-side count can exceed the rows we fetched; show the true number
# rather than lying about it, but never report fewer rows than we hold.
assert_json_eq '{"a":90}' "$(jqlib 'totals([["a", 90, 50]])')" "a larger server count wins"
assert_json_eq '{"a":50}' "$(jqlib 'totals([["a", 3, 50]])')" "a stale count never undercounts rows"
assert_json_eq '{"a":0}' "$(jqlib 'totals([["a", 0, 0]])')" "an empty queue is zero"
assert_json_eq '{"a":1,"b":2}' "$(jqlib 'totals([["a",1,0],["b",0,2]])')" "every queue is keyed"

# --- GitHub rows -----------------------------------------------------------

gh_nodes='[
  {"number":7,"title":"Fix bar","url":"https://github.com/o/r/pull/7","updatedAt":"2026-08-01T00:00:00Z",
   "isDraft":true,"reviewDecision":"CHANGES_REQUESTED","author":{"login":"other"},
   "comments":{"totalCount":4},"repository":{"nameWithOwner":"o/r"}},
  {"number":8,"title":"No url","url":"","repository":{"nameWithOwner":"o/r"}}
]'
gh=$(jqlib 'github_items($n; "ariadev")' --argjson n "$gh_nodes")
assert_eq "1" "$(jq -r 'length' <<<"$gh")" "a row without a url is dropped"
assert_json_eq '{
  "number":7,"title":"Fix bar","repository":"o/r","url":"https://github.com/o/r/pull/7",
  "updatedAt":"2026-08-01T00:00:00Z","draft":true,"author":"other",
  "review":"changes_requested","comments":4}' "$(jq -c '.[0]' <<<"$gh")" \
  "a GitHub row maps onto the shared item shape"

assert_eq "" "$(jqlib 'github_items([{"number":1,"url":"u","author":null}]; "me") | .[0].author')" \
  "a deleted GitHub author is empty, not null"
assert_eq "" "$(jqlib 'github_items([{"number":1,"url":"u"}]; "me") | .[0].review')" \
  "a missing review decision is empty"
assert_json_eq '[]' "$(jqlib 'github_items(null; "me")')" "a missing queue yields no rows"

# --- GitLab merge requests -------------------------------------------------

gl_nodes='[
  {"iid":"42","title":"Ship it","webUrl":"https://gitlab.com/g/p/-/merge_requests/42",
   "updatedAt":"2026-08-02T00:00:00Z","draft":false,"approved":true,"userNotesCount":2,
   "author":{"username":"ariadev"},"project":{"fullPath":"g/p"}}
]'
gl=$(jqlib 'gitlab_mr_items($n; "ariadev")' --argjson n "$gl_nodes")
assert_json_eq '{
  "number":42,"title":"Ship it","repository":"g/p",
  "url":"https://gitlab.com/g/p/-/merge_requests/42","updatedAt":"2026-08-02T00:00:00Z",
  "draft":false,"author":"","review":"approved","comments":2}' "$(jq -c '.[0]' <<<"$gl")" \
  "a GitLab merge request maps onto the shared item shape"

assert_eq "number" "$(jqlib 'gitlab_mr_items([{"iid":"9","webUrl":"u"}]; "me") | .[0].number | type')" \
  "the string iid becomes a number"
assert_eq "" "$(jqlib 'gitlab_mr_items([{"iid":"9","webUrl":"u","approved":false}]; "me") | .[0].review')" \
  "an unapproved merge request has no review state"

# --- GitLab issues ---------------------------------------------------------

assert_eq "group/project" "$(jqlib 'project_from_reference("group/project#12")')" \
  "an issue reference yields the project path"
assert_eq "group/project" "$(jqlib 'project_from_reference("group/project!5")')" \
  "a merge request reference does too"
assert_eq "group/sub/project" "$(jqlib 'project_from_reference("group/sub/project#1")')" \
  "nested groups survive"
assert_eq "" "$(jqlib 'project_from_reference("")')" "an empty reference stays empty"

gl_issues='[{"iid":3,"title":"Bug","web_url":"https://gitlab.com/g/p/-/issues/3",
  "updated_at":"2026-08-03T00:00:00Z","user_notes_count":1,
  "author":{"username":"other"},"references":{"full":"g/p#3"}}]'
assert_json_eq '{
  "number":3,"title":"Bug","repository":"g/p","url":"https://gitlab.com/g/p/-/issues/3",
  "updatedAt":"2026-08-03T00:00:00Z","draft":false,"author":"other","review":"","comments":1}' \
  "$(jqlib 'gitlab_issue_items($n; "ariadev") | .[0]' --argjson n "$gl_issues")" \
  "a GitLab issue maps onto the shared item shape"

# --- Gitea rows ------------------------------------------------------------

# One endpoint and one row shape answers both pulls and issues, so the same
# transform has to carry a draft pull and a plain issue.
gt_rows='[
  {"number":11,"title":"Add tea","html_url":"http://gitea.internal:3000/o/r/pulls/11",
   "updated_at":"2026-08-04T00:00:00Z","comments":3,"user":{"login":"other"},
   "repository":{"full_name":"o/r"},"pull_request":{"draft":true,"merged":false}},
  {"number":12,"title":"No url","html_url":""}
]'
gt=$(jqlib 'gitea_items($n; "ariadev"; "http://git.example.com:3000")' --argjson n "$gt_rows")
assert_eq "1" "$(jq -r 'length' <<<"$gt")" "a Gitea row without a url is dropped"
assert_json_eq '{
  "number":11,"title":"Add tea","repository":"o/r","url":"http://git.example.com:3000/o/r/pulls/11",
  "updatedAt":"2026-08-04T00:00:00Z","draft":true,"author":"other","review":"","comments":3}' \
  "$(jq -c '.[0]' <<<"$gt")" "a Gitea pull maps onto the shared shape and configured origin"

assert_eq "false" \
  "$(jqlib 'gitea_items([{"number":1,"html_url":"u"}]; "me"; "http://g") | .[0].draft')" \
  "an issue carries no pull_request block and is never a draft"
assert_eq "" "$(jqlib 'gitea_items([{"number":1,"html_url":"u","user":null}]; "me"; "http://g") | .[0].author')" \
  "a deleted Gitea author is empty, not null"
assert_json_eq '[]' "$(jqlib 'gitea_items(null; "me"; "http://g")')" "a missing Gitea queue yields no rows"

# --- Gitea organizations ---------------------------------------------------

gt_org='{"username":"example-org","full_name":"Example Organization","description":"members"}'
gt_members='[
  {"login":"quiet","full_name":"Quiet Member","active":true},
  {"login":"alice","full_name":"Alice","active":true},
  {"login":"bob","full_name":"Bob","active":true}
]'
gt_events='[
  {"op_type":"commit_repo","created":"2026-08-20T14:40:42-06:00",
   "act_user":{"login":"alice","full_name":"Alice"},
   "repo":{"full_name":"example-org/project"},"ref_name":"refs/heads/feature/a"},
  {"op_type":"commit_repo","created":"2026-08-19T12:00:00-06:00",
   "act_user":{"login":"alice","full_name":"Alice"},
   "repo":{"full_name":"example-org/dev.git"},"ref_name":"refs/heads/main"},
  {"op_type":"commit_repo","created":"2026-08-18T12:00:00-06:00",
   "act_user":{"login":"bob","full_name":"Bob"},
   "repo":{"full_name":"example-org/project"},"ref_name":"refs/heads/fix"},
  {"op_type":"create_repo","created":"2026-08-21T12:00:00-06:00",
   "act_user":{"login":"quiet"},"repo":{"full_name":"example-org/new"}}
]'
gt_organization=$(jqlib \
  'gitea_organization($org; $members; $events; "http://git.example.com:3000")' \
  --argjson org "$gt_org" --argjson members "$gt_members" --argjson events "$gt_events")
assert_eq "example-org|3|alice bob quiet" \
  "$(jq -r '[.name,.recentPushes,([.members[].username]|join(" "))] | join("|")' <<<"$gt_organization")" \
  "organization members are sorted by recent push activity and quiet members remain"
assert_eq "2|example-org/project|feature/a|http://git.example.com:3000/example-org/project" \
  "$(jq -r '.members[0] | [.pushes,.latestRepository,.latestRef,.latestUrl] | join("|")' <<<"$gt_organization")" \
  "a member carries its latest push context on the configured origin"
assert_eq "0||" \
  "$(jq -r '.members[2] | [.pushes,.latestAt,.latestRepository] | join("|")' <<<"$gt_organization")" \
  "a quiet organization member has an explicit zero and no invented activity"
assert_eq "http://public:3000/example-org/repo" \
  "$(jqlib 'rewrite_origin("http://private:3000/example-org/repo"; "http://public:3000")')" \
  "Gitea API links are rewritten from a private bind address"
assert_eq "https://git.example.com/Code/o/r/issues/5" \
  "$(jqlib 'gitea_items([{number:5, repository:{full_name:"o/r"},
    html_url:"http://internal/o/r/issues/5"}]; "me"; "https://git.example.com/Code") | .[0].url')" \
  "queue links use the configured subpath even when the API advertises another base"
assert_eq "https://git.example.com/Code/o/r/pulls/11" \
  "$(jqlib 'gitea_items($n; "me"; "https://git.example.com/Code") | .[0].url' --argjson n "$gt_rows")" \
  "pull links keep the configured subpath"
assert_eq "https://git.example.com/Code/o/r/issues/5" \
  "$(jqlib 'rewrite_origin("http://internal/Code/o/r/issues/5"; "https://git.example.com/Code")')" \
  "fallback links do not duplicate a subpath"
assert_eq "alice bob quiet" \
  "$(jqlib 'gitea_org_members($members + [{login:"ALICE"}]; $events; "https://git.example.com")
    | map(.username | ascii_downcase) | join(" ")' --argjson members "$gt_members" --argjson events "$gt_events")" \
  "members and feed actors are deduplicated case-insensitively"

# --- calendar count extraction ---------------------------------------------

assert_json_eq '{"2026-01-01":2,"2026-01-02":5}' \
  "$(jqlib '{"weeks":[{"contributionDays":[
      {"date":"2026-01-01","contributionCount":2},
      {"date":"2026-01-02","contributionCount":5}]}]} | counts_from_github_calendar')" \
  "GitHub calendar weeks flatten to a day map"

assert_json_eq '{"2026-01-01":2,"2026-01-02":1}' \
  "$(jqlib '[{"created_at":"2026-01-01T09:00:00Z"},{"created_at":"2026-01-01T10:00:00Z"},
      {"created_at":"2026-01-02T10:00:00Z"}] | counts_from_gitlab_events')" \
  "GitLab events tally per day"

assert_json_eq '{}' "$(jqlib '[{"created_at":"bad"},{}] | counts_from_gitlab_events')" \
  "malformed events are skipped rather than crashing the run"

# Gitea reports several buckets a day, so the day total is a sum, not a lookup.
assert_json_eq '{"2026-05-01":3,"2026-05-02":4}' \
  "$(jqlib '[{"timestamp":1777636800,"contributions":1},
      {"timestamp":1777640400,"contributions":2},
      {"timestamp":1777723200,"contributions":4}] | counts_from_gitea_heatmap')" \
  "Gitea heatmap buckets sum per day"

assert_json_eq '{}' "$(jqlib '[{"contributions":3},{}] | counts_from_gitea_heatmap')" \
  "a bucket with no timestamp is skipped"

# --- the base record -------------------------------------------------------

for kind in github gitlab gitea; do
  base=$(jqlib "base_provider(\"$kind\"; \"example.com\"; \"http://example.com\"; false)")
  assert_eq "$kind@example.com" "$(jq -r .key <<<"$base")" "$kind key is kind@host"
  assert_eq "false" "$(jq -r .ready <<<"$base")" "$kind starts unready"
  assert_eq "http://example.com" "$(jq -r .webUrl <<<"$base")" "$kind keeps its configured origin"
  assert_eq "0" "$(jq -r '[.reviewRequests,.assignedPrs,.authoredPrs,.assignedIssues,.authoredIssues]
    | map(length) | add' <<<"$base")" "$kind starts with empty queues"
done

assert_eq "GitHub" "$(jqlib 'base_provider("github"; "h"; "https://h"; true) | .name')" "GitHub is named"
assert_eq "GitLab" "$(jqlib 'base_provider("gitlab"; "h"; "https://h"; true) | .name')" "GitLab is named"
assert_eq "Gitea" "$(jqlib 'base_provider("gitea"; "h"; "https://h"; true) | .name')" "Gitea is named"

assert_eq "Pull requests" "$(jqlib 'base_provider("github"; "h"; "https://h"; true) | .mrTerm')" "GitHub says pull requests"
assert_eq "Pull requests" "$(jqlib 'base_provider("gitea"; "h"; "https://h"; true) | .mrTerm')" "Gitea says pull requests too"
assert_eq "Merge requests" "$(jqlib 'base_provider("gitlab"; "h"; "https://h"; true) | .mrTerm')" "GitLab says merge requests"
assert_eq "PRs" "$(jqlib 'base_provider("github"; "h"; "https://h"; true) | .mrTermShort')" "GitHub short term"
assert_eq "MRs" "$(jqlib 'base_provider("gitlab"; "h"; "https://h"; true) | .mrTermShort')" "GitLab short term"
assert_eq "PRs" "$(jqlib 'base_provider("gitea"; "h"; "https://h"; true) | .mrTermShort')" "Gitea short term"

finish
