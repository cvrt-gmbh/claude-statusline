#!/usr/bin/env bash
# Tests for claude-acct and the status line's switch links.
# Usage: ./test/acct.sh
#
# `security` and `tmux` are replaced by file-backed stubs on PATH, so the real
# keychain and real tmux sessions are never touched and this runs on Linux CI.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$script_dir")"
acct="$repo_dir/claude-acct"
statusline="$repo_dir/claude-statusline.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export HOME="$work/home"
export XDG_CONFIG_HOME="$work/config"
export XDG_CACHE_HOME="$work/cache"
export CLAUDE_ACCT_ACTIVE_SVC="Claude Code-credentials"
export CLAUDE_ACCT_SLOT_SVC="claude-statusline-account"
export CLAUDE_ACCT_NOTIFY=0
export CLAUDE_ACCT_NUDGE_DELAY=0
export STUB_KC="$work/kc" STUB_TMUX="$work/tmux"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/claude-statusline" "$STUB_KC" "$STUB_TMUX" "$work/bin"

# ============ stubs ============

cat >"$work/bin/security" <<'STUB'
#!/usr/bin/env bash
# Keychain stub: one file per item, $STUB_KC/<svc>__<acct>.
key() { printf '%s__%s' "$1" "$2" | tr ' /' '__'; }
run() {
  local cmd=$1; shift
  local a="" s="" w="" x="" want_pw=0
  while (( $# )); do
    case "$1" in
      -a) a=$2; shift ;; -s) s=$2; shift ;; -X) x=$2; shift ;;
      -w) if [[ $# -gt 1 && $2 != -* ]]; then w=$2; shift; else want_pw=1; fi ;;
    esac
    shift
  done
  case "$cmd" in
    find-generic-password)
      local f
      if [[ -n "$a" ]]; then f="$STUB_KC/$(key "$s" "$a")"
      else f=$(ls "$STUB_KC/$(key "$s" "")"* 2>/dev/null | head -1); fi
      [[ -f "$f" ]] || return 44
      if (( want_pw )); then cat "$f"; echo
      else printf 'keychain: "stub"\nattributes:\n    "acct"<blob>="%s"\n' "$(basename "$f" | sed 's/.*__//')"; fi ;;
    add-generic-password)
      [[ -n "$x" ]] && w=$(printf '%s' "$x" | xxd -r -p 2>/dev/null || printf '%s' "$x" | perl -pe 's/(..)/chr(hex($1))/ge')
      printf '%s' "$w" >"$STUB_KC/$(key "$s" "$a")"
      [[ -n "$x" ]] && echo stdin >>"$STUB_KC/.writes" || echo argv >>"$STUB_KC/.writes" ;;
    delete-generic-password) rm -f "$STUB_KC/$(key "$s" "$a")" ;;
  esac
}
if [[ "$1" == -i ]]; then
  while IFS= read -r line; do eval "run $line"; done
else
  run "$@"
fi
STUB

cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# tmux stub: $STUB_TMUX/panes lists "<id> <cmd>", $STUB_TMUX/<id>.screen holds
# each pane's screen, send-keys calls are appended to $STUB_TMUX/sent.
case "$1" in
  list-panes) cat "$STUB_TMUX/panes" ;;
  capture-pane) shift; while (( $# )); do [[ "$1" == -t ]] && id=$2; shift; done; cat "$STUB_TMUX/$id.screen" ;;
  send-keys) shift; echo "$*" >>"$STUB_TMUX/sent" ;;
  show) echo "" ;;
esac
STUB
chmod +x "$work/bin/security" "$work/bin/tmux"
export PATH="$work/bin:$PATH"

# ============ helpers ============

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; echo "        got: $2"; }

kc() { cat "$STUB_KC/$(printf '%s__%s' "$1" "$2" | tr ' /' '__')" 2>/dev/null; }
set_kc() { printf '%s' "$3" >"$STUB_KC/$(printf '%s__%s' "$1" "$2" | tr ' /' '__')"; }
cred() { printf '{"claudeAiOauth":{"accessToken":"at-%s","refreshToken":"rt-%s","expiresAt":1}}' "$1" "$1"; }
login_as() {
  # Simulates `/login`: active credential + oauthAccount, other keys untouched.
  set_kc "$CLAUDE_ACCT_ACTIVE_SVC" jh "$(cred "$2")"
  local base='{}'
  [[ -f "$HOME/.claude.json" ]] && base=$(cat "$HOME/.claude.json")
  jq --arg e "$1" '.oauthAccount = {emailAddress: $e, organizationName: "Org"}' <<<"$base" >"$HOME/.claude.json"
}

cat >"$XDG_CONFIG_HOME/claude-statusline/accounts.toml" <<'TOML'
[[account]]
email = "jay@example.com"
label = "JAY"

[[account]]
email = "info@example.com"
label = "INFO"
TOML
printf '{"numStartups": 7, "projects": {"x": 1}}' >"$HOME/.claude.json"
chmod 640 "$HOME/.claude.json"

# ============ save ============
echo "save ..."
login_as info@example.com info1
out=$("$acct" save 2>&1)
if [[ "$out" == "saved INFO (info@example.com)" ]]; then ok "save uses the label mapped to the logged-in email"; else bad "save uses the label mapped to the logged-in email" "$out"; fi
if [[ "$(kc "$CLAUDE_ACCT_SLOT_SVC" INFO)" == "$(cred info1)" ]]; then ok "save stores the credential in its slot"; else bad "save stores the credential in its slot" ""; fi
if [[ "$(jq -r .emailAddress "$XDG_CONFIG_HOME/claude-statusline/profiles/INFO.json")" == info@example.com ]] && ! grep -q rt- "$XDG_CONFIG_HOME/claude-statusline/profiles/INFO.json"; then ok "save writes the profile without secrets"; else bad "save writes the profile without secrets" ""; fi
f="$XDG_CONFIG_HOME/claude-statusline/profiles/INFO.json"
if [[ "$(uname)" == Darwin ]]; then mode=$(stat -f '%Lp' "$f"); else mode=$(stat -c '%a' "$f"); fi
if [[ "$mode" == 600 ]]; then ok "profile is private (600)"; else bad "profile is private (600)" "$mode"; fi
if [[ "$(sort -u "$STUB_KC/.writes")" == stdin ]]; then ok "short credentials are written via stdin, never argv"; else bad "short credentials are written via stdin, never argv" "$(sort -u "$STUB_KC/.writes")"; fi

login_as jay@example.com jay1
"$acct" save >/dev/null 2>&1

set_kc "$CLAUDE_ACCT_ACTIVE_SVC" jh '{"claudeAiOauth":{"accessToken":"x"}}'
out=$("$acct" save 2>&1); rc=$?
if (( rc == 1 )) && [[ "$out" == *"no refresh token"* ]]; then ok "save refuses a credential without refresh token"; else bad "save refuses a credential without refresh token" "$out"; fi
set_kc "$CLAUDE_ACCT_ACTIVE_SVC" jh "$(cred jay1)"

# ============ use ============
echo "use ..."
# The running sessions rotated JAY's token since it was saved.
set_kc "$CLAUDE_ACCT_ACTIVE_SVC" jh "$(cred jay2)"
out=$("$acct" use INFO 2>&1); rc=$?
if (( rc == 0 )); then ok "use exits 0"; else bad "use exits 0" "$out"; fi
if [[ "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" == "$(cred info1)" ]]; then ok "use makes INFO's credential the active one"; else bad "use makes INFO's credential the active one" ""; fi
if [[ "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" == info@example.com ]]; then ok "use switches oauthAccount in ~/.claude.json"; else bad "use switches oauthAccount in ~/.claude.json" ""; fi
if [[ "$(jq -c "{numStartups, projects}" "$HOME/.claude.json")" == "{\"numStartups\":7,\"projects\":{\"x\":1}}" ]]; then ok "use keeps every other key of ~/.claude.json"; else bad "use keeps every other key of ~/.claude.json" ""; fi
if [[ "$(uname)" == Darwin ]]; then cmode=$(stat -f '%Lp' "$HOME/.claude.json"); else cmode=$(stat -c '%a' "$HOME/.claude.json"); fi
if [[ "$cmode" == 640 ]]; then ok "use keeps the mode of ~/.claude.json"; else bad "use keeps the mode of ~/.claude.json" "$cmode"; fi
if [[ "$(kc "$CLAUDE_ACCT_SLOT_SVC" JAY)" == "$(cred jay2)" ]]; then ok "use banks the rotated credential of the account it leaves"; else bad "use banks the rotated credential of the account it leaves" "$(kc "$CLAUDE_ACCT_SLOT_SVC" JAY)"; fi
if [[ ! -d "$XDG_CACHE_HOME/claude-statusline/claude-acct.lock" ]]; then ok "use releases its lock"; else bad "use releases its lock" ""; fi

"$acct" use JAY >/dev/null 2>&1
if [[ "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" == "$(cred jay2)" ]]; then ok "switching back restores the banked credential"; else bad "switching back restores the banked credential" ""; fi

before=$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)
out=$("$acct" use DEV 2>&1); rc=$?
if (( rc == 1 )) && [[ "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" == "$before" ]] && [[ "$out" == *"not saved"* ]]; then ok "use of an unsaved label fails and changes nothing"; else bad "use of an unsaved label fails and changes nothing" "$out"; fi

mkdir "$XDG_CACHE_HOME/claude-statusline/claude-acct.lock"
out=$("$acct" use INFO 2>&1); rc=$?
if (( rc == 1 )) && [[ "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" == "$before" ]]; then ok "a held lock blocks a concurrent switch"; else bad "a held lock blocks a concurrent switch" "$out"; fi
rmdir "$XDG_CACHE_HOME/claude-statusline/claude-acct.lock"

# Long credentials take the argv path and still round-trip.
long=$(printf '{"claudeAiOauth":{"refreshToken":"%s"}}' "$(printf 'r%.0s' $(seq 1 2100))")
login_as info@example.com x
set_kc "$CLAUDE_ACCT_ACTIVE_SVC" jh "$long"
"$acct" save >/dev/null 2>&1
if [[ "$(kc "$CLAUDE_ACCT_SLOT_SVC" INFO)" == "$long" ]]; then ok "credentials over the stdin limit round-trip via argv"; else bad "credentials over the stdin limit round-trip via argv" ""; fi
"$acct" use JAY --no-nudge >/dev/null 2>&1

# ============ handle-url ============
echo "handle-url ..."
"$acct" handle-url "claude-acct://use/INFO" >/dev/null 2>&1
if [[ "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" == info@example.com ]]; then ok "a claude-acct://use/LABEL link switches"; else bad "a claude-acct://use/LABEL link switches" ""; fi
for url in 'claude-acct://use/JAY;touch%20x' 'claude-acct://use/../JAY' 'https://evil.example/use/JAY' 'claude-acct://rm/JAY'; do
  "$acct" handle-url "$url" >/dev/null 2>&1; rc=$?
  if (( rc == 1 )) && [[ "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" == info@example.com ]]; then ok "rejects link $url"; else bad "rejects link $url" ""; fi
done

# ============ nudge ============
echo "nudge ..."
sep='────────────────────────────────────────'
screen() { # screen ID PROMPT LINE...
  local id=$1 prompt=$2; shift 2
  { printf '%s\n' "$@"; echo; echo "$sep"; echo "❯ $prompt"; echo "$sep"; echo "  [INFO] · Opus"; } >"$STUB_TMUX/$id.screen"
}
screen %1 "" "⏺ Working on it" "  ⎿  Not logged in · Please run /login" "✻ Cogitated for 3m · done 1:10 PM"
screen %2 "" "⏺ Agent \"x\" failed: Agent terminated early due to an API error: You've hit your session limit"
screen %3 "" "  ⎿  You've hit your session limit · resets 3:40pm" "⏺ Usage limit reached · continuing automatically at 3:40pm · esc to cancel"
screen %4 "half typed draft" "  ⎿  Not logged in · Please run /login"
screen %5 "" "  ⎿  Not logged in · Please run /login" "⏺ Fixed it. Here is the summary." "  - one" "  - two" "  - three"
screen %6 "" "I quoted the error: ⎿  Not logged in · Please run /login" "Shall I continue?"
screen %7 "" "  ⎿  Not logged in · Please run /login"
printf '%s\n' "%1 2.1.296" "%2 claude" "%3 2.1.295" "%4 2.1.296" "%5 2.1.296" "%6 2.1.296" "%7 zsh" >"$STUB_TMUX/panes"
rm -f "$STUB_TMUX/sent"
dry=$("$acct" nudge --dry-run 2>&1)
if [[ "$dry" == *"would continue %1"* && ! -f "$STUB_TMUX/sent" ]]; then ok "dry run reports without typing"; else bad "dry run reports without typing" "$dry"; fi
"$acct" nudge >/dev/null 2>&1
sent=$(cat "$STUB_TMUX/sent" 2>/dev/null)
if [[ "$sent" == *"-t %1 -l continue"* ]]; then ok "nudges a session whose last output is a login error"; else bad "nudges a session whose last output is a login error" "$sent"; fi
if [[ "$sent" == *"-t %2 -l continue"* ]]; then ok "nudges a session whose agent died on an API error"; else bad "nudges a session whose agent died on an API error" "$sent"; fi
if [[ "$sent" == *"-t %1 Enter"* ]]; then ok "presses Enter after typing"; else bad "presses Enter after typing" "$sent"; fi
if [[ "$sent" != *"%3"* ]]; then ok "leaves a session that continues automatically alone"; else bad "leaves a session that continues automatically alone" "$sent"; fi
if [[ "$sent" != *"%4"* ]]; then ok "never types over a draft"; else bad "never types over a draft" "$sent"; fi
if [[ "$sent" != *"%5"* ]]; then ok "ignores an old error when the session moved on"; else bad "ignores an old error when the session moved on" "$sent"; fi
if [[ "$sent" != *"%6"* ]]; then ok "ignores error text quoted inside a message"; else bad "ignores error text quoted inside a message" "$sent"; fi
if [[ "$sent" != *"%7"* ]]; then ok "ignores panes that are not Claude Code"; else bad "ignores panes that are not Claude Code" "$sent"; fi

rm -f "$STUB_TMUX/sent"
"$acct" use JAY >/dev/null 2>&1
if [[ "$(cat "$STUB_TMUX/sent" 2>/dev/null)" == *"-t %1 -l continue"* ]]; then ok "use nudges stopped sessions after switching"; else bad "use nudges stopped sessions after switching" ""; fi

# ============ status line links ============
echo "status line switch links ..."
printf '4|%s|18|%s\n' "$(( $(date +%s) + 3600 ))" "$(( $(date +%s) + 9000 ))" >"$XDG_CACHE_HOME/claude-statusline/usage-info@example.com"
raw=$(printf '{"model":{"display_name":"Opus"}}' | "$statusline" 2>/dev/null)
link=$'\033]8;;claude-acct://use/INFO\aINFO 4%\033]8;;\a'
if [[ "$raw" == *"$link"* ]]; then ok "renders a clickable link to the other saved account with its usage"; else bad "renders a clickable link to the other saved account with its usage" "$(printf '%s' "$raw" | cat -v)"; fi
if [[ "$raw" != *"claude-acct://use/JAY"* ]]; then ok "does not link the active account"; else bad "does not link the active account" "$(printf '%s' "$raw" | cat -v)"; fi
printf '{"bogus": true}' >"$XDG_CONFIG_HOME/claude-statusline/profiles/bad;rm.json"
raw=$(printf '{"model":{"display_name":"Opus"}}' | "$statusline" 2>/dev/null)
if [[ "$raw" != *"bad;rm"* ]]; then ok "skips profile files with unsafe labels"; else bad "skips profile files with unsafe labels" "$(printf '%s' "$raw" | cat -v)"; fi

echo
echo "Passed: $pass  Failed: $fail"
exit $(( fail > 0 ? 1 : 0 ))
