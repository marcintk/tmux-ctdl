#!/usr/bin/env bash
# Discover every test-*.sh under tests/ and the per-agent workspace subdirs
# (workspace/<agent>/tests/) so co-located suites run without a manual list.
cd "$(dirname "$0")/.." || exit 1   # workspace

FAILED=0
while IFS= read -r suite; do
  printf '\n=== %s ===\n' "$suite"
  bash "$suite" || FAILED=1
done < <(find . -name 'test-*.sh' -type f | sort)

[ "$FAILED" -eq 0 ] && printf '\nAll suites passed.\n' || printf '\nSome suites FAILED.\n'
exit $FAILED
