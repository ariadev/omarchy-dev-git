#!/usr/bin/env bash
# End-to-end behaviour with no network. Every host below is unreachable on
# purpose, which is what lets these run offline and in CI: the collector must
# still emit a complete, well-formed document the panel can render.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "collector"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Port 9 (discard) refuses immediately, so failures are instant rather than
# waiting out a timeout.
readonly DEAD=127.0.0.1:9

# A PATH holding everything the collector needs and nothing it looks for: no
# `gh`, no `glab`. Building it explicitly is the only way to test the
# CLI-not-installed hints on a machine where both are installed.
readonly BARE_PATH="$work/bin"
mkdir -p "$BARE_PATH"
for tool in bash sh env curl jq awk date mktemp tr sed grep egrep head tail cat cp mv rm \
            mkdir dirname basename find sort wc cut uniq printf sleep; do
  target=$(command -v "$tool" 2>/dev/null) && ln -sf "$target" "$BARE_PATH/$tool"
done

# The same PATH plus stub CLIs that hand back a token, so a run reaches the
# HTTP layer without any real credential.
readonly STUB_PATH="$work/stub"
mkdir -p "$STUB_PATH"
cp -a "$BARE_PATH/." "$STUB_PATH/"
printf '#!/bin/sh\necho stub-token\n' >"$STUB_PATH/gh"
printf '#!/bin/sh\necho stub-token\n' >"$STUB_PATH/glab"
chmod +x "$STUB_PATH/gh" "$STUB_PATH/glab"

# Run against dead hosts with credentials present, so the collector gets past
# the auth gate and into the HTTP failure paths.
run_dead() {
  env -i HOME="$HOME" PATH="$STUB_PATH" XDG_CONFIG_HOME="$work/none" \
      GH_HOST="$DEAD" GITLAB_HOST="$DEAD" \
      bash "$COLLECTOR" "$@" 2>"$work/stderr"
}

# --- the script itself -----------------------------------------------------

assert_eq "0" "$(bash -n "$COLLECTOR" 2>&1; echo $?)" "the collector parses"
assert_eq "0" "$(jq -L "$JQ_LIB_DIR" -n 'include "gitwork"; empty_calendar' >/dev/null 2>&1; echo $?)" \
  "the jq module loads"
[[ -x $COLLECTOR ]] && ok "the collector is executable" || fail "the collector is executable"
assert_contains "$(head -1 "$COLLECTOR")" "bash" "the collector declares a bash interpreter"

# The panel invokes it with Go-style single-dash flags; both spellings work.
assert_contains "$("$COLLECTOR" --help)" "-output PATH" "help documents the output flag"
assert_eq "2" "$("$COLLECTOR" --nonsense >/dev/null 2>&1; echo $?)" "an unknown flag is rejected"
assert_eq "2" "$("$COLLECTOR" -output >/dev/null 2>&1; echo $?)" "a flag without its value is rejected"

# --- the document shape ----------------------------------------------------

doc=$(run_dead -pretty false)
assert_eq "0" "$(jq -e . <<<"$doc" >/dev/null 2>&1; echo $?)" "the output is valid JSON"
assert_eq "3" "$(jq -r .schemaVersion <<<"$doc")" "the schema version is declared"
assert_eq "0" "$(jq -r '.updatedAt | fromdateiso8601 | if . > 0 then 0 else 1 end' <<<"$doc")" \
  "updatedAt is a parseable timestamp"
assert_eq "number" "$(jq -r '.elapsedMs | type' <<<"$doc")" "elapsedMs is reported"
assert_eq "2" "$(jq -r '.providers | length' <<<"$doc")" "both providers are present"

# Every field the panel reads must exist on every record, whether or not the
# host answered — a missing key renders as undefined rather than as zero.
required='["key","kind","name","host","hostLabel","defaultHost","ready","stale","staleAt",
  "username","displayName","webUrl","userUrl","authHelpText","error","updatedAt","elapsedMs",
  "mrTerm","mrTermShort","calendar","reviewRequests","assignedPrs","authoredPrs",
  "assignedIssues","authoredIssues","totals"]'
assert_eq "0" "$(jq -r --argjson want "$required" \
  '[.providers[] | keys_unsorted as $have | $want - $have] | flatten | length' <<<"$doc")" \
  "every provider carries every field the panel reads"

cal_required='["supported","start","end","weeks","counts","levels","total","current",
  "longest","today","max","monthStarts"]'
assert_eq "0" "$(jq -r --argjson want "$cal_required" \
  '[.providers[].calendar | keys_unsorted as $have | $want - $have] | flatten | length' <<<"$doc")" \
  "every calendar carries every field the panel reads"

assert_eq "0" "$(jq -r '[.providers[] | select((.key | type) != "string" or
  (.ready | type) != "boolean" or (.totals | type) != "object" or
  (.reviewRequests | type) != "array")] | length' <<<"$doc")" \
  "field types match the contract"

# --- unreachable hosts -----------------------------------------------------

assert_eq "false" "$(jq -r '[.providers[].ready] | any' <<<"$doc")" \
  "an unreachable host is never ready"
assert_contains "$(jq -r '.providers[0].authHelpText' <<<"$doc")" "Could not reach" \
  "an unreachable host says so"
assert_contains "$(jq -r '.providers[0].error' <<<"$doc")" "HTTP" \
  "a transport failure is recorded as an error"
assert_eq "0" "$(jq -r '[.providers[] | .reviewRequests, .authoredPrs, .assignedIssues]
  | flatten | length' <<<"$doc")" "a failed host reports no rows"
assert_eq "" "$(cat "$work/stderr")" "a failed host is not noise on stderr"

# Discovery order is display order: GitHub leads, then GitLab.
assert_eq "github gitlab" "$(jq -r '[.providers[].kind] | join(" ")' <<<"$doc")" \
  "providers are ordered GitHub then GitLab"
assert_eq "true true" "$(jq -r '[.providers[].defaultHost] | join(" ")' <<<"$doc")" \
  "the first host of each provider is its default"

# --- missing credentials ---------------------------------------------------

# With no CLI and no token, the collector must still describe itself rather
# than failing: the hint is the only thing the user can act on.
bare=$(env -i HOME="$HOME" PATH="$BARE_PATH" XDG_CONFIG_HOME="$work/none" \
  GH_HOST=github.com GITLAB_HOST=gitlab.com \
  bash "$COLLECTOR" -pretty false 2>/dev/null)
assert_eq "0" "$(jq -e . <<<"$bare" >/dev/null 2>&1; echo $?)" "a credential-less run still emits JSON"
assert_contains "$(jq -r '.providers[0].authHelpText' <<<"$bare")" "gh auth login" \
  "the GitHub hint names the command that fixes it"
assert_contains "$(jq -r '.providers[1].authHelpText' <<<"$bare")" "glab auth login" \
  "the GitLab hint names the command that fixes it"
assert_eq "" "$(jq -r '.providers[0].error' <<<"$bare")" \
  "a missing credential is not an error, so nothing is carried over it"

# --- writing to a file -----------------------------------------------------

out="$work/state/overview.json"
run_dead -output "$out" >/dev/null
[[ -f $out ]] && ok "the output directory is created on demand" || fail "the output directory is created on demand"
assert_eq "0" "$(jq -e . "$out" >/dev/null 2>&1; echo $?)" "the written file is valid JSON"
assert_eq "0" "$(find "$(dirname "$out")" -name '*.tmp' | wc -l)" \
  "no temporary file is left beside the output"

# The panel watches this file, so it must never observe a partial write.
assert_contains "$(grep -c 'mv -f "\$output.tmp" "\$output"' "$COLLECTOR")" "1" \
  "the output is renamed into place rather than written over"

# A second run reads the first as its previous document and must not corrupt it.
run_dead -output "$out" >/dev/null
assert_eq "0" "$(jq -e . "$out" >/dev/null 2>&1; echo $?)" "a repeat run leaves valid JSON"
assert_eq "3" "$(jq -r .schemaVersion "$out")" "a repeat run keeps the schema version"

# --- formatting ------------------------------------------------------------

assert_eq "1" "$(run_dead -pretty false | wc -l)" "compact output is one line"
assert_eq "1" "$(run_dead -pretty true | head -2 | tail -1 | grep -c '^  "')" \
  "pretty output is indented two spaces"

finish
