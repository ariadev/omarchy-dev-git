#!/usr/bin/env bash
# Shared assertions for the gitwork test suite.
#
# Every test file sources this, calls assertions, and ends with `finish`. The
# collector has no compiler checking it, so these run on the pieces most likely
# to drift: the date math, the quartile buckets, and the carry-forward rules.

set -uo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly PLUGIN_DIR
readonly COLLECTOR="$PLUGIN_DIR/bin/gitwork"
readonly JQ_LIB_DIR="$PLUGIN_DIR/bin"

pass_count=0
fail_count=0

red() { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }

ok() {
  pass_count=$((pass_count + 1))
  printf '  %s %s\n' "$(green ok)" "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf '  %s %s\n' "$(red FAIL)" "$1"
  [[ $# -gt 1 ]] && printf '       %s\n' "${@:2}"
}

assert_eq() {
  local expected=$1 actual=$2 label=$3
  if [[ $expected == "$actual" ]]; then
    ok "$label"
  else
    fail "$label" "expected: $expected" "actual:   $actual"
  fi
}

assert_json_eq() {
  local expected actual label=$3
  expected=$(printf '%s' "$1" | jq -S -c . 2>/dev/null)
  actual=$(printf '%s' "$2" | jq -S -c . 2>/dev/null)
  assert_eq "$expected" "$actual" "$label"
}

assert_contains() {
  local haystack=$1 needle=$2 label=$3
  if [[ $haystack == *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label" "expected to contain: $needle" "actual: $haystack"
  fi
}

# Run a jq program against the collector's module. Extra arguments are passed
# straight through, so tests can bind --argjson values.
jqlib() {
  local program=$1
  jq -r -L "$JQ_LIB_DIR" -n "${@:2}" "include \"gitwork\"; $program"
}

# Load the collector's shell functions without running a collection.
load_collector() {
  # shellcheck disable=SC1090
  GITWORK_TEST_LIB=1 source "$COLLECTOR"
}

finish() {
  printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
  ((fail_count == 0)) || exit 1
}
