#!/usr/bin/env bash
# claude-statusline: subscription-aware custom status line for Claude Code.
# Reads one JSON object from stdin, writes one line to stdout. Never exits non-zero.

set -uo pipefail

# Always exit 0 so Claude Code doesn't blank the bar.
trap 'exit 0' ERR

# ANSI color helpers. Empty when stdout is not a TTY? Status line is never a
# TTY (it's piped into Claude Code's renderer), so always emit colors.
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_GREY=$'\033[90m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'

# color_for_pct PCT LOW HIGH
# Returns the color escape for a percentage value.
# pct <  LOW  -> green
# pct <  HIGH -> yellow
# pct >= HIGH -> red
color_for_pct() {
  local pct=$1 low=$2 high=$3
  if   (( pct >= high )); then printf '%s' "$C_RED"
  elif (( pct >= low  )); then printf '%s' "$C_YELLOW"
  else printf '%s' "$C_GREEN"
  fi
}

# format_duration SECONDS -> "Xh Ym" or "Mm"
format_duration() {
  local secs=$1
  if (( secs < 0 )); then secs=0; fi
  local hours=$(( secs / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))
  if (( hours > 0 )); then
    printf '%dh %dm' "$hours" "$mins"
  else
    printf '%dm' "$mins"
  fi
}

# git_branch DIR -> branch name or empty string
git_branch() {
  local dir=$1
  [[ -d "$dir" ]] || return 0
  git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true
}

# account_label EMAIL -> "A"/"B"/"C" or "?"
# Reads ~/.config/claude-statusline/accounts.toml which has entries like:
#   [[account]]
#   email = "jh@example.com"
#   label = "A"
# First match wins. Missing config or no match -> "?".
account_label() {
  local email=$1
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/accounts.toml"
  [[ -f "$config" ]] || { printf '?'; return 0; }
  [[ -n "$email" ]]  || { printf '?'; return 0; }
  # Lightweight TOML parse: buffer email+label per [[account]] block (order-independent).
  awk -v target="$email" '
    /^\[\[account\]\]/ { email_val=""; label_val=""; next }
    /^[[:space:]]*email[[:space:]]*=/ {
      match($0, /"[^"]*"/)
      if (RSTART) email_val = substr($0, RSTART + 1, RLENGTH - 2)
    }
    /^[[:space:]]*label[[:space:]]*=/ {
      match($0, /"[^"]*"/)
      if (RSTART) label_val = substr($0, RSTART + 1, RLENGTH - 2)
    }
    email_val != "" && label_val != "" && email_val == target {
      print label_val; exit
    }
  ' "$config" | head -n1 | grep -E '.' || printf '?'
}

# current_email -> email from ~/.claude.json or empty
current_email() {
  local state="$HOME/.claude.json"
  [[ -f "$state" ]] || return 0
  jq -r '.oauthAccount.emailAddress // empty' "$state" 2>/dev/null || true
}

render() {
  local input=$1
  local segments=()

  # Widget 1: account tag. Color mirrors 5h usage (green/yellow/red) when
  # available; otherwise dim.
  local email label tag_color="$C_DIM"
  email=$(current_email)
  label=$(account_label "$email")
  local five_h_used
  five_h_used=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
  if [[ -n "$five_h_used" ]]; then
    tag_color=$(color_for_pct "${five_h_used%.*}" 50 90)
  fi
  if [[ "$label" == "?" ]]; then
    segments+=("${C_GREY}[?]${C_RESET}")
  else
    segments+=("${tag_color}[${label}]${C_RESET}")
  fi

  # Widget 2: model (dim).
  local model
  model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"')
  segments+=("${C_DIM}${model}${C_RESET}")

  # Widget 3: context used percentage.
  local ctx_pct
  ctx_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
  if [[ -n "$ctx_pct" && "$ctx_pct" != "null" ]]; then
    local ctx_int=${ctx_pct%.*}
    local ctx_color
    ctx_color=$(color_for_pct "$ctx_int" 50 70)
    segments+=("${ctx_color}ctx ${ctx_int}%${C_RESET}")
  fi

  # Widget 4: 5h window with countdown.
  if [[ -n "$five_h_used" ]]; then
    local five_h_int=${five_h_used%.*}
    local five_h_color
    five_h_color=$(color_for_pct "$five_h_int" 50 90)
    local resets_at
    resets_at=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    if [[ -n "$resets_at" ]]; then
      local now remaining countdown
      now=$(date +%s)
      remaining=$(( resets_at - now ))
      countdown=$(format_duration "$remaining")
      segments+=("${five_h_color}5h ${five_h_int}% (${countdown})${C_RESET}")
    else
      segments+=("${five_h_color}5h ${five_h_int}%${C_RESET}")
    fi
  fi

  # Widget 5: 7d window.
  local seven_d_used
  seven_d_used=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
  if [[ -n "$seven_d_used" ]]; then
    local seven_d_int=${seven_d_used%.*}
    local seven_d_color
    seven_d_color=$(color_for_pct "$seven_d_int" 50 90)
    segments+=("${seven_d_color}7d ${seven_d_int}%${C_RESET}")
  fi

  # Widget 6: git branch (if cwd is a git repo).
  local cwd branch
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
  branch=$(git_branch "$cwd")
  if [[ -n "$branch" ]]; then
    segments+=("${C_DIM}${branch}${C_RESET}")
  fi

  # Join with " · ".
  local sep=$' \xc2\xb7 '  # UTF-8 for " · "
  local out=""
  local i
  for i in "${!segments[@]}"; do
    if (( i == 0 )); then
      out="${segments[i]}"
    else
      out="${out}${sep}${segments[i]}"
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
  input=$(cat)

  if [[ -z "$input" ]]; then
    printf '[claude-statusline: empty input]\n'
    return 0
  fi

  render "$input"
}

main "$@"
