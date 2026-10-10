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

# write_atomic FILE CONTENT -> replace FILE via rename so concurrent readers
# (one status line per open session) never see a half-written file.
write_atomic() {
  local tmp
  tmp=$(mktemp "$(dirname "$1")/.tmp.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# is_newer RESET_A PCT_A RESET_B PCT_B -> 0 when window reading A is newer than B
# A later reset means a later window; within one window usage only grows, so a
# higher percentage is the more recent reading. A missing B always loses.
is_newer() {
  awk -v ra="$1" -v pa="$2" -v rb="$3" -v pb="$4" 'BEGIN {
    num = "^[0-9]+([.][0-9]+)?$"
    if (ra !~ num || pa !~ num) exit 1
    if (rb !~ num || pb !~ num) exit 0
    if (ra + 0 > rb + 0) exit 0
    if (ra + 0 == rb + 0 && pa + 0 > pb + 0) exit 0
    exit 1
  }' 2>/dev/null
}

# usage_sync EMAIL SESSION FIVE FIVE_RESET SEVEN SEVEN_RESET
#   -> "five|five_reset|seven|seven_reset" to display
#
# rate_limits in the payload is a snapshot from THIS session's last API
# response, so an idle session shows stale usage forever. All sessions of one
# account share a per-account cache instead: whoever saw the newest numbers
# publishes them, and everyone renders the newest.
#
# A session only publishes when its numbers changed since its previous tick.
# After an account switch, an idle session still carries the OLD account's
# numbers; they are unchanged, so they never leak into the new account's cache.
usage_sync() {
  local email=$1 session=$2 five=$3 five_reset=$4 seven=$5 seven_reset=$6
  local payload="$five|$five_reset|$seven|$seven_reset"
  [[ -n "$email" ]] || { printf '%s' "$payload"; return 0; }

  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
  mkdir -p "$dir" 2>/dev/null || { printf '%s' "$payload"; return 0; }
  local shared
  shared="$dir/usage-$(printf '%s' "$email" | tr -c 'A-Za-z0-9._@-' '_')"

  local s_five="" s_five_reset="" s_seven="" s_seven_reset=""
  if [[ -f "$shared" ]]; then
    IFS='|' read -r s_five s_five_reset s_seven s_seven_reset <"$shared" || true
  fi

  # A session first seen WITH numbers cannot prove which account they belong
  # to (it may predate a switch, or this script), so that first reading is only
  # recorded. New sessions start without rate_limits (they arrive with the first
  # API response), so their first real reading is a change and gets published.
  if [[ -n "$session" ]]; then
    local seen_file last="" known=0
    seen_file="$dir/seen-$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
    if [[ -f "$seen_file" ]]; then
      last=$(cat "$seen_file" 2>/dev/null) || last=""
      known=1
    else
      # New session: prune markers of sessions gone for a week.
      find "$dir" -name 'seen-*' -mtime +7 -delete 2>/dev/null || true
    fi
    if (( ! known )) || [[ "$last" != "$payload" ]]; then
      write_atomic "$seen_file" "$payload"
    fi
    if (( known )) && [[ "$last" != "$payload" && -n "$five$seven" ]]; then
      local changed=0
      if is_newer "$five_reset" "$five" "$s_five_reset" "$s_five"; then
        s_five=$five; s_five_reset=$five_reset; changed=1
      fi
      if is_newer "$seven_reset" "$seven" "$s_seven_reset" "$s_seven"; then
        s_seven=$seven; s_seven_reset=$seven_reset; changed=1
      fi
      (( changed )) && write_atomic "$shared" "$s_five|$s_five_reset|$s_seven|$s_seven_reset"
    fi
  fi

  # The shared reading is never older than this session's payload, so always
  # prefer it. Once its window has reset, the account has used 0% of the new
  # window. Falling back to the payload there would resurrect a stale snapshot,
  # possibly of the account that was active before a switch.
  local now
  now=$(date +%s)
  is_uint "$now" || now=0
  if is_uint "$s_five_reset"; then
    if (( s_five_reset > now )); then five=$s_five; five_reset=$s_five_reset
    else five=0; five_reset=""
    fi
  fi
  if is_uint "$s_seven_reset"; then
    if (( s_seven_reset > now )); then seven=$s_seven; seven_reset=$s_seven_reset
    else seven=0; seven_reset=""
    fi
  fi
  printf '%s' "$five|$five_reset|$seven|$seven_reset"
}

# switch_links CURRENT_LABEL -> "⇄ INFO 98% DEV 3%", one clickable OSC 8 link
# per account saved with claude-acct other than the active one, colored by that
# account's last known 5h usage. Cmd+click opens claude-acct://use/LABEL, which
# the ClaudeAcct handler app turns into `claude-acct use LABEL`.
switch_links() {
  local cur=$1
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
  [[ -d "$config/profiles" ]] || return 0
  local now f l email text color pct p_five p_reset out=""
  now=$(date +%s)
  for f in "$config/profiles"/*.json; do
    [[ -f "$f" ]] || continue
    l=$(basename "$f" .json)
    [[ "$l" == "$cur" ]] && continue
    [[ $l =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue
    text=$l color=$C_DIM
    email=$(jq -r '.emailAddress // empty' "$f" 2>/dev/null) || email=""
    if [[ -n "$email" && -f "$cache/usage-$email" ]]; then
      IFS='|' read -r p_five p_reset _ <"$cache/usage-$email" || true
      if is_uint "$p_reset" && is_uint "$now" && (( p_reset <= now )); then
        pct=0
      else
        pct=$(round_pct "$p_five") || pct=""
      fi
      if [[ -n "$pct" ]]; then
        text="$l ${pct}%"
        color=$(color_for_pct "$pct" 50 90)
      fi
    fi
    out+="${color}"$'\033]8;;'"claude-acct://use/${l}"$'\a'"${text}"$'\033]8;;\a'"${C_RESET} "
  done
  [[ -n "$out" ]] && printf '%s' "${C_DIM}⇄${C_RESET} ${out% }"
  return 0
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
    , (.session_id // "")
    , (.rate_limits.seven_day.resets_at // "")
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
  local session=${fields[6]:-}
  local seven_reset=${fields[7]:-}

  local email
  email=$(current_email)

  # Replace this session's possibly stale snapshot with the newest reading any
  # session of the same account has seen.
  local synced
  synced=$(usage_sync "$email" "$session" "$five_raw" "$five_reset" "$seven_raw" "$seven_reset") \
    || synced="$five_raw|$five_reset|$seven_raw|$seven_reset"
  IFS='|' read -r five_raw five_reset seven_raw seven_reset <<<"$synced" || true

  # 5h usage drives both its own segment and the account tag color, so round once.
  local five_pct=""
  five_pct=$(round_pct "$five_raw") || five_pct=""

  # Widget 1: account tag. Colored by 5h usage when known, so the tag itself
  # carries the usage signal even before you read the numbers.
  local label tag_color="$C_DIM"
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

  # Widget 1b: links to switch to the other saved accounts.
  local switch
  switch=$(switch_links "$label") || switch=""
  [[ -n "$switch" ]] && segments+=("$switch")

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

  # Widget 7: "+ login" link (last, so it sits at the right end of the line).
  # Opens `claude-acct login` in a new window; shown once claude-acct is in use.
  if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/profiles" ]]; then
    segments+=("${C_DIM}"$'\033]8;;claude-acct://login\a+ login\033]8;;\a'"${C_RESET}")
  fi

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
