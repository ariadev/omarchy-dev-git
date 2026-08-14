#!/usr/bin/env bash
# Calendar grid: window alignment, quartile levels, streaks, month labels.
#
# This is the part of the collector with no server to check it — a wrong grid
# renders as a plausible-looking graph, so the shape is asserted explicitly.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "calendar"

# A fixed Sunday so every assertion below is independent of today's date.
# 2024-01-07 is a Sunday; 371 days spans exactly 53 full week columns.
SUNDAY=$(date -u -d 2024-01-07 +%s)

# --- window shape ----------------------------------------------------------

grid=$(jqlib 'build_calendar($s; 371; {}; 0)' --argjson s "$SUNDAY")
assert_eq "2024-01-07" "$(jq -r .start <<<"$grid")" "start is the given Sunday"
assert_eq "2025-01-11" "$(jq -r .end <<<"$grid")" "end is start + 370 days"
assert_eq "53" "$(jq -r .weeks <<<"$grid")" "371 days is 53 week columns"
assert_eq "371" "$(jq -r '.counts|length' <<<"$grid")" "counts spans every day"
assert_eq "371" "$(jq -r '.levels|length' <<<"$grid")" "levels matches counts"
assert_eq "53" "$(jq -r '.monthStarts|length' <<<"$grid")" "monthStarts is one per column"
assert_eq "true" "$(jq -r .supported <<<"$grid")" "a built grid is supported"

# A partial final week still rounds up to a whole column, which is what lets
# the panel draw the grid without doing any date math of its own.
partial=$(jqlib 'build_calendar($s; 367; {}; 0)' --argjson s "$SUNDAY")
assert_eq "53" "$(jq -r .weeks <<<"$partial")" "a partial final week still gets a column"

assert_eq "0" "$(jq -r '.weeks' <<<"$(jqlib 'build_calendar($s; 0; {}; 0)' --argjson s "$SUNDAY")")" \
  "a zero-day window yields the empty calendar"
assert_eq "false" "$(jq -r .supported <<<"$(jqlib 'empty_calendar')")" \
  "the empty calendar is not supported"

# --- counts, totals and max ------------------------------------------------

counts='{"2024-01-07":3,"2024-01-08":10,"2024-01-09":1,"2024-02-01":7}'
filled=$(jqlib 'build_calendar($s; 371; $c; 0)' --argjson s "$SUNDAY" --argjson c "$counts")
assert_eq "21" "$(jq -r .total <<<"$filled")" "total sums every day in the window"
assert_eq "10" "$(jq -r .max <<<"$filled")" "max is the busiest day"
assert_eq "3" "$(jq -r '.counts[0]' <<<"$filled")" "day zero maps to the start date"
assert_eq "0" "$(jq -r '.counts[3]' <<<"$filled")" "a missing day is zero"

reported=$(jqlib 'build_calendar($s; 371; $c; 999)' --argjson s "$SUNDAY" --argjson c "$counts")
assert_eq "999" "$(jq -r .total <<<"$reported")" "a reported total wins over the local sum"

# Days outside the window are ignored rather than folded into the edges.
outside='{"2020-05-05":50,"2024-01-07":2}'
clipped=$(jqlib 'build_calendar($s; 371; $c; 0)' --argjson s "$SUNDAY" --argjson c "$outside")
assert_eq "2" "$(jq -r .total <<<"$clipped")" "days outside the window are ignored"

# --- levels ----------------------------------------------------------------

assert_json_eq '[0,0,0]' "$(jqlib '[0,0,0] | levels_for(.)')" "an all-zero year is all level zero"
assert_eq "null" "$(jqlib 'quartiles([0,0])')" "quartiles are undefined without activity"

# Quartiles run over the non-zero days only, so one heavy day cannot wash out
# a light week. Thresholds land at the 25th, 50th and 80th percentile.
ladder='[0,1,2,3,4,5,6,7,8,9,10]'
assert_json_eq '[3,5,8]' "$(jqlib "quartiles($ladder)")" "quartiles use the non-zero days"
assert_json_eq '[0,1,1,1,2,2,3,3,3,4,4]' "$(jqlib "levels_for($ladder)")" "levels bucket 0-4"
assert_eq "0" "$(jqlib "levels_for($ladder) | .[0]")" "a zero day is always level zero"
assert_eq "4" "$(jqlib "levels_for($ladder) | .[-1]")" "the busiest day is level four"
assert_json_eq '[0,1,1]' "$(jqlib 'levels_for([0,5,5])')" "a flat year collapses to one level"

# --- streaks ---------------------------------------------------------------

assert_eq "3" "$(jqlib 'current_streak([0,1,1,1])')" "current streak counts back from today"
assert_eq "0" "$(jqlib 'current_streak([1,1,0,0])')" "two quiet days end the current streak"
assert_eq "4" "$(jqlib 'current_streak([1,1,1,1])')" "a full run is all current"
assert_eq "0" "$(jqlib 'current_streak([])')" "an empty year has no current streak"

# A quiet today does not break the run yet — the day is not over — so the walk
# starts at yesterday, which is how both providers present it.
assert_eq "2" "$(jqlib 'current_streak([1,1,0])')" "a quiet today does not break the streak"
assert_eq "0" "$(jqlib 'current_streak([0,0])')" "a quiet yesterday does"

assert_eq "3" "$(jqlib 'longest_streak([1,1,1,0,1,1])')" "longest streak spans the whole year"
assert_eq "0" "$(jqlib 'longest_streak([0,0,0])')" "no activity is no streak"
assert_eq "2" "$(jqlib 'longest_streak([0,1,1,0])')" "a streak bounded on both sides counts"

assert_eq "7" "$(jq -r .today <<<"$(jqlib 'build_calendar($s; 371; {"2025-01-11":7}; 0)' --argjson s "$SUNDAY")")" \
  "today is the final day in the window"

# --- month labels ----------------------------------------------------------

months=$(jq -c .monthStarts <<<"$grid")
assert_eq "1" "$(jq -r '.[0]' <<<"$months")" "the first column is labelled with its month"
# The window opens 2024-01-07 and closes 2025-01-11, so January is labelled at
# both ends: thirteen labels across the twelve months it touches.
assert_eq "13" "$(jq -r '[.[] | select(. > 0)] | length' <<<"$months")" \
  "every month the window touches is labelled once"
assert_eq "0" "$(jq -r '[.[] | select(. > 0)] as $l
  | [range(0; ($l | length) - 1) | select($l[.] == $l[. + 1])] | length' <<<"$months")" \
  "no month is labelled twice in a row"
assert_eq "0" "$(jq -r '[.[] | select(. != 0 and (. < 1 or . > 12))] | length' <<<"$months")" \
  "labels are month numbers or the empty marker"

# A column opening after the 25th belongs to the month occupying most of it.
late=$(jqlib 'month_starts($s; 371; 53)' --argjson s "$(date -u -d 2024-01-28 +%s)")
assert_eq "2" "$(jq -r '.[0]' <<<"$late")" "a column opening after the 25th takes the next month"

finish
