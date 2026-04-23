#!/usr/bin/env bash
# Fixture-driven smoke test for claude-statusline.sh.
# Usage: ./test/run.sh

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$script_dir")"
target="$repo_dir/claude-statusline.sh"
fixtures_dir="$script_dir/fixtures"

if [[ ! -x "$target" ]]; then
  echo "FAIL: $target is not executable or missing" >&2
  exit 1
fi

fail=0
pass=0

# Strip ANSI escape sequences so assertions match regardless of color.
strip_ansi() {
  # shellcheck disable=SC2001
  sed $'s/\x1b\\[[0-9;]*m//g'
}

# assert_contains FIXTURE NEEDLE
assert_contains() {
  local fixture=$1 needle=$2
  local out
  out=$("$target" < "$fixtures_dir/$fixture" | strip_ansi)
  if [[ "$out" == *"$needle"* ]]; then
    pass=$((pass + 1))
    echo "  PASS: $fixture contains '$needle'"
  else
    fail=$((fail + 1))
    echo "  FAIL: $fixture missing '$needle'"
    echo "  Output: $out"
  fi
}

# assert_not_contains FIXTURE NEEDLE
assert_not_contains() {
  local fixture=$1 needle=$2
  local out
  out=$("$target" < "$fixtures_dir/$fixture" | strip_ansi)
  if [[ "$out" != *"$needle"* ]]; then
    pass=$((pass + 1))
    echo "  PASS: $fixture omits '$needle'"
  else
    fail=$((fail + 1))
    echo "  FAIL: $fixture should omit '$needle'"
    echo "  Output: $out"
  fi
}

echo "full.json ..."
assert_contains   full.json "Opus"
assert_contains   full.json "ctx 42%"
assert_contains   full.json "5h 67%"
assert_contains   full.json "7d 41%"

echo "no-ratelimits.json ..."
assert_contains     no-ratelimits.json "Opus"
assert_contains     no-ratelimits.json "ctx 42%"
assert_not_contains no-ratelimits.json "5h "
assert_not_contains no-ratelimits.json "7d "

echo "null-context.json ..."
assert_contains     null-context.json "Opus"
assert_not_contains null-context.json "ctx"

echo "not-git.json ..."
assert_contains   not-git.json "Opus"
assert_contains   not-git.json "ctx 42%"
# /tmp is not a git repo, so no branch segment.
out=$("$target" < "$fixtures_dir/not-git.json" | strip_ansi)
# Segments are separated by " · ". We expect 5 or fewer segments (no branch).
segment_count=$(printf '%s' "$out" | awk -F' · ' '{print NF}')
if (( segment_count <= 5 )); then
  pass=$((pass + 1))
  echo "  PASS: not-git.json has $segment_count segments (<=5)"
else
  fail=$((fail + 1))
  echo "  FAIL: not-git.json has $segment_count segments (expected <=5)"
  echo "  Output: $out"
fi

echo
echo "Passed: $pass  Failed: $fail"
exit $(( fail > 0 ? 1 : 0 ))
