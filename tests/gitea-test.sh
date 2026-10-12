#!/usr/bin/env bash
# Exercise a successful collector and optional API failures without credentials
# or a live server. Tiny pages model servers with a reduced maximum page size.
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "gitea"
load_collector
: "${tmp:?load_collector must create temporary storage}"

test_base="http://git.example.com:3000/Code"
test_mode=ok
export GITEA_HOST="$test_base" GITEA_TOKEN=test-token
request_log="$tmp/requests"
: >"$request_log"

http_get() {
  local url=$1 body=$2 headers=$3 status=200 data='[]' path
  : >"$headers"
  printf '%s\n' "$url" >>"$request_log"
  path=${url#"$test_base/api/v1"}
  case "$path" in
    /user) data='{"login":"alice","full_name":"Alice"}' ;;
    '/user/orgs?limit=50&page=1')
      data='[{"username":"example-org","full_name":"Example Organization"}]'
      printf 'X-Total-Count: 2\r\nLink: <http://internal/user/orgs?page=2>; rel="next"\r\n' >"$headers"
      [[ $test_mode == discovery_failure ]] && status=403
      ;;
    '/user/orgs?limit=50&page=2')
      data='[{"name":"other-org"}]'
      printf 'X-Total-Count: 2\r\n' >"$headers"
      ;;
    '/orgs/example-org/members?limit=50&page=1')
      data='[{"login":"alice"}]'
      printf 'X-Total-Count: 2\r\nLink: <http://internal/members?page=2>; rel="next"\r\n' >"$headers"
      ;;
    '/orgs/example-org/members?limit=50&page=2')
      data='[{"login":"quiet"}]'
      printf 'X-Total-Count: 2\r\n' >"$headers"
      [[ $test_mode == roster_failure ]] && status=500
      ;;
    '/orgs/example-org/activities/feeds?limit=100')
      data='[{"op_type":"commit_repo","created":"2026-08-20T12:00:00Z",
        "act_user":{"login":"alice"},"repo":{"full_name":"example-org/project"}}]'
      [[ $test_mode == missing_feed ]] && status=404
      [[ $test_mode == invalid_feed ]] && data='<html>proxy error</html>'
      [[ $test_mode == empty_feed ]] && data='[]'
      ;;
    '/orgs/other-org/members?limit=50&page=1'|'/orgs/other-org/activities/feeds?limit=100'|\
    '/orgs/example-org/members?limit=50&page=3'|'/users/alice/heatmap') ;;
    '/repos/issues/search?'*)
      data='[{"number":7,"title":"Example issue","repository":{"full_name":"example-org/project"},
        "html_url":"http://internal/example-org/project/issues/7"}]'
      printf 'X-Total-Count: 1\r\n' >"$headers"
      ;;
    '/loop?limit=50&page='*)
      data='[{"login":"repeated"}]'
      printf 'Link: <http://internal/loop?page=2>; rel="next"\r\n' >"$headers"
      ;;
    *) printf 'unexpected: %s\n' "$url" >>"$tmp/unexpected"; status=599 ;;
  esac
  [[ $test_mode == no_headers ]] && : >"$headers"
  printf '%s\n' "$data" >"$body"
  printf '%s' "$status"
}

collect_gitea 'git.example.com:3000/Code' true "$tmp/provider.json"
assert_eq "true|http://git.example.com:3000/Code" \
  "$(jq -r '[.ready,.webUrl] | join("|")' "$tmp/provider.json")" \
  "a successful collector preserves an HTTP base URL with a subpath"
assert_eq "example-org other-org" \
  "$(jq -r '[.organizations[].name] | join(" ")' "$tmp/provider.json")" \
  "all organization pages reach the provider record"
assert_eq "alice quiet" \
  "$(jq -r '[.organizations[0].members[].username] | join(" ")' "$tmp/provider.json")" \
  "all roster pages are joined to activity, including quiet members"
assert_eq "1|true|true" \
  "$(jq -r '.organizations[0] | [.recentPushes,.activityAvailable,.membersAvailable] | join("|")' "$tmp/provider.json")" \
  "successful organization endpoints are marked available"
assert_eq "$test_base/example-org/project/issues/7" \
  "$(jq -r '.authoredIssues[0].url' "$tmp/provider.json")" \
  "the collector emits browser links on the configured base URL"
assert_eq "0" "$(grep -c 'http://internal' "$request_log")" \
  "pagination never follows an advertised internal origin"

for test_mode in missing_feed invalid_feed empty_feed roster_failure discovery_failure; do
  collect_gitea 'git.example.com:3000/Code' true "$tmp/$test_mode.json"
  assert_eq "true|1" \
    "$(jq -r '[.ready,(.authoredIssues | length)] | join("|")' "$tmp/$test_mode.json")" \
    "$test_mode leaves the user's work queues usable"
done
for test_mode in missing_feed invalid_feed; do
  assert_eq "false|2" \
    "$(jq -r '.organizations[0] | [.activityAvailable,(.members | length)] | join("|")' "$tmp/$test_mode.json")" \
    "$test_mode preserves members and marks activity unavailable"
done
assert_eq "true|0" \
  "$(jq -r '.organizations[0] | [.activityAvailable,.recentPushes] | join("|")' "$tmp/empty_feed.json")" \
  "an empty successful feed is distinct from an unavailable one"
assert_eq "false|true|1" \
  "$(jq -r '.organizations[0] | [.membersAvailable,.activityAvailable,(.members | length)] | join("|")' "$tmp/roster_failure.json")" \
  "a failed later roster page is marked unavailable while feed contributors remain"
assert_eq "0" "$(jq '.organizations | length' "$tmp/discovery_failure.json")" \
  "an unavailable organization API remains optional"

test_mode=no_headers
gitea_list "$test_base/api/v1/orgs/example-org/members" "$tmp/no-headers.json"
assert_eq "2" "$(jq 'length' "$tmp/no-headers.json")" \
  "without pagination headers, smaller server pages are read until empty"
test_mode=ok
gitea_list "$test_base/api/v1/loop" "$tmp/capped.json"
assert_eq "1" "$?" "a non-terminating paginated endpoint is bounded"
assert_eq "pagination limit reached" "$(cat "$tmp/capped.json.err")" \
  "the page cap is reported as incomplete data"
[[ ! -f $tmp/unexpected ]] && ok "all requests use expected endpoints" \
  || fail "unexpected requests" "$(cat "$tmp/unexpected")"

finish
