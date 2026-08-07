#!/usr/bin/env bash
#
# doctor.sh — is the Ghostwire on this machine the one you think it is?
#
# The hook and the server share a protocol with no version handshake, and
# launching any build re-installs its bundled hook over ~/.claude, ~/.codex,
# ~/.cursor and friends. So the *last build launched* owns the hook while a
# *different* build may still hold the socket. That skew is invisible, degrades
# every agent on the machine, and is what GW-408 was originally reported as.
#
# It is also what nearly produced a false pass on the GW-413 smoke test:
# a new hook talking to a server built 90 minutes earlier.
#
# Run this before debugging any approval behaviour, and before believing any
# manual test. Exits non-zero if something is out of sync.
#
# Usage: ./doctor.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SOCKET=/tmp/com.ghostwire.notch.sock
REPO_HOOK=Ghostwire/Ghostwire/Resources/ghostwire-hook.py
PROBLEMS=0

bold=$'\033[1m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; dim=$'\033[2m'; off=$'\033[0m'
ok()   { printf "  ${grn}ok${off}    %s\n" "$1"; }
warn() { printf "  ${ylw}warn${off}  %s\n" "$1"; PROBLEMS=$((PROBLEMS+1)); }
bad()  { printf "  ${red}BAD${off}   %s\n" "$1"; PROBLEMS=$((PROBLEMS+1)); }
note() { printf "        ${dim}%s${off}\n" "$1"; }

printf "\n${bold}Ghostwire doctor${off}  ${dim}%s${off}\n" "$(date '+%H:%M:%S')"

# ── repo ────────────────────────────────────────────────────────────────────
printf "\n${bold}repo${off}\n"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
HEAD_SHA=$(git rev-parse --short HEAD 2>/dev/null)
HEAD_EPOCH=$(git log -1 --format=%ct 2>/dev/null)
ok "$BRANCH @ $HEAD_SHA — $(git log -1 --format=%s 2>/dev/null | cut -c1-58)"
DIRTY=$(git status --porcelain 2>/dev/null | grep -v 'Package.resolved' | wc -l | tr -d ' ')
[ "$DIRTY" != "0" ] && note "$DIRTY uncommitted file(s) — a build may not match this commit"

# ── which build is running ──────────────────────────────────────────────────
printf "\n${bold}running app${off}\n"
PID=$(lsof -t "$SOCKET" 2>/dev/null | head -1)
if [ -z "${PID:-}" ]; then
  warn "nothing is holding $SOCKET"
  note "Ghostwire is not running, or failed to bind. Agents will fall back to"
  note "their own prompts — correct behaviour (GW-413), but you get no notch."
  RUNNING_APP=""
else
  RUNNING_BIN=$(ps -o comm= -p "$PID" 2>/dev/null)
  RUNNING_APP="${RUNNING_BIN%/Contents/MacOS/Ghostwire}"
  STARTED=$(ps -o lstart= -p "$PID" 2>/dev/null | xargs)
  STARTED_EPOCH=$(date -j -f "%a %b %d %T %Y" "$STARTED" +%s 2>/dev/null || echo 0)
  ok "pid $PID  started $STARTED"
  note "$(echo "$RUNNING_BIN" | sed 's|.*/DerivedData/||')"

  if [ "$STARTED_EPOCH" != "0" ] && [ -n "$HEAD_EPOCH" ] && [ "$STARTED_EPOCH" -lt "$HEAD_EPOCH" ]; then
    bad "running app predates HEAD — it does NOT contain your latest commit"
    note "quit it and rebuild, or any test you run is testing old code"
  fi
fi

# ── which DerivedData the CLI actually builds to ────────────────────────────
printf "\n${bold}build output${off}\n"
BPD=$(xcodebuild -scheme Ghostwire -destination 'platform=macOS' -configuration Debug \
        -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3; exit}')
if [ -z "${BPD:-}" ]; then
  warn "could not resolve BUILT_PRODUCTS_DIR (xcodebuild failed?)"
else
  ok "CLI builds to $(echo "$BPD" | sed 's|.*/DerivedData/||')"
  if [ -n "${RUNNING_APP:-}" ] && [ "$RUNNING_APP" != "$BPD/Ghostwire.app" ]; then
    bad "the running app is NOT what the CLI builds"
    note "running: $(echo "$RUNNING_APP" | sed 's|.*/DerivedData/||')"
    note "This is the trap: 'BUILD SUCCEEDED' then launching a different bundle."
    note "Launch it with:  open \"$BPD/Ghostwire.app\""
  fi
fi
DD_COUNT=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'Ghostwire-*' 2>/dev/null | wc -l | tr -d ' ')
[ "$DD_COUNT" -gt 1 ] && note "$DD_COUNT Ghostwire DerivedData dirs ($(du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null | cut -f1) total) — stale ones are safe to delete"

# ── installed hooks vs repo ─────────────────────────────────────────────────
printf "\n${bold}installed hooks${off}\n"
FOUND=0
for d in .claude .codex .cursor .copilot .factory .qoder .codebuddy; do
  f="$HOME/$d/hooks/ghostwire-hook.py"
  [ -f "$f" ] || continue
  FOUND=$((FOUND+1))
  if diff -q "$f" "$REPO_HOOK" >/dev/null 2>&1; then
    ok "~/$d"
  else
    bad "~/$d differs from the repo copy"
    note "$(diff "$f" "$REPO_HOOK" | grep -c '^[<>]') differing lines — launch a current build to reinstall"
  fi
done
[ "$FOUND" = "0" ] && warn "no ghostwire hooks installed anywhere — launch the app once"

# ── the invariant this repo exists to protect ───────────────────────────────
printf "\n${bold}fail-open contract${off} ${dim}(GW-413)${off}\n"
if grep -q "fail_closed_message" "$REPO_HOOK" 2>/dev/null; then
  bad "the hook still has fail_closed_message — a non-human deny path is back"
else
  ok "hook has no non-human deny path"
fi
if grep -q "func sendImmediateDeny" Ghostwire/Ghostwire/Services/Hooks/HookSocketServer.swift 2>/dev/null; then
  bad "sendImmediateDeny is back in the server — it lets Ghostwire deny without a click"
else
  ok "server has no immediate-deny helper"
fi

# ── verdict ─────────────────────────────────────────────────────────────────
printf "\n"
if [ "$PROBLEMS" = "0" ]; then
  printf "  ${grn}${bold}healthy${off} — the running app, the installed hooks and this checkout agree\n\n"
  exit 0
fi
printf "  ${ylw}${bold}%d thing(s) to look at${off} — fix before trusting a manual test\n\n" "$PROBLEMS"
exit 1
