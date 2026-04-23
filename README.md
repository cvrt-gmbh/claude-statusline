# claude-statusline

Subscription-aware status line for [Claude Code](https://code.claude.com).

Shows, in a single line:

- `[A]` active account (from your mapping in `accounts.toml`)
- `Opus` active model
- `ctx 42%` context-window usage
- `5h 67% (2h12m)` 5-hour rate-limit usage + time to reset
- `7d 41%` 7-day rate-limit usage
- `main` git branch

No dollar amounts, no burn rate - this is built for Claude Max / Team Max subscription plans where those numbers are meaningless.

## Install

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

## Requirements

- macOS or Linux
- bash
- `jq` (`brew install jq`)
- git (optional, only for the branch segment)

## Configuration

Edit `~/.config/claude-statusline/accounts.toml`:

```toml
[[account]]
email = "you@example.com"
label = "A"

[[account]]
email = "you+work@example.com"
label = "B"

[[account]]
email = "you+third@example.com"
label = "C"
```

The script reads the current account from `~/.claude.json` (`.oauthAccount.emailAddress`) and shows the matching label. Unmapped emails show `[?]`.

## Color thresholds

| Widget | Green | Yellow | Red |
|---|---|---|---|
| ctx | <50% | 50-69% | >=70% |
| 5h | <50% | 50-89% | >=90% |
| 7d | <50% | 50-89% | >=90% |
| account tag | mirrors 5h | mirrors 5h | mirrors 5h |

## Testing

```bash
./test/run.sh
```

## Graceful degradation

The script never blanks the status bar. When data is missing:

- No `rate_limits` (pre-first-response, or non-Pro/Max account): 5h and 7d segments are omitted.
- Null `context_window.used_percentage`: ctx segment omitted.
- No `accounts.toml` or email not mapped: account tag shows `[?]`.
- `cwd` not a git repo: branch segment omitted.
- `jq` missing: prints a one-line warning and exits 0.

## License

MIT. See `LICENSE`.
