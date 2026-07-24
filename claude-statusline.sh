#!/usr/bin/env bash
# claude-statusline: subscription-aware custom status line for Claude Code.
# Reads one JSON object from stdin, writes one line to stdout. Never exits non-zero.
#
# Input schema: https://code.claude.com/docs/en/statusline
# Notes on the payload that shape this script:
#   - used_percentage is a FLOAT (docs examples: 23.5, 41.2), not an integer.
#   - resets_at is Unix epoch SECONDS.
#   - rate_limits appears only for Claude.ai subscribers (Pro/Max), and only
#     after the first API response of the session. Each window may be absent
#     independently.

set -uo pipefail

# Last-resort guard: if anything unexpected fails, still print something and
# exit 0 so Claude Code never renders a blank bar. Individual risky steps are
# additionally guarded inline, because an ERR trap alone does not stop a failed
# arithmetic expansion from aborting a function mid-render.
trap 'printf "[claude-statusline: error]\n"; exit 0' ERR

# ANSI colors. The status line is never a TTY (it is piped into Claude Code's
# renderer), so colors are always emitted.
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_GREY=$'\033[90m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'

# Sentinel for "no account label matched". Kept distinct from any user-supplied
# label so a literal label of "?" in accounts.toml cannot impersonate it.
readonly NO_LABEL=$'\001none'

# is_uint VALUE -> 0 if VALUE is a plain non-negative integer
# Guards every (( )) arithmetic context against non-numeric API data.
is_uint() {
  [[ $1 =~ ^[0-9]+$ ]]
}

# round_pct FLOAT -> nearest integer, clamped to 0..100
# Uses half-up rounding (89.5 -> 90) so a value sitting on a color threshold
# escalates rather than silently under-reporting usage. Truncation would report
# 89.7 as 89 and render yellow when the 90 threshold deserves red.
round_pct() {
  local raw=$1
  [[ -n "$raw" && "$raw" != "null" ]] || return 1
  awk -v v="$raw" 'BEGIN {
    if (v + 0 != v && v !~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/) exit 1
    r = int(v + 0.5)
    if (r < 0) r = 0
    if (r > 100) r = 100
    print r
  }' 2>/dev/null
}

# color_for_pct PCT LOW HIGH -> ANSI color escape
# pct >= HIGH -> red;  pct >= LOW -> yellow;  else green
color_for_pct() {
  local pct=$1 low=$2 high=$3
  is_uint "$pct" || { printf '%s' "$C_DIM"; return 0; }
  if   (( pct >= high )); then printf '%s' "$C_RED"
  elif (( pct >= low  )); then printf '%s' "$C_YELLOW"
  else printf '%s' "$C_GREEN"
  fi
}

# format_duration SECONDS -> "Xh Ym" or "Mm"
# Callers must not pass a non-positive value; an elapsed window has no
# meaningful countdown and should omit it instead of claiming "0m".
format_duration() {
  local secs=$1
  local hours=$(( secs / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))
  if (( hours > 0 )); then
    printf '%dh %dm' "$hours" "$mins"
  else
    printf '%dm' "$mins"
  fi
}

# git_branch DIR -> branch name, short SHA when detached, or empty
git_branch() {
  local dir=$1
  [[ -n "$dir" && -d "$dir" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  local branch
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || branch=""
  if [[ -z "$branch" ]]; then
    # Detached HEAD (rebase, bisect, checked-out tag): show the short SHA so the
    # segment does not silently vanish exactly when orientation matters most.
    branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) || branch=""
    [[ -n "$branch" ]] && branch="@${branch}"
  fi
  printf '%s' "$branch"
}

# account_label EMAIL -> label from accounts.toml, or $NO_LABEL
# Config lives at ~/.config/claude-statusline/accounts.toml:
#   [[account]]
#   email = "jh@example.com"
#   label = "A"
# First match wins.
account_label() {
  local email=$1
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/accounts.toml"
  [[ -f "$config" && -n "$email" ]] || { printf '%s' "$NO_LABEL"; return 0; }
  local label
  # Buffer email+label per [[account]] block so key order does not matter.
  label=$(awk -v target="$email" '
    /^[[:space:]]*\[\[account\]\]/ { email_val=""; label_val=""; next }
    /^[[:space:]]*email[[:space:]]*=/ {
      if (match($0, /"[^"]*"/)) email_val = substr($0, RSTART + 1, RLENGTH - 2)
    }
    /^[[:space:]]*label[[:space:]]*=/ {
      if (match($0, /"[^"]*"/)) label_val = substr($0, RSTART + 1, RLENGTH - 2)
    }
    email_val != "" && label_val != "" && email_val == target { print label_val; exit }
  ' "$config" 2>/dev/null) || label=""
  [[ -n "$label" ]] || label="$NO_LABEL"
  printf '%s' "$label"
}

# current_email -> active account email from ~/.claude.json, or empty
current_email() {
  local state="$HOME/.claude.json"
  [[ -f "$state" ]] || return 0
  jq -r '.oauthAccount.emailAddress // empty' "$state" 2>/dev/null || true
}

render() {
  local input=$1
  local segments=()

  # Single jq pass: 7 separate invocations meant 7 subprocesses on every refresh
  # tick. One newline-delimited record per field, read into an array.
  #
  # Do NOT use `IFS=$'\t' read -r a b c ...`: word splitting collapses an empty
  # field, shifting every later value one slot left. With a missing
  # context_window that put the 5h percentage into ctx and resets_at into the 5h
  # percentage. Reading one field per line preserves empty fields.
  local parsed
  parsed=$(printf '%s' "$input" | jq -r '
    [ (.model.display_name // "Claude")
    , (.context_window.used_percentage // "")
    , (.rate_limits.five_hour.used_percentage // "")
    , (.rate_limits.five_hour.resets_at // "")
    , (.rate_limits.seven_day.used_percentage // "")
    , (.cwd // "")
    ] | map(tostring) | .[]' 2>/dev/null) || parsed=""

  if [[ -z "$parsed" ]]; then
    # Malformed or non-object JSON. Emit a readable marker rather than a bare
    # or half-built line, and keep stderr quiet so it cannot leak into the bar.
    printf '%s\n' "${C_GREY}[claude-statusline: bad input]${C_RESET}"
    return 0
  fi

  # Read line-by-line rather than with `mapfile`/`readarray`: those are bash 4+
  # builtins and macOS still ships bash 3.2 as /bin/bash, where they are absent.
  local fields=() line
  while IFS= read -r line || [[ -n "$line" ]]; do
    fields+=("$line")
  done <<<"$parsed"

  local model=${fields[0]:-Claude}
  local ctx_raw=${fields[1]:-}
  local five_raw=${fields[2]:-}
  local five_reset=${fields[3]:-}
  local seven_raw=${fields[4]:-}
  local cwd=${fields[5]:-}

  # 5h usage drives both its own segment and the account tag color, so round once.
  local five_pct=""
  five_pct=$(round_pct "$five_raw") || five_pct=""

  # Widget 1: account tag. Colored by 5h usage when known, so the tag itself
  # carries the usage signal even before you read the numbers.
  local email label tag_color="$C_DIM"
  email=$(current_email)
  label=$(account_label "$email")
  if [[ -n "$five_pct" ]]; then
    tag_color=$(color_for_pct "$five_pct" 50 90)
  fi
  if [[ "$label" == "$NO_LABEL" ]]; then
    # Unmapped account: still show usage color when available. Grey only when
    # there is genuinely nothing to report.
    [[ -n "$five_pct" ]] || tag_color="$C_GREY"
    segments+=("${tag_color}[?]${C_RESET}")
  else
    segments+=("${tag_color}[${label}]${C_RESET}")
  fi

  # Widget 2: model (dim).
  segments+=("${C_DIM}${model:-Claude}${C_RESET}")

  # Widget 3: context window usage.
  local ctx_pct
  if ctx_pct=$(round_pct "$ctx_raw"); then
    segments+=("$(color_for_pct "$ctx_pct" 50 70)ctx ${ctx_pct}%${C_RESET}")
  fi

  # Widget 4: 5h window, with countdown to reset when it is still in the future.
  if [[ -n "$five_pct" ]]; then
    local five_color countdown=""
    five_color=$(color_for_pct "$five_pct" 50 90)
    if is_uint "$five_reset"; then
      local now remaining
      now=$(date +%s)
      if is_uint "$now" && (( five_reset > now )); then
        remaining=$(( five_reset - now ))
        countdown=" ($(format_duration "$remaining"))"
      fi
      # Reset already elapsed: omit the countdown entirely. Printing "(0m)"
      # would claim an imminent reset that has in fact already happened.
    fi
    segments+=("${five_color}5h ${five_pct}%${countdown}${C_RESET}")
  fi

  # Widget 5: 7d window.
  local seven_pct
  if seven_pct=$(round_pct "$seven_raw"); then
    segments+=("$(color_for_pct "$seven_pct" 50 90)7d ${seven_pct}%${C_RESET}")
  fi

  # Widget 6: git branch (dim), when cwd is a repo.
  local branch
  branch=$(git_branch "$cwd")
  [[ -n "$branch" ]] && segments+=("${C_DIM}${branch}${C_RESET}")

  # Join with " · ".
  local sep=$' \xc2\xb7 '
  local out="" i
  for i in "${!segments[@]}"; do
    if (( i == 0 )); then out="${segments[i]}"
    else out="${out}${sep}${segments[i]}"
    fi
  done
  printf '%s\n' "$out"
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '[claude-statusline: jq required]\n'
    return 0
  fi

  local input
  input=$(cat) || input=""

  if [[ -z "$input" ]]; then
    printf '[claude-statusline: empty input]\n'
    return 0
  fi

  render "$input"
}

main "$@"
