#!/usr/bin/env bash
# claude-statusline: subscription-aware custom status line for Claude Code.
# Reads one JSON object from stdin, writes one line to stdout. Never exits non-zero.

set -uo pipefail

# Always exit 0 so Claude Code doesn't blank the bar.
trap 'exit 0' ERR

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

render() {
  local input=$1
  # Implemented in later tasks. For now print a minimal fallback so tests can
  # start running against the script.
  local model
  model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"')
  printf '%s\n' "$model"
}

main "$@"
