#!/usr/bin/env bash
# Row normalization: both providers are flattened onto one Item shape so the
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

# --- the base record -------------------------------------------------------

for kind in github gitlab; do
  base=$(jqlib "base_provider(\"$kind\"; \"example.com\"; false)")
  assert_eq "$kind@example.com" "$(jq -r .key <<<"$base")" "$kind key is kind@host"
  assert_eq "false" "$(jq -r .ready <<<"$base")" "$kind starts unready"
  assert_eq "https://example.com" "$(jq -r .webUrl <<<"$base")" "$kind web url defaults to the host"
  assert_eq "0" "$(jq -r '[.reviewRequests,.assignedPrs,.authoredPrs,.assignedIssues,.authoredIssues]
    | map(length) | add' <<<"$base")" "$kind starts with empty queues"
done

assert_eq "Pull requests" "$(jqlib 'base_provider("github"; "h"; true) | .mrTerm')" "GitHub says pull requests"
assert_eq "Merge requests" "$(jqlib 'base_provider("gitlab"; "h"; true) | .mrTerm')" "GitLab says merge requests"
assert_eq "PRs" "$(jqlib 'base_provider("github"; "h"; true) | .mrTermShort')" "GitHub short term"
assert_eq "MRs" "$(jqlib 'base_provider("gitlab"; "h"; true) | .mrTermShort')" "GitLab short term"

finish
