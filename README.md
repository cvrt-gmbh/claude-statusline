# claude-statusline

![CI](https://github.com/cvrt-gmbh/claude-statusline/actions/workflows/ci.yml/badge.svg)
![license](https://img.shields.io/github/license/cvrt-gmbh/claude-statusline)

> Subscription-aware status line for Claude Code.

Built for Claude Max / Team Max plans where dollar amounts and burn-rate are meaningless.

## Features

- Active account label (map any logged-in email to a short tag)
- Active model display
- Context-window usage with color thresholds
- 5-hour rate-limit usage + countdown to reset
- 7-day rate-limit usage
- Usage shared across all open sessions of the same account, so idle tabs never show stale 5h/7d numbers
- Account table once accounts are saved with `claude-acct`: one aligned line per account with its 5h and 7d usage. `→` marks the active account, `⇄` the least used one worth switching to. Cmd+click a name to move every open session to that account at once (macOS):

  ```
  ⇄ DEV   5h   -           7d   -
    INFO  5h 100% (25m)    7d  49%
  → JAY   5h  92% (2h 55m) 7d   8%
  ```
- Git branch for orientation
- Graceful degradation when fields are missing (never blanks the bar)

## Prerequisites

- macOS or Linux
- bash 3.2 or newer (works with the bash that ships on macOS)
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
[JAY] · Opus · ctx 42% · 5h 67% (2h 12m) · 7d 41% · main
```

Each segment:

| Segment | Source | Color thresholds (green / yellow / red) |
|---|---|---|
| `[JAY]` | `~/.claude.json` email mapped via `accounts.toml` | mirrors 5h |
| `Opus` | `.model.display_name` | dim |
| `ctx 42%` | `.context_window.used_percentage` | <50 / 50-69 / >=70 |
| `5h 67% (2h 12m)` | `.rate_limits.five_hour` + countdown to `resets_at` | <50 / 50-89 / >=90 |
| `7d 41%` | `.rate_limits.seven_day.used_percentage` | <50 / 50-89 / >=90 |
| `main` | `git symbolic-ref --short HEAD`, or `@abc1234` when detached | dim |

Percentages arrive as floats (e.g. `89.7`) and are rounded half-up, so a value
sitting on a threshold escalates rather than under-reporting: `89.7` renders as
`90%` in red, not `89%` in yellow.

The 5h countdown is omitted when the reset time has already passed, rather than
showing `(0m)`.

### Shared usage across sessions

Claude Code sends each session's `rate_limits` as of that session's last API
response, so an idle tab keeps showing old numbers, and after an account switch
it shows the previous account's numbers until it makes a request. To fix this,
every session publishes new readings to a per-account cache
(`~/.cache/claude-statusline/usage-<email>`), and every tab renders the newest
reading for the account that is currently logged in.

- A reading is newer if its window resets later, or, within the same window, if
  its percentage is higher.
- A session publishes only numbers that changed after it was first seen. A tab
  that was already open across an account switch still carries the old
  account's numbers unchanged, so they never leak into the new account's cache.
- Once a cached window's reset time has passed, it renders as 0% with no
  countdown, never as a tab's own stale snapshot.

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

## Account switching (macOS)

`claude-acct` switches the Claude Code login for every open session at once.
Running sessions re-read the login from the macOS Keychain, so replacing the
active credential is enough. Unlike `/logout` + `/login` there is no window
without a login, which otherwise kills in-flight requests and subagents with
`Not logged in · Please run /login`.

```bash
ln -s "$PWD/claude-acct" ~/.local/bin/claude-acct
claude-acct save            # save the account that is logged in now
claude-acct login           # log in to another account and save it; open sessions stay put
claude-acct install-handler # builds ~/Applications/ClaudeAcct.app for claude-acct:// links
claude-acct use INFO        # switch every session to INFO
claude-acct list            # saved accounts and their last known usage
claude-acct doctor          # checks the setup, never prints secrets
```

Once two or more accounts are saved, the status line shows the other ones after
the account tag, colored by their last known 5h usage. Cmd+click one to switch.
A `+ login` link at the end of the line opens `claude-acct login` in a new tmux
window (or a new Ghostty window without tmux).

`claude-acct login` runs `claude auth login` with a temporary
`CLAUDE_CONFIG_DIR`, which gets its own credential store, so the open sessions
keep their account during the login. It saves the new account (asking for a
label if its email is not in `accounts.toml` yet), deletes the temporary login,
and offers to switch. If the login ever lands in the live credential store
instead, it stops and says so, and never deletes that credential.
For the links to be clickable:

- the terminal must support OSC 8 links (Ghostty, iTerm2, Kitty, WezTerm),
- inside tmux: `set -as terminal-features ',xterm-ghostty:hyperlinks'`,
- Claude Code only detects link support in a few terminals, so export
  `FORCE_HYPERLINK=1` before starting it (needed inside tmux).

How a switch works:

1. The live credential of the account you leave goes back into its own keychain
   item (`claude-statusline-account`, one per label). Sessions rotate the
   refresh token while they run, so the copy from `save` goes stale. Always switch
   with `claude-acct`; after a manual `/login`, run `claude-acct save` again.
2. The target credential becomes the active `Claude Code-credentials` item, and
   `.oauthAccount` in `~/.claude.json` is replaced (all other keys are kept).
3. After a few seconds, tmux panes that stopped on a limit or login error get
   `continue`. A pane only counts when one of Claude Code's own errors is in its
   last lines, its prompt is empty, and it is not already waiting to continue
   automatically. `claude-acct nudge --dry-run` shows which panes would get it.

Credentials up to 2000 characters are written through `security -i` on stdin,
so they never show up in the process list. Profiles in
`~/.config/claude-statusline/profiles/` hold only the non-secret account details
(mode 600). Any page can open a `claude-acct://` link; the worst it can do is
switch between your saved accounts. Labels are restricted to letters, digits,
`-` and `_`.

## Development

```bash
./test/run.sh && ./test/acct.sh                                  # tests
shellcheck --shell=bash claude-statusline.sh claude-acct install.sh test/*.sh   # lint
```

Fixture-driven assertions covering the full payload, missing `rate_limits`, null
context, a non-git cwd, an already-elapsed reset, color thresholds, malformed
JSON, and an empty object -- plus colors, exit codes, stderr cleanliness,
detached `HEAD`, and account-label mapping. Exits 0 on green.

`test/acct.sh` covers `claude-acct` against file-backed stubs of `security`
and `tmux`, so it never touches the real keychain or real sessions and runs on
Linux CI too.

Fixtures may contain `__RESET_FUTURE__`, `__RESET_FUTURE_7D__`, and `__CWD__`
placeholders, substituted at run time. Reset timestamps must stay computed rather
than hardcoded -- a fixed far-future epoch once let the countdown render
`615298h 15m` while every substring assertion still passed.

CI runs lint and tests on Linux and macOS. Both matter: macOS ships bash 3.2, and
a bash 4+ builtin once broke every macOS user while Linux stayed green. Avoid
`mapfile`, `readarray`, `declare -A`, and `${var,,}`.

## Graceful degradation

The script never blanks the status bar. When data is missing:

- No `rate_limits` (pre-first-response, or non-Pro/Max account): 5h and 7d segments omitted.
- Null `context_window.used_percentage`: ctx segment omitted.
- No `accounts.toml` or email not mapped: account tag shows `[?]`.
- `cwd` not a git repo: branch segment omitted.
- `jq` missing: prints a one-line warning and exits 0.
- Malformed JSON: renders `[claude-statusline: bad input]`, no stderr noise.
- 5h reset already elapsed, or a non-numeric `resets_at`: countdown omitted, percentage still shown.
- Detached `HEAD`: branch segment shows the short SHA (`@abc1234`).
- `git` not installed: branch segment omitted.
- Cache directory not writable: each tab shows its own payload, as before.

## License

MIT. See [LICENSE](LICENSE).
