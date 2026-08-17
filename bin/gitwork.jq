# jq module for the gitwork collector: calendar math and record assembly.
#
# Everything here is a pure transform. The bash side does I/O and date
# arithmetic that needs the system clock; this file only reshapes JSON, which
# keeps the parts that are easy to get wrong in one testable place.

def empty_calendar:
  { supported: false, start: "", end: "", weeks: 0, counts: [], levels: [],
    total: 0, current: 0, longest: 0, today: 0, max: 0, monthStarts: [] };

# Quartile thresholds over the non-zero days, matching the Go collector: a
# light week and a heavy week both stay readable instead of one washing out.
def quartiles($c):
  ($c | map(select(. > 0)) | sort) as $nz
  | ($nz | length) as $n
  | if $n == 0 then null
    else [ $nz[(0.25 * ($n - 1)) | floor],
           $nz[(0.50 * ($n - 1)) | floor],
           $nz[(0.80 * ($n - 1)) | floor] ]
    end;

def levels_for($c):
  quartiles($c) as $q
  | if $q == null then ($c | map(0))
    else $c | map(
      if   . <= 0     then 0
      elif . <= $q[0] then 1
      elif . <= $q[1] then 2
      elif . <= $q[2] then 3
      else 4 end)
    end;

# A quiet today does not break the run yet — the day is not over — so the walk
# starts at yesterday in that case, which is how both providers present it.
def current_streak($c):
  ($c | reverse) as $r
  | (if ($r[0] // 0) == 0 then $r[1:] else $r end) as $tail
  | ([$tail[] | . > 0] | index(false)) as $stop
  | if $stop == null then ($tail | length) else $stop end;

def longest_streak($c):
  reduce $c[] as $n ({best: 0, run: 0};
    if $n > 0
    then ((.run + 1) as $run | {run: $run, best: (if $run > .best then $run else .best end)})
    else {best: .best, run: 0}
    end)
  | .best;

# Mark each week column with the month that starts inside it, so the axis
# reads Sep Oct Nov ... exactly like the provider's own graph. A column that
# opens after the 25th belongs to the next month, which occupies most of it.
def month_starts($start; $days; $weeks):
  reduce range(0; $weeks) as $w ({last: 0, out: []};
    if ($w * 7) >= $days then {last: .last, out: (.out + [0])}
    else
      ($start + $w * 7 * 86400) as $epoch
      | ($epoch | gmtime | strftime("%d") | tonumber) as $dom
      | (if $dom > 25
         then (($epoch + 7 * 86400) | gmtime | strftime("%m") | tonumber)
         else ($epoch | gmtime | strftime("%m") | tonumber) end) as $month
      | if $month != .last
        then {last: $month, out: (.out + [$month])}
        else {last: .last, out: (.out + [0])} end
    end)
  | .out;

# Turn a "YYYY-MM-DD" -> count object into the dense grid the panel draws.
# $start is the Sunday on or before (today - 364); $days spans through today,
# so counts always splits evenly into $weeks columns of seven rows.
def build_calendar($start; $days; $counts; $reported):
  if $days <= 0 then empty_calendar
  else
    ([range(0; $days)] | map(($start + . * 86400) | gmtime | strftime("%Y-%m-%d"))) as $dates
    | ($dates | map(($counts[.] // 0) | if . < 0 then 0 else . end)) as $c
    | (($days + 6) / 7 | floor) as $weeks
    | ($c | add) as $sum
    | { supported: true,
        start: $dates[0],
        end: $dates[-1],
        weeks: $weeks,
        counts: $c,
        levels: levels_for($c),
        total: (if $reported > 0 then $reported else $sum end),
        current: current_streak($c),
        longest: longest_streak($c),
        today: $c[-1],
        max: (($c | max) // 0),
        monthStarts: month_starts($start; $days; $weeks) }
  end;

# The server-side count can exceed the rows we fetched; show the true number
# rather than lying about it, but never report fewer rows than we hold.
def totals($pairs):
  $pairs | map({key: .[0], value: (if .[1] < .[2] then .[2] else .[1] end)}) | from_entries;

# Blank the author when it is the viewer: a row in your own queue does not
# need to tell you who opened it.
def other_author($author; $viewer):
  if ($author | length) == 0 or ($author | ascii_downcase) == ($viewer | ascii_downcase)
  then "" else $author end;

def base_provider($kind; $host; $is_default):
  { key: ($kind + "@" + $host),
    kind: $kind,
    name: (if $kind == "github" then "GitHub"
           elif $kind == "gitea" then "Gitea"
           else "GitLab" end),
    host: $host,
    hostLabel: $host,
    defaultHost: $is_default,
    ready: false,
    stale: false,
    staleAt: "",
    username: "",
    displayName: "",
    webUrl: ("https://" + $host),
    userUrl: "",
    authHelpText: "",
    error: "",
    updatedAt: "",
    elapsedMs: 0,
    mrTerm: (if $kind == "gitlab" then "Merge requests" else "Pull requests" end),
    mrTermShort: (if $kind == "gitlab" then "MRs" else "PRs" end),
    calendar: empty_calendar,
    reviewRequests: [],
    assignedPrs: [],
    authoredPrs: [],
    assignedIssues: [],
    authoredIssues: [],
    totals: {} };

def github_items($nodes; $viewer):
  [ $nodes[]? | select((.url // "") != "") |
    { number: (.number // 0),
      title: (.title // ""),
      repository: (.repository.nameWithOwner // ""),
      url: .url,
      updatedAt: (.updatedAt // ""),
      draft: (.isDraft // false),
      author: other_author((.author.login // ""); $viewer),
      review: (.reviewDecision // "" | ascii_downcase),
      comments: (.comments.totalCount // 0) } ];

def gitlab_mr_items($nodes; $viewer):
  [ $nodes[]? | select((.webUrl // "") != "") |
    { number: (.iid // "0" | tonumber? // 0),
      title: (.title // ""),
      repository: (.project.fullPath // ""),
      url: .webUrl,
      updatedAt: (.updatedAt // ""),
      draft: (.draft // false),
      author: other_author((.author.username // ""); $viewer),
      review: (if .approved then "approved" else "" end),
      comments: (.userNotesCount // 0) } ];

# "group/project#12" -> "group/project"
def project_from_reference($ref):
  $ref | sub("[#!].*$"; "");

def gitlab_issue_items($rows; $viewer):
  [ $rows[]? | select((.web_url // "") != "") |
    { number: (.iid // 0),
      title: (.title // ""),
      repository: project_from_reference(.references.full // ""),
      url: .web_url,
      updatedAt: (.updated_at // ""),
      draft: false,
      author: other_author((.author.username // ""); $viewer),
      review: "",
      comments: (.user_notes_count // 0) } ];

# Gitea's issue search answers pulls and issues from one endpoint and one row
# shape, so both queues share this. It reports no review decision anywhere in
# the search response, so `review` stays empty rather than guessing.
def gitea_items($rows; $viewer):
  [ $rows[]? | select((.html_url // "") != "") |
    { number: (.number // 0),
      title: (.title // ""),
      repository: (.repository.full_name // ""),
      url: .html_url,
      updatedAt: (.updated_at // ""),
      draft: (.pull_request.draft // false),
      author: other_author((.user.login // ""); $viewer),
      review: "",
      comments: (.comments // 0) } ];

def counts_from_github_calendar:
  [ .weeks[]?.contributionDays[]? | {key: .date, value: .contributionCount} ]
  | from_entries;

# Gitea's heatmap is a flat list of {timestamp, contributions} buckets, several
# per day, so the day totals are summed rather than read off directly.
def counts_from_gitea_heatmap:
  [ .[]? | select((.timestamp // null) != null)
    | {key: (.timestamp | gmtime | strftime("%Y-%m-%d")), value: (.contributions // 0)} ]
  | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries;

def counts_from_gitlab_events:
  [ .[]? | .created_at // "" | select(length >= 10) | .[0:10] ]
  | group_by(.) | map({key: .[0], value: length}) | from_entries;

# Keep the last good record for any host this run could not reach. A dropped
# VPN or a flaky network should not blank a working dashboard — but an
# authentication failure genuinely means the data is gone, so those records
# (which carry no error) are left exactly as the collector found them.
def carry_forward($previous; $schema; $cutoff):
  ($previous | if type == "object" and .schemaVersion == $schema then .providers else [] end) as $old
  | ($old | map({key: .key, value: .}) | from_entries) as $by_key
  | map(
      . as $cur
      | if .ready or (.error | length) == 0 then $cur
        else
          ($by_key[$cur.key] // null) as $prev
          | if $prev == null or ($prev.ready | not) then $cur
            else
              (if $prev.stale and ($prev.staleAt | length) > 0
               then $prev.staleAt else $prev.updatedAt end) as $as_of
              | ($as_of | fromdateiso8601? // 0) as $when
              | if $when < $cutoff then $cur
                else $prev + { stale: true,
                               staleAt: $as_of,
                               updatedAt: $cur.updatedAt,
                               elapsedMs: $cur.elapsedMs,
                               error: $cur.error,
                               authHelpText: $cur.authHelpText }
                end
            end
        end);
