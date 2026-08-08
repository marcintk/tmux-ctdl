#!/usr/bin/env bash
# Shared test helpers. Source this from each test file.
# Tests return 0 on pass, non-zero on fail. run_tests() drives output.

FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
PASS=0; FAIL=0

ok()   { printf '\033[32m  PASS\033[0m %s\n' "$1"; (( PASS++ )); }
fail() { printf '\033[31m  FAIL\033[0m %s\n' "$1"; (( FAIL++ )); }

assert_contains() {
  local haystack=$1 needle=$2 msg=${3:-"contains '$needle'"}
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    printf '    expected: %s\n' "$msg" >&2
    printf '    got:      %s\n' "$(printf '%s' "$haystack" | head -1)" >&2
    return 1
  fi
}

assert_empty() {
  local val=$1 msg=${2:-"value is empty"}
  if [ -n "$val" ]; then
    printf '    expected empty, got: %s\n' "$val" >&2
    return 1
  fi
}

assert_file_exists() {
  local path=$1 msg=${2:-"file exists: $path"}
  if [ ! -f "$path" ]; then
    printf '    file not found: %s\n' "$path" >&2
    return 1
  fi
}

run_tests() {
  local name err
  for name in "$@"; do
    err=$(mktemp)
    if $name 2>"$err"; then
      ok "$name"
    else
      fail "$name"
      cat "$err" >&2
    fi
    rm -f "$err"
  done
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
