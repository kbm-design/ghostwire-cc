# GW-448 — Connector catalog: measured end-to-end results

**Measured 2026-08-25** against Keelan's real accounts, from Ghostwire's own code path
(`MCPClientService.connectInteractively` → swift-sdk DCR + loopback OAuth → `tools/list`
→ one `tools/call` through `callAllowedTool`). Read-only, zero-required-input tools only.
Harness: `GhostwireTests/GW448LiveConnectorVerificationTests.swift` (gated on `GW448_LIVE=1`).

**"Connected" only proves `initialize` + `tools/list`. The call is the test.**

## TL;DR

| | Count | Servers |
|---|---|---|
| **Full pass** (connect → real read-only call succeeded) | **7** | Linear, Notion, Canva, Granola, Railway, Resend, Vercel |
| Connected, **call unverifiable** (no zero-input read-only tool exists) | 2 | Cloudflare, PostHog |
| **Broken at DCR** (vendor rejects Ghostwire's registration) | 2 | Calendly, Figma |
| **Blocked by a Ghostwire bug** (reproduced 5×, human on the button) | 1 | Supabase |
| Needs sign-in (flow works to the vendor login; no session in the browser) | 1 | Zapier |

`catalog.json` now carries `verified: true` for exactly the seven full passes; a test pins that set.

## Per-server results

| Server | Endpoint | Result | Tools | Called | Notes |
|---|---|---|---|---|---|
| Linear | `mcp.linear.app/mcp` | ✅ pass | 60 | `list_agent_skills` ok | Prior grant → consent auto-redirected. 10 s. |
| Notion | `mcp.notion.com/mcp` | ✅ pass | 28 | `notion-get-teams` ok | Prior grant. 11 s. |
| Canva | `mcp.canva.com/mcp` | ✅ pass | 33 | `search-folders` ok | Fresh DCR + consent. 9 s. Scope string is enormous (asset/brandkit/design/folder…). |
| Granola | `mcp.granola.ai/mcp` | ✅ pass | 6 | `list_meetings` ok | AS is `mcp-auth.granola.ai` (WorkOS). 22 s. |
| Railway | `mcp.railway.app` | ✅ pass | 30 | `whoami` ok | AS is `backboard.railway.com`. 26 s. |
| Resend | `mcp.resend.com/mcp` | ✅ pass | 98 | `list-api-keys` ok | ⚠ Selector's first read-only zero-input tool was `list-api-keys` — see Findings §4. |
| Vercel | `mcp.vercel.com/v1/mcp` | ✅ pass | 35 | `list_projects` ok | Fresh DCR + consent. 13 s. |
| Cloudflare | `mcp.cloudflare.com/mcp` | 🟡 connected | 3 | — | "Cloudflare API MCP" is code-mode: `docs(query)`, `search(code)`, `execute(code)`. Every tool requires input; nothing for "Test connection" to call. |
| PostHog | `mcp.posthog.com/mcp` | 🟡 connected | 1 | — | Single `exec(command, context)` tool — code-mode. Not classifiable as read-only; never auto-callable. |
| Calendly | `mcp.calendly.com` | ❌ DCR rejected | 0 | — | `400 invalid_client_metadata`: `redirect_uri must be an HTTPS/SSL URI or redirect to localhost`. Rejects `http://127.0.0.1:<port>/callback`; **accepts `http://localhost:<port>/callback`** (verified with curl, 201). |
| Figma | `mcp.figma.com/mcp` | ❌ DCR rejected | 0 | — | Registration endpoint `api.figma.com/v1/oauth/mcp/register` answers a bare **403 Forbidden** to any DCR (any UA). Figma docs: *"Only clients listed in the Figma MCP Catalog can connect."* Advertises DCR it will not honour. |
| Supabase | `mcp.supabase.com/mcp` | ❌ blocked (ours) | 0 | — | `NWError 48 Address already in use` on the loopback port, every attempt, with Keelan clicking Authorize. See Findings §1–2. |
| Zapier | `mcp.zapier.com/api/mcp/mcp` | 🔐 needs sign-in | 0 | — | DCR + authorize work; lands on `zapier.com/app/login`. No session in Chrome; credentials can't be entered by the harness. Untested past login. |

Timings are wall-clock from `connectInteractively` start to a settled status.

## Findings (the reusable part)

### 1. First-time consent slower than 10 s fails — the SSE side-channel opens a second OAuth flow
`HTTPClientTransport(streaming: true)` starts an SSE GET that waits for a session ID for
`sseInitializationTimeout` (**10 s**, swift-sdk 0.12.1) and then *"will proceed anyway"*. On a
first-time connect the POST is still parked on the consent screen, so the GET also gets a 401 and
the SDK starts a **second, independent** authorization: second DCR registration (a second
`client_id` at the vendor), second authorize URL (second browser tab), second loopback listener on
the **same** UUID-derived port → `Address already in use` → the connect throws → UI shows
"Needs auth". The user's click on tab #1 then redirects to a listener whose flow the SDK has
already abandoned.

Reproduced 5× on Supabase (consent page is slow enough to always miss 10 s). The seven passes
either had a prior grant (instant auto-redirect) or the consent completed inside 10 s. **Any user
who reads a consent screen before clicking will hit this on any tier-1 server.**

Fix candidates (not done here): serialize grants in `MCPOAuthCoordinator` so a concurrent
`presentAuthorizationURL` for the same server awaits the in-flight one; or connect with
`streaming: false` until the first token exists; or raise `sseInitializationTimeout` well above
human consent time. → ticket.

### 2. An abandoned loopback listener stays bound for 180 s — every Reconnect inside that window fails and opens another tab
`OAuthLoopbackListener.waitForCallback(timeout: 180)` keeps the port for the full wait even after
the SDK has given up on that flow. With a deterministic per-server port, the next Reconnect can't
bind, fails instantly, and each attempt opens a new consent tab. This is what "it keeps opening
regardless of my click" looks like from the outside. → same ticket as §1 (cancel the listener when
the owning flow fails).

### 3. DCR clients are never persisted — every connect registers a new client at the vendor
Each attempt produced a fresh `client_id` (Supabase: six registrations in one session). The SDK
re-registers on every `authorize()`; only the token is persisted (Keychain). Harmless for the
passes, but vendors see a new "Ghostwire" app per attempt, and Calendly-style metadata policies
get re-evaluated every time.

### 4. The "Test connection" selector picks the first zero-input read-only tool — on Resend that is `list-api-keys`
It returned key *metadata* (names/ids, no secrets) and is read-only by every rule we have, but it
is the least reassuring thing a "test" could touch. Worth a deny-list of sensitive nouns
(`key`, `secret`, `token`, `credential`) in `MCPPaneModel.testableTool` before GW-450 surfaces it.

### 5. Code-mode servers have nothing a one-click test can call
Cloudflare (`docs/search/execute`) and PostHog (`exec`) expose 1–3 input-bearing tools. "Test
connection" is unavailable there by design, and `isFeedCandidate` is false for all of them — so
these cards can connect but never produce a feed card or a test result. GW-450 needs a visible
state for that, or these two are tier-1 in name only.

### 6. Vendor DCR quirks
- **Calendly**: `redirect_uri` must be HTTPS or `localhost` (rejects the RFC 8252 loopback IP we
  use). A per-server "loopback host = localhost" fallback on `invalid_client_metadata` would fix
  it; `MCPHTTPAuth.oauthClient(loopbackPort:loopbackPath:)` already pins port/path, not host.
- **Figma**: advertises `registration_endpoint` but returns 403 — allowlisted clients only.
  Structurally tier-2+ (needs a Figma-issued client, which requires being in their catalog). Drop
  or demote.
- **Zapier**: authorize goes through `zapier.com/app/login` with scope `internal internal:session`
  — a normal login wall, not a DCR problem.

### 7. Harness lessons
- The service collapses every auth-shaped failure into `.needsAuth`
  (`MCPClientService.isAuthError` matches "401"/"authorization"), which hid all of the above until
  the harness re-ran the transport directly to keep the verbatim error. The detail view has the
  same blind spot — "Needs auth" was shown for a port bind failure.
- Reading the live store read-only to reuse a server's UUID (same port, same Keychain token)
  meant no re-consent for servers already added — but it also means the test shares a port with
  the running app.
- `MCPOAuthCoordinator.authorizationURLObserver` (added) prints the authorize URL so consent can
  be completed from a driven tab; the URL carries only public parameters.

## Not done / open
- Notion **MCP Planning** DB Evidence column not updated (out of this PR's scope; table above is
  the source).
- Supabase remains unmeasured past the bug — re-run once §1/§2 are fixed.
- Zapier needs a signed-in Zapier session in the default browser to finish.
- The GW-448 ticket scoped 17 servers; the catalog shipped 13 (Airtable/Asana/Cal.com/Retool were
  cut for lack of logos in GW-449). Those four are unmeasured.
