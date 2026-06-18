# MCP Gateway — Phase 2 (HTTP-in-GUI transport) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Host the Phase-0 gateway core as a **localhost Streamable-HTTP MCP server inside the running app**, so a real local agent (Claude Code / MCP Inspector) can connect and use the user's namespaced downstream tools (`linear_*`). In-process = it can reach the live authed connections (`MCPClientService.shared`), solving the auth-boundary.

**Architecture (reference-backed — verified 2026-06-17):** The SDK is deliberately "bring your own HTTP listener, bridge to `StatefulHTTPServerTransport.handleRequest(_:)`" (same as TS/Python SDKs). The least-patchwork listener is the SDK's **own** example listener (`Sources/MCPConformance/Server/HTTPApp.swift`, swift-nio) — vendor + trim it. Honor the spec's localhost security rules.

**Tech Stack:** swift-nio (NIOCore/NIOPosix/NIOHTTP1), MCP SDK (`StatefulHTTPServerTransport`, `Server`), the Phase-0 `MCPGatewayCore` + `MCPClientServiceUpstreamSource`.

## Global Constraints
- New Swift files under `Ghostwire/Ghostwire/Services/MCP/` (synced group).
- **Security (spec-mandated):** bind **`127.0.0.1` only**; **validate `Origin`** (anti DNS-rebinding); require a **per-launch random bearer token**. No `0.0.0.0`, ever.
- Keep the SDK's Apache-2.0 header on any vendored code.
- Build/test `-scheme Ghostwire`, pipefail.

---

### Task 0: Add swift-nio (YOU, in Xcode — project-file change)

The cleanest/safest way to add the dependency (hand-editing `.pbxproj` package products risks corrupting the project).

- [ ] In Xcode: **File → Add Package Dependencies…** → enter `https://github.com/apple/swift-nio.git`. It's already in the resolved graph (transitive via swift-sdk), so Xcode reuses the pinned version — accept it.
- [ ] Add **three products to the `Ghostwire` target**: `NIOCore`, `NIOPosix`, `NIOHTTP1`.
- [ ] Build once (`⌘B`) to confirm resolution. Then hand back to me.

### Task 1: Vendor + trim the NIO HTTP listener

**Files:** Create `Ghostwire/Ghostwire/Services/MCP/GatewayHTTPListener.swift` (adapted from the SDK's `MCPConformance/Server/HTTPApp.swift`).

- Port the NIO `ServerBootstrap` bind + `HTTPHandler` (NIO ↔ `HTTPRequest`/`HTTPResponse`, including the `.stream` SSE case) verbatim where possible (it's the maintainers' tested code). Trim multi-session timeout machinery to what a localhost endpoint needs.
- Config: `host = "127.0.0.1"`, `port` (fixed default, e.g. 51762), `endpoint = "/mcp"`.
- Keep the `ServerFactory = @Sendable (sessionID, StatefulHTTPServerTransport) async throws -> Server` seam — this is where we inject the gateway.

- [ ] **Step 1:** copy `HTTPApp.swift` → `GatewayHTTPListener.swift`, keep Apache-2.0 header + a note it's vendored from the SDK conformance example.
- [ ] **Step 2:** trim to single-endpoint localhost; add Origin-check + bearer-token validation hooks (Task 3 fills them).
- [ ] **Step 3:** build (`xcodebuild build -scheme Ghostwire`) — confirm it compiles against NIO.
- [ ] **Step 4:** Commit — `feat(GW-253): vendor SDK NIO HTTP listener (Phase 2 T1)`.

### Task 2: Gateway MCP server composition (TDD)

**Files:** Create `Ghostwire/Ghostwire/Services/MCP/GatewayServer.swift`; Test `GhostwireTests/GatewayServerTests.swift`.

**Interfaces:**
- `enum GatewayServer { static func makeServer(source: GatewayUpstreamSource) async -> Server }` — `ListTools` → `MCPGatewayCore(source:).buildExposure().tools`; `CallTool` → `core.call(...)` → `CallTool.Result`; `ListResources` → **empty, returns promptly** (Codex marks a server unavailable / hangs if `resources/list` is slow/absent); `instructions` describing the gateway.

- [ ] **Step 1:** failing test — over `InMemoryTransport` (mirror `MCPGatewayEndToEndTests`): a real `Client` against `makeServer(source: fake)` lists `linear_*` tools with schemas and routes a call. (RED)
- [ ] **Step 2:** run → RED.
- [ ] **Step 3:** implement `makeServer`.
- [ ] **Step 4:** run → GREEN.
- [ ] **Step 5:** Commit — `feat(GW-253): gateway MCP server composition (Phase 2 T2)`.

### Task 3: Localhost security — Origin check + per-launch bearer token (TDD)

**Files:** Create `Ghostwire/Ghostwire/Services/MCP/GatewayAuth.swift`; Test `GhostwireTests/GatewayAuthTests.swift`.

**Interfaces:**
- `struct GatewayAuth { let token: String; func validate(method:String, headers:[String:String]) -> Bool }` — reject missing/mismatched `Authorization: Bearer <token>`; reject non-loopback `Origin`. Pure → unit-testable without a socket.

- [ ] **Step 1:** failing tests — valid token+origin → allow; wrong/absent token → deny; non-localhost `Origin` → deny. (RED)
- [ ] **Step 2:** run → RED.
- [ ] **Step 3:** implement; wire into the listener's request path.
- [ ] **Step 4:** run → GREEN.
- [ ] **Step 5:** Commit — `feat(GW-253): gateway localhost auth (Phase 2 T3)`.

### Task 4: Lifecycle service

**Files:** Create `Ghostwire/Ghostwire/Services/MCP/GatewayHTTPService.swift`.

- `@MainActor final class GatewayHTTPService` (`.shared`): owns the listener + token; `start()` binds the listener with `ServerFactory` = `{ _,_ in await GatewayServer.makeServer(source: MCPClientServiceUpstreamSource(service: .shared)) }`; `stop()`; exposes `endpointURL` + `token`. Gate behind a `Default(.mcpGatewayEnabled)` (default off — opt-in). Start on app launch if enabled; stop on terminate.

- [ ] **Step 1:** implement; add `mcpGatewayEnabled` Default; start/stop in `AppDelegate` lifecycle (guard XCTest like the hook server does).
- [ ] **Step 2:** build clean.
- [ ] **Step 3:** Commit — `feat(GW-253): gateway HTTP lifecycle service (Phase 2 T4)`.

### Task 5: Registration helper (TDD)

**Files:** extend `MCPServeRegistration.swift` (or new `GatewayRegistration.swift`); test the builder.

- `claude mcp add --transport http ghostwire-gateway http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"` (+ Codex/Inspector equivalents). Pure builder, testable.

- [ ] **Step 1:** failing test on the command string. → RED → implement → GREEN.
- [ ] **Step 2:** Commit — `feat(GW-253): gateway register command (Phase 2 T5)`.

### Task 6: Surface + manual verification

- Update the throwaway debug section (or a minimal real UI): a toggle to start/stop, the endpoint URL, and the copyable `mcp add` command.
- [ ] **Manual:** enable gateway → `claude mcp add … http://127.0.0.1:<port>/mcp …` in a real Claude Code session (or paste the URL+token into MCP Inspector) → confirm `linear_*` tools list and a real call works. Record in GW-253.

---

## Out of scope (later)
- Claude Desktop (cloud-origin, can't reach localhost) → stdio-with-IPC-bridge or public/tunnel, later.
- ChatGPT → same HTTP server + OpenAI Secure Tunnel, later.
- Search wrapper / usage-ranked pinning (Phase 3).
- Caching the exposure (today it rebuilds per call).
