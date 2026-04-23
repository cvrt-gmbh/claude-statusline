# claude-statusline

![license](https://img.shields.io/github/license/cvrt-gmbh/claude-statusline)

> Subscription-aware status line for Claude Code.

Built for Claude Max / Team Max plans where dollar amounts and burn-rate are meaningless.

## Features

- Active account label (map any logged-in email to a short tag)
- Active model display
- Context-window usage with color thresholds
- 5-hour rate-limit usage + countdown to reset
- 7-day rate-limit usage
- Git branch for orientation
- Graceful degradation when fields are missing (never blanks the bar)

## Prerequisites

- macOS or Linux
- bash
- `jq` (`brew install jq`)
- git (optional, only needed for the branch segment)

## Installation

```bash
git clone https://github.com/cvrt-gmbh/claude-statusline
cd claude-statusline
./install.sh
```

Then add the snippet printed by the installer to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "/absolute/path/to/claude-statusline.sh",
  "padding": 0,
  "refreshInterval": 5
}
```

Restart Claude Code.

## Usage

After install, Claude Code renders a line like:

```
[JAY] · Opus · ctx 42% · 5h 67% (2h12m) · 7d 41% · main
```

Each segment:

| Segment | Source | Color thresholds (green / yellow / red) |
|---|---|---|
| `[JAY]` | `~/.claude.json` email mapped via `accounts.toml` | mirrors 5h |
| `Opus` | `.model.display_name` | dim |
| `ctx 42%` | `.context_window.used_percentage` | <50 / 50-69 / >=70 |
| `5h 67% (2h12m)` | `.rate_limits.five_hour` + countdown to `resets_at` | <50 / 50-89 / >=90 |
| `7d 41%` | `.rate_limits.seven_day.used_percentage` | <50 / 50-89 / >=90 |
| `main` | `git symbolic-ref --short HEAD` | dim |

## Configuration

Edit `~/.config/claude-statusline/accounts.toml` to map your Claude account emails to labels:

```toml
[[account]]
email = "you@example.com"
label = "A"

[[account]]
email = "you+work@example.com"
label = "B"
```

The script reads the current account from `~/.claude.json` (`.oauthAccount.emailAddress`) every tick. Logging out and back into a different account flips the label within one refresh (up to 5 seconds). Unmapped emails render as `[?]`.

## Development

```bash
./test/run.sh
```

13 fixture-driven assertions across four input shapes (full, no rate_limits, null context, not-git cwd). Exits 0 on green.

## Graceful degradation

The script never blanks the status bar. When data is missing:

- No `rate_limits` (pre-first-response, or non-Pro/Max account): 5h and 7d segments omitted.
- Null `context_window.used_percentage`: ctx segment omitted.
- No `accounts.toml` or email not mapped: account tag shows `[?]`.
- `cwd` not a git repo: branch segment omitted.
- `jq` missing: prints a one-line warning and exits 0.

## License

MIT. See [LICENSE](LICENSE).
