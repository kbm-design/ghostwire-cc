# MCP Gateway — Phase 0 (core engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the gateway engine — enumerate the user's connected downstream MCP servers, re-expose their *allowed* tools (with full `inputSchema`) under a per-server namespace, and route a `CallTool` to the right downstream — over the in-memory transport, with no commitment to a wire transport or UI.

**Architecture:** A pure `MCPGatewayCore` reads from an injectable `GatewayUpstreamSource` (faked in tests; backed by `MCPClientService.shared` in production). It produces a namespaced `[Tool]` exposure + a route map, and forwards calls. No notch gating — the host gates (native-passthrough). Search wrapper / usage-ranking are out of scope (later phases).

**Tech Stack:** Swift, `modelcontextprotocol/swift-sdk` (`MCP` module: `Tool`, `Value`, `Server`, `Client`, `InMemoryTransport`), XCTest. Build/test with `-scheme Ghostwire`.

## Global Constraints
- New Swift files MUST live under `Ghostwire/Ghostwire/Services/MCP/` (the synced group root; `components/`/`models/` are explicit pbxproj refs and silently won't compile).
- Server **slug must be underscore-free** (Gemini splits the tool FQN on underscores). Slugify downstream names accordingly.
- Exposed tool name = `‹slug›_‹originalToolName›` (single `_` join; original tool names may themselves contain `_` — never parse the exposed name, always resolve via the route map).
- Default-deny: only tools the user has allowlisted are exposed (the source supplies already-allowed tools).
- Approval is the host's; the gateway never gates. Build/test must stay clean: `set -o pipefail; xcodebuild test -scheme Ghostwire ...`.
- Mirror existing idioms: `MCPServeRuntime` (server composition) and `MCPServeRuntimeTests` (in-memory `InMemoryTransport.createConnectedPair()` driving a real SDK `Client`).

---

### Task 1: Upstream seam — `GatewayUpstreamSource` + slug

**Files:**
- Create: `Ghostwire/Ghostwire/Services/MCP/GatewayUpstream.swift`
- Test: `GhostwireTests/GatewayUpstreamTests.swift`

**Interfaces:**
- Produces:
  - `struct GatewayUpstreamServer { let id: UUID; let displayName: String; let slug: String; let tools: [Tool] }` (`tools` = the connected, *allowlisted*, full SDK `Tool`s incl. `inputSchema`).
  - `protocol GatewayUpstreamSource { func servers() async -> [GatewayUpstreamServer]; func call(serverID: UUID, tool: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput }`
  - `enum GatewaySlug { static func slugify(_ name: String) -> String }` — lowercased, `[a-z0-9]` kept, every other run collapsed away; empty → `"server"`.
  - Test helper `FinalFakeUpstreamSource` (in the test file) capturing `call(...)` args.

- [ ] **Step 1: Write the failing test** (`GatewayUpstreamTests.swift`)
```swift
import MCP
import XCTest
@testable import Ghostwire

final class GatewayUpstreamTests: XCTestCase {
    func testSlugifyStripsNonAlphanumericAndUnderscores() {
        XCTAssertEqual(GatewaySlug.slugify("Linear"), "linear")
        XCTAssertEqual(GatewaySlug.slugify("Google Sheets"), "googlesheets")
        XCTAssertEqual(GatewaySlug.slugify("my_server"), "myserver")   // no underscores survive
        XCTAssertEqual(GatewaySlug.slugify("!!!"), "server")           // fallback
    }
}
```
- [ ] **Step 2: Run to verify it fails** — `set -o pipefail; xcodebuild test -scheme Ghostwire -only-testing:GhostwireTests/GatewayUpstreamTests 2>&1 | xcbeautify` → FAIL (`GatewaySlug` undefined).
- [ ] **Step 3: Implement** `GatewayUpstream.swift` — the struct, protocol, and `GatewaySlug.slugify` (filter `Character.isLetter || .isNumber`, lowercased; collapse removed runs; fallback `"server"`).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat(GW-253): gateway upstream seam + slug`.

### Task 2: `MCPGatewayCore.buildExposure` — namespaced merge + schema forwarding

**Files:**
- Create: `Ghostwire/Ghostwire/Services/MCP/MCPGatewayCore.swift`
- Test: `GhostwireTests/MCPGatewayCoreTests.swift`

**Interfaces:**
- Consumes: `GatewayUpstreamSource`, `GatewayUpstreamServer`.
- Produces:
  - `struct GatewayRoute { let serverID: UUID; let originalName: String }`
  - `struct GatewayExposure { let tools: [Tool]; let routes: [String: GatewayRoute] }`
  - `struct MCPGatewayCore { init(source: GatewayUpstreamSource); func buildExposure() async -> GatewayExposure }`
  - Exposed `Tool` = a copy of the upstream `Tool` with `name` replaced by `‹slug›_‹original›`, `inputSchema`/`description`/`annotations` preserved.

- [ ] **Step 1: Write the failing test** — fake source with one server `{slug:"linear", tools:[create_issue(inputSchema X), list_issues]}`; assert `exposure.tools` names == `["linear_create_issue","linear_list_issues"]`, the `linear_create_issue` tool's `inputSchema` equals X (schema forwarded, not dropped), and `routes["linear_create_issue"] == (serverID, "create_issue")`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `buildExposure()` — iterate `await source.servers()`, for each tool build the renamed `Tool` + route entry.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat(GW-253): gateway core namespaced exposure`.

### Task 3: Collision handling across servers

**Files:** Modify `MCPGatewayCore.swift`; add tests to `MCPGatewayCoreTests.swift`.

- [ ] **Step 1: Failing test** — two servers whose slug+tool collide (e.g. two "linear" or a tool genuinely duplicated) → both exposed names are unique and BOTH resolve in `routes` to their correct `(serverID, originalName)`. Suffix scheme `_2`, `_3`, …
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** dedupe-on-insert (track used exposed names; suffix on clash).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat(GW-253): gateway collision-safe naming`.

### Task 4: `MCPGatewayCore.call` — route + unknown-name error

**Files:** Modify `MCPGatewayCore.swift`; add tests.

**Interfaces:**
- Produces: `func call(exposedName: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput`; `enum GatewayError: Error { case unknownTool(String) }`.

- [ ] **Step 1: Failing test** — build exposure, call `"linear_create_issue"` with args → fake source records `call(serverID, "create_issue", args)` and returns a stub output that flows back; calling an unknown exposed name throws `GatewayError.unknownTool`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `call` — resolve route (must call `buildExposure` or cache it; cache the last route map), `try await source.call(...)`.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat(GW-253): gateway call routing`.

### Task 5: In-memory end-to-end (mirror `MCPServeRuntimeTests`)

**Files:** Test only — `GhostwireTests/MCPGatewayEndToEndTests.swift`.

- [ ] **Step 1: Failing test** — build a real SDK `Server` whose `ListTools` returns `exposure.tools` and whose `CallTool` delegates to `MCPGatewayCore.call`; connect a real `Client` over `InMemoryTransport.createConnectedPair()`; assert `listTools()` returns the namespaced names *with* `inputSchema` populated, and `callTool(name:"linear_create_issue", ...)` routes through to the fake source and returns its output.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the minimal `Server` wiring in the test (no production transport — that's Phase 2).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `test(GW-253): gateway in-memory end-to-end`.

### Task 6: Real adapter + client full-`Tool` surfacing + manual verification

**Files:**
- Modify: `Ghostwire/Ghostwire/Services/MCP/MCPConnection.swift` (add `listFullTools() async throws -> [Tool]` to the actor and the `MCPConnecting` protocol; existing `listTools()` already fetches `[Tool]` then maps — return the raw page collection).
- Modify: `Ghostwire/Ghostwire/Services/MCP/MCPClientService.swift` (cache/expose full `[Tool]` per connected server + an accessor the adapter reads; the adapter filters by `config.allowedTools`).
- Create: `Ghostwire/Ghostwire/Services/MCP/MCPClientServiceUpstreamSource.swift` (`@MainActor` adapter conforming to `GatewayUpstreamSource`, backed by `MCPClientService.shared`; `call` delegates to `callAllowedTool`).
- Test: extend `MCPClientServiceTests` (fake `MCPConnecting` returning full `Tool`s → adapter yields allowlisted, schema-bearing tools; `call` hits `callAllowedTool`).

- [ ] **Step 1: Failing test** for `listFullTools()` on the connection seam + adapter mapping (allowlist filter applied; `inputSchema` present).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the seam method, the client accessor, the adapter.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Manual verification** — connect one real downstream (e.g. Linear) in the GUI; in a scratch harness build `MCPGatewayCore(source: MCPClientServiceUpstreamSource())`, print `buildExposure().tools.map(\.name)` (expect `linear_…` namespaced, schema-bearing) and route one read-only `call`. Record result in GW-253.
- [ ] **Step 6: Commit** — `feat(GW-253): real MCPClientService-backed gateway source`.

---

## Out of scope (later phases)
- **Phase 2:** transport + GUI hosting (stdio for Claude Desktop vs HTTP-in-GUI + OpenAI Secure Tunnel for ChatGPT) — resolves the GUI↔subprocess auth-boundary.
- **Phase 3:** search wrapper (`search_tools` schema-embedded + `use_tool`) + usage-ranked auto-pinning, only for no-tool-search hosts at scale.
- `resources/list` must answer promptly even if empty (Codex hangs otherwise) — fold into Phase 2 when the gateway becomes a real server.

## Self-review notes
- Spec coverage: enumerate (T6 source) · forward full schema (T2/T6) · namespace + collision (T2/T3 + slug T1) · route (T4) · end-to-end proof (T5). ✓
- The `inputSchema`-dropped gap is addressed in T6 (`listFullTools`), with T1–T5 proving the core against a fake that already supplies full `Tool`s — so the engine is proven before the client change.
