# claude-statusline

Subscription-aware status line for [Claude Code](https://code.claude.com).

Shows: active account, model, context usage, 5h/7d rate-limit usage, git branch.

## Install

```bash
git clone https://github.com/cvrt-gmbh/claude-statusline ~/Git/cvrt-gmbh/cmd/claude-statusline
cd ~/Git/cvrt-gmbh/cmd/claude-statusline
./install.sh
```

## Config

Edit `~/.config/claude-statusline/accounts.toml` to map your Claude account emails to labels.

## Test

```bash
./test/run.sh
```
