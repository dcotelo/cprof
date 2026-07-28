#!/usr/bin/env bash
set -u
cd "$(dirname "$0")" || exit 1
status=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '== %s\n' "$t"
  bash "$t" || status=1
done
if [ "$status" -eq 0 ]; then
  printf 'ALL TESTS PASSED\n'
else
  printf 'TESTS FAILED\n'
fi
exit "$status"
