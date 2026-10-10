# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `claude-acct`: switch the Claude Code login of every open session at once
  (`save`, `use`, `list`, `nudge`, `doctor`), without the logout gap that kills
  in-flight requests. Banks the rotated credential of the account it leaves,
  then sends `continue` to tmux panes that stopped on a limit or login error.
- Clickable account switch in the status line: the other saved accounts render
  as OSC 8 `claude-acct://use/LABEL` links with their last known 5h usage,
  handled by `~/Applications/ClaudeAcct.app` (`claude-acct install-handler`).
- `claude-acct login` and a `+ login` link at the end of the status line: log in
  to another account in an isolated `CLAUDE_CONFIG_DIR` and save it, without
  touching the open sessions.

- 5h and 7d usage are shared across all open sessions of the same account via
  `~/.cache/claude-statusline/usage-<email>`. Previously each tab showed the
  snapshot from its own last API response, so idle tabs showed stale usage and,
  after an account switch, the previous account's usage. Only numbers that
  changed after a session was first seen are published, so the old account's
  snapshot never leaks into the new account's cache. A cached window whose
  reset has passed renders as 0%.

### Fixed

- Countdown rendered absurd durations such as `5h 67% (615298h 15m)`. Test
  fixtures used a hardcoded `resets_at` of `4000000000` (the year 2096), and the
  assertions only checked the `5h 67%` substring, so the broken countdown passed
  CI. Fixtures now compute `resets_at` relative to the current time and the
  countdown format is asserted.
- Percentages are now rounded half-up instead of truncated. `used_percentage` is
  a float in the Claude Code payload (documented examples: `23.5`, `41.2`), and
  `${pct%.*}` truncation reported `89.7` as `89`, rendering yellow when the 90
  threshold should have been red. Truncation systematically under-reported usage
  at exactly the thresholds that matter.
- A window whose `resets_at` has already passed no longer claims `(0m)`. The
  countdown is omitted instead of asserting an imminent reset that already
  happened.
- Fields shifted when an optional field was absent. Parsing used
  `IFS=$'\t' read`, which collapses an empty field and moves every later value
  one slot left; with no `context_window` the 5h percentage was rendered as
  `ctx` and `resets_at` became the 5h percentage (clamped to `100%`). Fields are
  now read one per line, preserving empties.
- The account tag no longer discards its computed color. Previously an unmapped
  account (`[?]`, the default before editing `accounts.toml`) always rendered
  grey, losing the usage signal.
- A non-numeric `resets_at` aborted the render with empty stdout and exit 1,
  blanking the status bar; the `ERR` trap did not prevent a failed arithmetic
  expansion from killing the render mid-way. All arithmetic is now guarded and
  the trap prints a marker.
- Malformed JSON no longer leaks `jq` parse errors to stderr; it renders
  `[claude-statusline: bad input]` and exits 0.
- Detached `HEAD` (rebase, bisect, checked-out tag) no longer drops the branch
  segment. It renders the short SHA as `@abc1234`.
- A literal `label = "?"` in `accounts.toml` is no longer confused with the
  internal "unmapped" sentinel.
- The git segment is skipped when `git` is not on `PATH`, as the README already
  claimed.

### Changed

- Reduced from 7 `jq` subprocesses per render to 1 for parsing (plus 1 for
  reading the account email). The status line refreshes every 5 seconds, so this
  runs continuously.
- Rounding is half-up rather than `printf "%.0f"` banker's rounding, so a value
  sitting on a color threshold escalates instead of rounding down.

### Added

- CI running `shellcheck` and the test suite on both Linux and macOS. macOS
  ships bash 3.2, and a bash 4+ builtin (`mapfile`) had broken every macOS user
  while passing on Linux; both are now exercised.
- Fixtures for elapsed resets, color-threshold floats, malformed JSON, and an
  empty object; plus assertions for colors, exit codes, stderr cleanliness,
  detached `HEAD`, and account-label mapping. 13 assertions -> 42.
- Issue and pull request templates.
