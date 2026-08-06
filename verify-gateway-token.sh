#!/usr/bin/env bash
#
# verify-gateway-token.sh — GW-308 live check for the MCP gateway bearer token.
#
# Proves the token is file-backed and STABLE: the gateway accepts the token from
# Application Support, rejects others, and does not rotate across a relaunch.
#
# Usage:
#   ./verify-gateway-token.sh                 # probe the already-running gateway
#   ./verify-gateway-token.sh /path/Ghostwire.app   # also relaunch it and re-check stability
#
# No secrets are hardcoded; the token is read from the live file at runtime.

set -u

TOKEN_FILE="$HOME/Library/Application Support/Ghostwire/MCP/gateway-token"
PORT="${GHOSTWIRE_GATEWAY_PORT:-51762}"   # matches GatewayHTTPListener.Configuration's default
ENDPOINT="http://127.0.0.1:${PORT}/mcp"
APP="${1:-}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gw308-verify","version":"1"}}}'

fail() { echo "❌ $1"; exit 1; }

probe() { # $1 = bearer token -> echoes HTTP status code
  curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$INIT"
}

wait_for_gateway() {
  for _ in $(seq 1 20); do
    lsof -nP -iTCP:${PORT} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

[ -f "$TOKEN_FILE" ] || fail "no token file at $TOKEN_FILE (launch Ghostwire first)"

# Perms are the only protection left once the token is out of Keychain, so a
# mismatch is a hard failure, not a warning.
TOKEN_DIR=$(dirname "$TOKEN_FILE")
perms=$(stat -f "%Lp" "$TOKEN_FILE")
[ "$perms" = "600" ] && echo "✅ token file perms 0600" || fail "token file perms $perms (expected 600)"
dperms=$(stat -f "%Lp" "$TOKEN_DIR")
[ "$dperms" = "700" ] && echo "✅ token dir perms 0700" || fail "token dir perms $dperms (expected 700)"

# A stray atomic-write temp file would be a second, unmanaged copy of the token.
strays=$(find "$TOKEN_DIR" -maxdepth 1 -name '.gateway-token.*' 2>/dev/null)
[ -z "$strays" ] && echo "✅ no stray temp token files" || fail "stray temp token file(s): $strays"

wait_for_gateway || fail "gateway not listening on :${PORT}"
TOK=$(cat "$TOKEN_FILE")
echo "token: ${TOK:0:8}…  (len ${#TOK})"

[ "$(probe "$TOK")" = "200" ]        && echo "✅ correct token → 200" || fail "correct token not accepted"
[ "$(probe "WRONG-$TOK")" = "401" ]  && echo "✅ wrong token   → 401" || fail "wrong token not rejected"

if [ -n "$APP" ]; then
  echo "--- relaunch stability check ($APP) ---"
  BEFORE="$TOK"
  pkill -9 -f "Ghostwire.app/Contents/MacOS/Ghostwire"; sleep 1
  open -n "$APP"
  wait_for_gateway || fail "gateway did not come back up after relaunch"
  AFTER=$(cat "$TOKEN_FILE")
  [ "$BEFORE" = "$AFTER" ] && echo "✅ token unchanged across relaunch" || fail "token ROTATED across relaunch"
  [ "$(probe "$AFTER")" = "200" ] && echo "✅ same token still accepted post-relaunch" || fail "token not accepted post-relaunch"
fi

echo "✅ GW-308 gateway token verification passed"
