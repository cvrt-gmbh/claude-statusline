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
      printf '%s\t%s\n' "$s" "$a" >>"$STUB_KC/.index"
      [[ -n "$x" ]] && echo stdin >>"$STUB_KC/.writes" || echo argv >>"$STUB_KC/.writes" ;;
    delete-generic-password) rm -f "$STUB_KC/$(key "$s" "$a")" ;;
    dump-keychain)
      sort -u "$STUB_KC/.index" 2>/dev/null | while IFS=$'\t' read -r sv ac; do
        [[ -f "$STUB_KC/$(key "$sv" "$ac")" ]] && printf '    "svce"<blob>="%s"\n' "$sv"
      done ;;
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
  list-sessions) echo "main: 1 windows" ;;
  new-window) shift; printf '%s\n' "$*" >>"$STUB_TMUX/windows" ;;
  show) echo "" ;;
  list-clients) cat "$STUB_TMUX/clients" 2>/dev/null ;;
esac
STUB
cat >"$work/bin/claude" <<'STUB'
#!/usr/bin/env bash
# `claude auth login` stub: writes an isolated credential the way Claude Code
# does for a custom CLAUDE_CONFIG_DIR, or the live one when STUB_LOGIN_LEAK=1.
[[ "$1 $2" == "auth login" ]] || exit 2
[[ "${STUB_LOGIN_FAIL:-0}" == 1 ]] && exit 1
svc="Claude Code-credentials-${STUB_LOGIN_SUFFIX:-1a2b3c4d}"
[[ "${STUB_LOGIN_LEAK:-0}" == 1 ]] && svc="Claude Code-credentials"
printf 'add-generic-password -U -a "jh" -s "%s" -w %s\n' "$svc" \
  "$(printf '{"claudeAiOauth":{"refreshToken":"rt-%s"}}' "$STUB_LOGIN_EMAIL" | sed 's/"/\\"/g; s/^/"/; s/$/"/')" \
  | security -i
printf '{"oauthAccount":{"emailAddress":"%s"}}' "$STUB_LOGIN_EMAIL" >"$CLAUDE_CONFIG_DIR/.claude.json"
STUB
chmod +x "$work/bin/security" "$work/bin/tmux" "$work/bin/claude"
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


# ============ login ============
echo "login ..."
cat >>"$XDG_CONFIG_HOME/claude-statusline/accounts.toml" <<'TOML'

[[account]]
email = "dev@example.com"
label = "DEV"
TOML
active_before=$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)
email_before=$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")
out=$(printf 'n\n' | STUB_LOGIN_EMAIL=dev@example.com "$acct" login 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"saved DEV (dev@example.com)"* ]]; then ok "login saves the new account under its mapped label"; else bad "login saves the new account" "$out"; fi
if [[ "$(kc "$CLAUDE_ACCT_SLOT_SVC" DEV)" == *"rt-dev@example.com"* ]]; then ok "login stores the new credential in the slot"; else bad "login stores the credential" "$(kc "$CLAUDE_ACCT_SLOT_SVC" DEV)"; fi
if [[ "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" == "$active_before" && "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" == "$email_before" ]]; then
  ok "login leaves the open sessions' account untouched"; else bad "login touched the active account" "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")"; fi
if [[ -z "$(kc "Claude Code-credentials-1a2b3c4d" jh)" ]]; then ok "login deletes its temporary credential"; else bad "temporary credential left behind" ""; fi
if ! ls -d "$XDG_CACHE_HOME"/claude-statusline/login.* >/dev/null 2>&1; then ok "login removes its temporary config dir"; else bad "temporary config dir left behind" "$(ls -d "$XDG_CACHE_HOME"/claude-statusline/login.*)"; fi

out=$(printf 'NEWONE\ny\n' | STUB_LOGIN_EMAIL=new@example.com STUB_LOGIN_SUFFIX=99 "$acct" login 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'email = "new@example.com"' "$XDG_CONFIG_HOME/claude-statusline/accounts.toml" && [[ -f "$XDG_CONFIG_HOME/claude-statusline/profiles/NEWONE.json" ]]; then
  ok "login asks for a label for an unmapped email and records it"; else bad "unmapped email login" "$out"; fi
if [[ "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" == new@example.com ]]; then ok "answering y switches every session to the new account"; else bad "y should switch" "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")"; fi
"$acct" use JAY --no-nudge >/dev/null 2>&1

active_before=$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)
out=$(printf 'n\n' | STUB_LOGIN_EMAIL=dev@example.com STUB_LOGIN_FAIL=1 "$acct" login 2>&1); rc=$?
if (( rc == 1 )) && [[ "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" == "$active_before" ]]; then ok "a failed login changes nothing"; else bad "failed login" "$out"; fi

rm -f "$STUB_KC/$(printf '%s__%s' "$CLAUDE_ACCT_ACTIVE_SVC" jh | tr ' /' '__')"
out=$(printf 'n\n' | STUB_LOGIN_EMAIL=dev@example.com STUB_LOGIN_LEAK=1 "$acct" login 2>&1); rc=$?
if (( rc == 1 )) && [[ "$out" == *"isolation failed"* && -n "$(kc "$CLAUDE_ACCT_ACTIVE_SVC" jh)" ]]; then
  ok "a login that lands in the live store is reported and never deleted"; else bad "isolation failure handling" "$out"; fi
set_kc "$CLAUDE_ACCT_ACTIVE_SVC" jh "$active_before"

rm -f "$STUB_TMUX/windows"
"$acct" handle-url "claude-acct://login" >/dev/null 2>&1
if grep -q -- "-n claude-login .*claude-acct' login" "$STUB_TMUX/windows" 2>/dev/null; then ok "a claude-acct://login link opens the login in a new tmux window"; else bad "login link" "$(cat "$STUB_TMUX/windows" 2>/dev/null)"; fi

# ============ status line account table ============
echo "status line account table ..."
plain() { perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;[^\a]*\a//g'; }
cachedir="$XDG_CACHE_HOME/claude-statusline"
in1h=$(( $(date +%s) + 3600 )) in2d=$(( $(date +%s) + 172800 ))
# Every saved account except JAY and INFO is at 80%, so INFO decides the arrow.
for f in "$XDG_CONFIG_HOME/claude-statusline/profiles"/*.json; do
  e=$(jq -r .emailAddress "$f"); [[ "$e" == jay@example.com || "$e" == info@example.com ]] && continue
  printf '80|%s|10|%s\n' "$in1h" "$in2d" >"$cachedir/usage-$e"
done
printf '4|%s|18|%s\n' "$in1h" "$in2d" >"$cachedir/usage-info@example.com"
session() { printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":8,"resets_at":%s}}}' "$1" "$in1h" "$in2d" | "$statusline" 2>/dev/null; }
row() { printf '%s\n' "$1" | grep -a -- "$2"; }
raw=$(session 60); txt=$(printf '%s' "$raw" | plain)
if (( $(printf '%s\n' "$raw" | wc -l) == $(ls "$XDG_CONFIG_HOME/claude-statusline/profiles"/*.json | wc -l) + 1 )); then ok "prints one line per saved account under the model line"; else bad "one line per account" "$txt"; fi
if [[ "$raw" == *$'\033]8;;claude-acct://use/INFO\aINFO\033]8;;\a'* ]]; then ok "links each other account's name to claude-acct://use/LABEL"; else bad "links other accounts" "$(printf '%s' "$raw" | cat -v)"; fi
if [[ "$raw" != *"claude-acct://use/JAY"* && "$(row "$txt" ' JAY ')" == $'\xe2\x86\x92 JAY'*"5h  60%"* ]]; then ok "marks the active account with an arrow, unlinked, with this session's 5h"; else bad "active row" "$txt"; fi
if [[ "$txt" != *"["* ]]; then ok "no brackets around any account name"; else bad "brackets" "$txt"; fi
if ! printf '%s\n' "$txt" | grep -q '^[[:space:]]'; then ok "no line starts with whitespace, which Claude Code would trim"; else bad "leading whitespace" "$txt"; fi
if [[ "$(row "$txt" ' INFO ')" == *"5h   4% ("*"7d  18%"* ]]; then ok "shows another account's cached 5h with countdown and 7d"; else bad "INFO row" "$txt"; fi
cols=$(printf '%s\n' "$txt" | tail -n +2 | perl -CS -ne 'print index($_, " 5h "), " ", index($_, " 7d "), "\n"' | sort -u | wc -l)
if (( cols == 1 )); then ok "aligns the 5h and 7d columns across all rows"; else bad "column alignment" "$txt"; fi
if [[ "$(row "$txt" ' INFO ')" == $'\xe2\x87\x84'* ]] && (( $(printf '%s' "$txt" | grep -c $'\xe2\x87\x84') == 1 )); then ok "marks only the least used account with the switch arrow"; else bad "switch arrow" "$txt"; fi
if (( $(session 2 | grep -c $'\xe2\x87\x84') == 0 )); then ok "no switch arrow when the active account is the least used"; else bad "arrow with active lowest" "$(session 2 | plain)"; fi
printf '4|%s|100|%s\n' "$in1h" "$in2d" >"$cachedir/usage-info@example.com"
if (( $(session 90 | grep -c $'\xe2\x87\x84') == 1 )) && [[ "$(row "$(session 90 | plain)" ' INFO ')" != $'\xe2\x87\x84'* ]]; then ok "never recommends an account whose 7d is used up"; else bad "7d exhausted recommended" "$(session 90 | plain)"; fi
printf '97|%s|18|%s\n' "$(( $(date +%s) - 60 ))" "$in2d" >"$cachedir/usage-info@example.com"
if [[ "$(row "$(session 60 | plain)" ' INFO ')" == *"5h   0% "* ]]; then ok "an elapsed 5h window shows as 0%"; else bad "elapsed window" "$(session 60 | plain)"; fi
rm -f "$cachedir/usage-info@example.com"
if [[ "$(row "$(session 60 | plain)" ' INFO ')" == *"5h    - "*"7d    -"* ]]; then ok "an account never used shows - for both windows"; else bad "unknown usage" "$(session 60 | plain)"; fi
printf '{"bogus": true}' >"$XDG_CONFIG_HOME/claude-statusline/profiles/bad;rm.json"
raw=$(session 60)
if [[ "$raw" != *"bad;rm"* ]]; then ok "skips profile files with unsafe labels"; else bad "skips profile files with unsafe labels" "$(printf '%s' "$raw" | cat -v)"; fi
loginlink=$'\033]8;;claude-acct://login\a+ login\033]8;;\a'
first=$(printf '%s\n' "$raw" | head -1)
if [[ "$first" == *"$loginlink" || "$first" == *"$loginlink"$'\033[0m' ]]; then ok "renders a + login link at the end of the first line"; else bad "+ login link" "$(printf '%s' "$first" | cat -v)"; fi

printf '/dev/ttys000 clipboard,focus,title\n/dev/ttys001 clipboard,hyperlinks,title\n' >"$STUB_TMUX/clients"
doc=$(TMUX=/tmp/stub,1,0 "$acct" doctor 2>&1)
if [[ "$doc" == *"client /dev/ttys000: hyperlinks OFF"* ]]; then ok "doctor flags a tmux client attached without hyperlinks"; else bad "doctor flags a tmux client attached without hyperlinks" "$doc"; fi
if [[ "$doc" == *"client /dev/ttys001: hyperlinks on"* ]]; then ok "doctor reports a tmux client with hyperlinks as on"; else bad "doctor reports a tmux client with hyperlinks as on" "$doc"; fi

echo
echo "Passed: $pass  Failed: $fail"
exit $(( fail > 0 ? 1 : 0 ))
