#!/usr/bin/env bash
# install.sh - one-time setup for claude-statusline.
# - Seeds ~/.config/claude-statusline/accounts.toml from the example if missing.
# - Prints the settings.json snippet to add to ~/.claude/settings.json.
# Safe to re-run.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline"
config_file="$config_dir/accounts.toml"

mkdir -p "$config_dir"

if [[ -f "$config_file" ]]; then
  echo "Config already exists at $config_file (not overwriting)."
else
  cp "$script_dir/accounts.example.toml" "$config_file"
  echo "Seeded $config_file from example. Edit it to map your account emails."
fi

if ! command -v jq >/dev/null 2>&1; then
  echo
  echo "WARNING: 'jq' is not installed. claude-statusline requires jq."
  echo "  Install with: brew install jq"
fi

chmod +x "$script_dir/claude-statusline.sh"
chmod +x "$script_dir/test/run.sh"

cat <<EOF

Next step: add the following to ~/.claude/settings.json under the top-level object:

  "statusLine": {
    "type": "command",
    "command": "$script_dir/claude-statusline.sh",
    "padding": 0,
    "refreshInterval": 5
  }

Then restart any running Claude Code sessions.

Test the script directly:

  $script_dir/claude-statusline.sh < $script_dir/test/fixtures/full.json

Run the tests:

  cd $script_dir && ./test/run.sh

Lint (optional, requires shellcheck):

  cd $script_dir && shellcheck --shell=bash claude-statusline.sh install.sh test/run.sh
EOF
