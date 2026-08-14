#!/usr/bin/env bash
# Run every test file. No network and no credentials are required.

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

failed=0
for test in *-test.sh; do
  ./"$test" || failed=1
  echo
done

if ((failed)); then
  printf '\033[31mFAILED\033[0m\n'
  exit 1
fi
printf '\033[32mAll suites passed\033[0m\n'
