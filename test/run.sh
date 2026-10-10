#!/usr/bin/env bash
# Fixture-driven test suite for claude-statusline.sh.
# Usage: ./test/run.sh
#
# Fixtures may contain placeholders, substituted at run time:
#   __RESET_FUTURE__    epoch seconds ~2h12m from now  (5h window)
#   __RESET_FUTURE_7D__ epoch seconds ~3 days from now  (7d window)
#   __CWD__             the repo directory (a real git repo)
# Timestamps must be computed, not hardcoded: a fixed far-future epoch made the
# countdown render "615298h 15m" while substring assertions still passed.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$script_dir")"
target="$repo_dir/claude-statusline.sh"
fixtures_dir="$script_dir/fixtures"

if [[ ! -x "$target" ]]; then
  echo "FAIL: $target is not executable or missing" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to run these tests" >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

now=$(date +%s)
reset_future=$(( now + 7920 ))    # 2h 12m
reset_future_7d=$(( now + 259200 ))  # 3d

# Isolate from the developer's real account map, logged-in account and usage
# cache so results are reproducible. With the real ~/.claude.json, fixtures
# would publish into and read from the developer's live shared usage cache.
export XDG_CONFIG_HOME="$work_dir/config"
export XDG_CACHE_HOME="$work_dir/cache"
mkdir -p "$XDG_CONFIG_HOME/claude-statusline" "$work_dir/nohome"
export HOME="$work_dir/nohome"

fail=0
pass=0

strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# prepare FIXTURE -> path to a fixture with placeholders substituted
prepare() {
  local fixture=$1
  local out="$work_dir/$fixture"
  sed -e "s|__RESET_FUTURE_7D__|$reset_future_7d|g" \
      -e "s|__RESET_FUTURE__|$reset_future|g" \
      -e "s|__CWD__|$repo_dir|g" \
      "$fixtures_dir/$fixture" > "$out"
  printf '%s' "$out"
}

run_fixture() { "$target" < "$(prepare "$1")" 2>/dev/null; }

ok()   { pass=$((pass + 1)); echo "  PASS: $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL: $1"; echo "        output: $2"; }

# assert_contains FIXTURE NEEDLE
assert_contains() {
  local out; out=$(run_fixture "$1" | strip_ansi)
  if [[ "$out" == *"$2"* ]]; then ok "$1 contains '$2'"; else bad "$1 missing '$2'" "$out"; fi
}

# assert_not_contains FIXTURE NEEDLE
assert_not_contains() {
  local out; out=$(run_fixture "$1" | strip_ansi)
  if [[ "$out" != *"$2"* ]]; then ok "$1 omits '$2'"; else bad "$1 should omit '$2'" "$out"; fi
}

# assert_matches FIXTURE REGEX LABEL  (regex runs against ANSI-stripped output)
assert_matches() {
  local out; out=$(run_fixture "$1" | strip_ansi)
  if [[ "$out" =~ $2 ]]; then ok "$1 $3"; else bad "$1 $3" "$out"; fi
}

# assert_color FIXTURE SEGMENT_LITERAL COLOR_CODE LABEL  (colors kept intact)
# Substring match on the raw escape + literal segment text, so callers do not
# have to escape regex metacharacters like the '[' in a tag.
assert_color() {
  local out needle
  out=$(run_fixture "$1")
  needle=$'\033'"[$3m$2"
  if [[ "$out" == *"$needle"* ]]; then ok "$1 $4"; else bad "$1 $4" "$(printf '%s' "$out" | tr -d '\033')"; fi
}

# assert_exit_zero FIXTURE  (the bar must never blank)
assert_exit_zero() {
  local out rc
  out=$("$target" < "$(prepare "$1")" 2>/dev/null); rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    ok "$1 exits 0 with non-empty output"
  else
    bad "$1 exit=$rc, output must be non-empty" "$out"
  fi
}

# assert_no_stderr FIXTURE
assert_no_stderr() {
  local err
  err=$("$target" < "$(prepare "$1")" 2>&1 >/dev/null)
  if [[ -z "$err" ]]; then ok "$1 writes nothing to stderr"; else bad "$1 leaked stderr" "$err"; fi
}

echo "full.json (docs-realistic floats, future reset) ..."
assert_contains full.json "Opus"
# 42.4 -> 42, 67.2 -> 67, 41.2 -> 41 (half-up rounding)
assert_contains full.json "ctx 42%"
assert_contains full.json "7d 41%"
# Bug 1 regression: countdown must be a plausible sub-5h duration, not 615298h.
assert_matches  full.json '5h 67% \(2h 1[12]m\)' "renders a plausible 5h countdown"
assert_matches  full.json '^\[' "starts with the account tag"
# Compare against the branch actually checked out. Hardcoding "main" made this
# assertion pass only while the repo happened to be on main, so it failed on
# every feature branch for a segment that was rendering correctly.
assert_contains full.json "$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null \
  || git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)"
assert_exit_zero full.json
assert_no_stderr full.json

echo "threshold-floats.json (rounding at color boundaries) ..."
# Bug 3 regression: 89.7 must round UP to 90 and turn red, not truncate to 89/yellow.
assert_contains threshold-floats.json "5h 90%"
assert_color    threshold-floats.json '5h 90%' 31 "colors 5h 90% red"
# 69.6 -> 70 crosses the ctx red threshold.
assert_contains threshold-floats.json "ctx 70%"
assert_color    threshold-floats.json 'ctx 70%' 31 "colors ctx 70% red"
# 0.4 -> 0, and must still render rather than being dropped as empty.
assert_contains threshold-floats.json "7d 0%"
assert_color    threshold-floats.json '7d 0%' 32 "colors 7d 0% green"

echo "past-reset.json (reset already elapsed) ..."
# Bug 2 regression: an elapsed window must omit the countdown, not claim "(0m)".
assert_contains     past-reset.json "5h 50%"
assert_not_contains past-reset.json "(0m)"
assert_not_contains past-reset.json "("
assert_exit_zero    past-reset.json

echo "no-ratelimits.json (free tier / pre-first-response) ..."
assert_contains     no-ratelimits.json "Opus"
assert_contains     no-ratelimits.json "ctx 42%"
assert_not_contains no-ratelimits.json "5h "
assert_not_contains no-ratelimits.json "7d "
# Bug 4: with no usage data the tag falls back to grey (90).
assert_color        no-ratelimits.json '[' 90 "greys the tag when no usage data"

echo "null-context.json ..."
assert_contains     null-context.json "Opus"
assert_not_contains null-context.json "ctx"
assert_exit_zero    null-context.json

echo "not-git.json (cwd is not a repo) ..."
assert_contains     not-git.json "Opus"
assert_contains     not-git.json "ctx 42%"
assert_not_contains not-git.json "main"
assert_exit_zero    not-git.json

echo "malformed.json (invalid JSON) ..."
# Bug 5 regression: must print a marker, exit 0, and keep stderr clean.
assert_exit_zero  malformed.json
assert_no_stderr  malformed.json
assert_contains   malformed.json "bad input"

echo "empty-object.json ..."
assert_exit_zero empty-object.json
assert_contains  empty-object.json "Claude"

echo "edge cases (inline payloads) ..."
# Empty stdin.
out=$(printf '' | "$target" 2>/dev/null); rc=$?
if (( rc == 0 )) && [[ "$out" == *"empty input"* ]]; then
  ok "empty stdin reports empty input and exits 0"
else
  bad "empty stdin (exit=$rc)" "$out"
fi

# Non-numeric resets_at must not abort the render (previously exited 1, blank bar).
out=$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":67.2,"resets_at":"2026-07-24T18:00:00Z"}}}' \
  | "$target" 2>/dev/null | strip_ansi); rc=$?
if (( rc == 0 )) && [[ "$out" == *"5h 67%"* && "$out" != *"("* ]]; then
  ok "non-numeric resets_at degrades to no countdown, exits 0"
else
  bad "non-numeric resets_at (exit=$rc)" "$out"
fi

# Detached HEAD must still show an @sha rather than dropping the segment.
detached="$work_dir/detached"
git init -q "$detached" 2>/dev/null
git -C "$detached" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
sha=$(git -C "$detached" rev-parse --short HEAD 2>/dev/null)
git -C "$detached" checkout -q --detach HEAD 2>/dev/null
out=$(printf '{"cwd":"%s","model":{"display_name":"Opus"}}' "$detached" | "$target" 2>/dev/null | strip_ansi)
if [[ "$out" == *"@$sha"* ]]; then
  ok "detached HEAD renders @$sha"
else
  bad "detached HEAD should render @$sha" "$out"
fi

# A mapped account renders its label and takes the 5h usage color.
cat > "$XDG_CONFIG_HOME/claude-statusline/accounts.toml" <<'TOML'
[[account]]
label = "B"
email = "mapped@example.com"

[[account]]
email = "other@example.com"
label = "C"
TOML
fake_home="$work_dir/home"
mkdir -p "$fake_home"
printf '{"oauthAccount":{"emailAddress":"mapped@example.com"}}' > "$fake_home/.claude.json"
out=$(HOME="$fake_home" "$target" < "$(prepare full.json)" 2>/dev/null)
if [[ "$(printf '%s' "$out" | strip_ansi)" == "[B]"* ]]; then
  ok "mapped email renders its label (key order independent)"
else
  bad "mapped email should render [B]" "$(printf '%s' "$out" | cat -v)"
fi
# Bug 4 regression: tag mirrors 5h usage (67% -> yellow/33), not grey.
if [[ "$out" == *$'\033'"[33m[B]"* ]]; then
  ok "mapped tag mirrors 5h usage color"
else
  bad "mapped tag should be yellow at 67%" "$(printf '%s' "$out" | cat -v)"
fi

# Bug 4 regression: an unmapped account still shows the usage color, not grey.
printf '{"oauthAccount":{"emailAddress":"unknown@example.com"}}' > "$fake_home/.claude.json"
out=$(HOME="$fake_home" "$target" < "$(prepare full.json)" 2>/dev/null)
if [[ "$out" == *$'\033'"[33m[?]"* ]]; then
  ok "unmapped tag keeps the 5h usage color"
else
  bad "unmapped tag should be yellow at 67%" "$(printf '%s' "$out" | cat -v)"
fi

# A literal label of "?" must not be confused with the unmapped sentinel.
cat > "$XDG_CONFIG_HOME/claude-statusline/accounts.toml" <<'TOML'
[[account]]
email = "q@example.com"
label = "?"
TOML
printf '{"oauthAccount":{"emailAddress":"q@example.com"}}' > "$fake_home/.claude.json"
out=$(HOME="$fake_home" "$target" < "$(prepare full.json)" 2>/dev/null | strip_ansi)
if [[ "$out" == "[?]"* ]]; then
  ok "literal '?' label renders without colliding with the sentinel"
else
  bad "literal '?' label should render [?]" "$out"
fi

echo "shared usage across sessions ..."
rm -f "$XDG_CONFIG_HOME/claude-statusline/accounts.toml"
r5=$(( now + 3600 )); r5_late=$(( now + 7200 )); r7=$(( now + 259200 ))

# home_for EMAIL -> a fake HOME whose ~/.claude.json is logged in as EMAIL
home_for() {
  local h="$work_dir/home-$1"
  mkdir -p "$h"
  printf '{"oauthAccount":{"emailAddress":"%s"}}' "$1" >"$h/.claude.json"
  printf '%s' "$h"
}

# tick EMAIL SESSION FIVE FIVE_RESET SEVEN SEVEN_RESET -> stripped status line
# Pass FIVE="-" for a payload without rate_limits (session before its first response).
tick() {
  local payload
  if [[ "$3" == "-" ]]; then
    payload=$(printf '{"session_id":"%s","model":{"display_name":"Opus"}}' "$2")
  else
    payload=$(printf '{"session_id":"%s","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
      "$2" "$3" "$4" "$5" "$6")
  fi
  printf '%s' "$payload" | HOME="$(home_for "$1")" "$target" 2>/dev/null | strip_ansi
}

# expect LABEL OUTPUT NEEDLE
expect() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (want '$3')" "$2"; fi
}

# A session already open when this feature (or an account switch) arrived is
# first seen WITH numbers of unknown account; it must not publish them.
tick a@example.com s0 99 "$r5_late" 99 "$r7" >/dev/null
out=$(tick a@example.com s3 - - - -)
if [[ "$out" != *"5h"* && "$out" != *"7d"* ]]; then
  ok "a session first seen with numbers does not publish them"
else
  bad "first-seen numbers leaked into the shared cache" "$out"
fi

# New sessions start without rate_limits; their first real reading publishes.
for s in s1 s2 s9; do tick a@example.com "$s" - - - - >/dev/null; done
tick a@example.com s1 80 "$r5" 30 "$r7" >/dev/null
expect "idle session renders the newer 5h reading of its account" \
  "$(tick a@example.com s2 20 "$r5" 10 "$r7")" "5h 80%"
expect "idle session renders the newer 7d reading of its account" \
  "$(tick a@example.com s2 20 "$r5" 10 "$r7")" "7d 30%"
expect "session without rate_limits renders the shared reading" \
  "$(tick a@example.com s3 - - - -)" "5h 80% (59m)"
expect "fresh higher reading from another session wins" \
  "$(tick a@example.com s2 85 "$r5" 31 "$r7")" "5h 85%"
expect "first session follows the newer reading on its next tick" \
  "$(tick a@example.com s1 80 "$r5" 30 "$r7")" "5h 85%"
expect "a later window beats a higher percentage of an older window" \
  "$(tick a@example.com s1 2 "$r5_late" 31 "$r7")" "5h 2%"

# Account switch: s1 still carries account a's numbers (unchanged payload).
# They must neither show nor leak into account b's cache.
tick b@example.com s9 5 "$r5" 1 "$r7" >/dev/null
out=$(tick b@example.com s1 2 "$r5_late" 31 "$r7")
expect "after a switch, a stale session shows the new account's 5h" "$out" "5h 5%"
expect "after a switch, a stale session shows the new account's 7d" "$out" "7d 1%"
expect "the stale numbers did not leak into the new account's cache" \
  "$(tick b@example.com s3 - - - -)" "5h 5%"

# An elapsed shared window means the account starts the new window at 0%. It
# must not fall back to a session's stale snapshot (here s0's 99%, which could
# be the previous account's numbers).
past=$(( now - 60 ))
tick c@example.com s1 90 "$past" 40 "$r7" >/dev/null
out=$(tick c@example.com s0 99 "$r5_late" 99 "$r7")
if [[ "$out" == *"5h 0% "* && "$out" != *"5h 0% ("* && "$out" == *"7d 40%"* ]]; then
  ok "an elapsed shared 5h window renders 0% without countdown, not a stale snapshot"
else
  bad "elapsed shared 5h window should render 0%" "$out"
fi

# Without a logged-in account there is no key, so nothing is cached.
before=$(find "$XDG_CACHE_HOME" -name 'usage-*' | wc -l | tr -d ' ')
printf '{"session_id":"x","rate_limits":{"five_hour":{"used_percentage":50,"resets_at":%s}}}' "$r5" \
  | HOME="$work_dir/nohome" "$target" >/dev/null 2>&1
after=$(find "$XDG_CACHE_HOME" -name 'usage-*' | wc -l | tr -d ' ')
if [[ "$before" == "$after" ]]; then ok "no account means no shared cache file"; else bad "no account wrote a cache file" "$before -> $after"; fi

echo
echo "Passed: $pass  Failed: $fail"
exit $(( fail > 0 ? 1 : 0 ))
