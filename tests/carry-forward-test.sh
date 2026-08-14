#!/usr/bin/env bash
# Stale-record rules. A dropped VPN should not blank a working dashboard, but
# yesterday's queue must not masquerade as today's either, and an expired
# credential genuinely means the data is gone.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "carry-forward"

readonly SCHEMA=3
NOW=$(date -u +%s)
CUTOFF=$((NOW - 6 * 3600))

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A previous run that reached the host and holds real rows.
previous() {
  local at=$1 extra=${2:-'{}'}
  jq -c -n --arg at "$at" --argjson schema "$SCHEMA" --argjson extra "$extra" \
    '{schemaVersion: $schema, providers: [{
       key: "github@github.com", kind: "github", ready: true, stale: false, staleAt: "",
       username: "ariadev", error: "", authHelpText: "", updatedAt: $at,
       elapsedMs: 10, authoredPrs: [{number: 1}], totals: {authoredPrs: 1}} + $extra]}'
}

# The current run for that host, parameterised by how it failed.
current() {
  local error=$1 help=$2
  jq -c -n --arg e "$error" --arg h "$help" \
    '[{key: "github@github.com", kind: "github", ready: false, stale: false, staleAt: "",
       username: "", error: $e, authHelpText: $h, updatedAt: "2026-08-14T12:00:00Z",
       elapsedMs: 5, authoredPrs: [], totals: {}}]'
}

run_carry() {
  local prev=$1 cur=$2
  jq -r -L "$JQ_LIB_DIR" -c --argjson prev "$prev" --argjson schema "$SCHEMA" \
    --argjson cutoff "$CUTOFF" \
    'include "gitwork"; carry_forward($prev; $schema; $cutoff) | .[0]' <<<"$cur"
}

# --- a reachable host is never touched -------------------------------------

fresh=$(run_carry "$(previous "$(iso $((NOW - 60)))")" \
  '[{"key":"github@github.com","ready":true,"error":"","stale":false,"authoredPrs":[{"number":9}]}]')
assert_eq "false" "$(jq -r .stale <<<"$fresh")" "a successful run is never marked stale"
assert_eq "9" "$(jq -r '.authoredPrs[0].number' <<<"$fresh")" "a successful run keeps its own rows"

# --- a network failure carries the last good record ------------------------

was_at=$(iso $((NOW - 3600)))
carried=$(run_carry "$(previous "$was_at")" "$(current 'HTTP 000' 'Could not reach github.com.')")
assert_eq "true" "$(jq -r .ready <<<"$carried")" "a carried record stays ready"
assert_eq "true" "$(jq -r .stale <<<"$carried")" "a carried record is marked stale"
assert_eq "$was_at" "$(jq -r .staleAt <<<"$carried")" "staleAt records when the data was real"
assert_eq "ariadev" "$(jq -r .username <<<"$carried")" "the carried identity survives"
assert_eq "1" "$(jq -r '.authoredPrs | length' <<<"$carried")" "the carried rows survive"
assert_eq "HTTP 000" "$(jq -r .error <<<"$carried")" "the current error is kept, not the old one"
assert_eq "Could not reach github.com." "$(jq -r .authHelpText <<<"$carried")" \
  "the current hint is kept"
assert_eq "2026-08-14T12:00:00Z" "$(jq -r .updatedAt <<<"$carried")" \
  "updatedAt reflects this run, not the carried one"
assert_eq "5" "$(jq -r .elapsedMs <<<"$carried")" "elapsedMs reflects this run"

# --- the six-hour window ---------------------------------------------------

stale=$(run_carry "$(previous "$(iso $((NOW - 9 * 3600)))")" "$(current 'HTTP 000' 'x')")
assert_eq "false" "$(jq -r .ready <<<"$stale")" "a record past the stale window is not carried"
assert_eq "" "$(jq -r .username <<<"$stale")" "nothing is carried from an expired record"

edge=$(run_carry "$(previous "$(iso $((NOW - 6 * 3600 + 120)))")" "$(current 'HTTP 000' 'x')")
assert_eq "true" "$(jq -r .ready <<<"$edge")" "a record just inside the window is carried"

# An already-stale record ages from when the data was real, not from the last
# refresh, so a dead host cannot be carried indefinitely.
old_stale=$(previous "$(iso $((NOW - 60)))" \
  "$(jq -c -n --arg s "$(iso $((NOW - 9 * 3600)))" '{stale: true, staleAt: $s}')")
assert_eq "false" "$(jq -r .ready <<<"$(run_carry "$old_stale" "$(current 'HTTP 000' 'x')")")" \
  "a stale record ages from staleAt, not from its last refresh"

# --- authentication failures are not carried -------------------------------

# An auth failure carries no error string: the data is genuinely gone, so
# showing yesterday's queue would be a lie rather than a courtesy.
auth=$(run_carry "$(previous "$(iso $((NOW - 60)))")" "$(current '' 'Not signed in to github.com.')")
assert_eq "false" "$(jq -r .ready <<<"$auth")" "an auth failure is not carried"
assert_eq "Not signed in to github.com." "$(jq -r .authHelpText <<<"$auth")" \
  "an auth failure keeps its sign-in hint"

# --- nothing to carry from --------------------------------------------------

assert_eq "false" "$(jq -r .ready <<<"$(run_carry 'null' "$(current 'HTTP 000' 'x')")")" \
  "a missing previous document carries nothing"
assert_eq "false" "$(jq -r .ready <<<"$(run_carry '{"schemaVersion":2,"providers":[]}' \
  "$(current 'HTTP 000' 'x')")")" "a previous document at another schema is ignored"

unready_prev=$(jq -c '.providers[0].ready = false' <<<"$(previous "$(iso $((NOW - 60)))")")
assert_eq "false" "$(jq -r .ready <<<"$(run_carry "$unready_prev" "$(current 'HTTP 000' 'x')")")" \
  "an unready previous record is not carried"

other_host=$(jq -c '.providers[0].key = "github@other.example"' <<<"$(previous "$(iso $((NOW - 60)))")")
assert_eq "false" "$(jq -r .ready <<<"$(run_carry "$other_host" "$(current 'HTTP 000' 'x')")")" \
  "records are matched by key, never by position"

# --- multiple providers -----------------------------------------------------

# One dead host must not disturb the record beside it.
both_prev=$(jq -c --argjson schema "$SCHEMA" '.providers += [{
  key: "gitlab@gitlab.com", kind: "gitlab", ready: true, stale: false, staleAt: "",
  username: "glu", error: "", authHelpText: "", updatedAt: .providers[0].updatedAt,
  elapsedMs: 1, authoredPrs: [], totals: {}}]' <<<"$(previous "$(iso $((NOW - 60)))")")
both_cur=$(jq -c '. + [{key:"gitlab@gitlab.com",kind:"gitlab",ready:true,stale:false,
  staleAt:"",username:"glu",error:"",authHelpText:"",updatedAt:"now",elapsedMs:1,
  authoredPrs:[],totals:{}}]' <<<"$(current 'HTTP 000' 'x')")
mixed=$(jq -r -L "$JQ_LIB_DIR" -c --argjson prev "$both_prev" --argjson schema "$SCHEMA" \
  --argjson cutoff "$CUTOFF" 'include "gitwork"; carry_forward($prev; $schema; $cutoff)' <<<"$both_cur")
assert_eq "2" "$(jq -r 'length' <<<"$mixed")" "every provider survives the pass"
assert_eq "true" "$(jq -r '.[0].stale' <<<"$mixed")" "the failed provider is carried"
assert_eq "false" "$(jq -r '.[1].stale' <<<"$mixed")" "the healthy provider beside it is untouched"
assert_eq "github@github.com" "$(jq -r '.[0].key' <<<"$mixed")" "provider order is preserved"

finish
