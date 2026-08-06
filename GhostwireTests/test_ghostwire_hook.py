#!/usr/bin/env python3
"""
Adapter tests for ghostwire-hook.py's third-party agent path (GW-175).

Run: python3 GhostwireTests/test_ghostwire_hook.py
(Standalone — not part of the XCTest target; the Swift side is covered by
GenericHookInstallerTests. This guards the normalise-in / denormalise-out logic.)
"""
import contextlib
import importlib.util
import io
import json
import os
import sys

HOOK = os.path.join(
    os.path.dirname(__file__),
    "..", "Ghostwire", "Ghostwire", "Resources", "ghostwire-hook.py",
)


def load():
    spec = importlib.util.spec_from_file_location("ghostwire_hook", HOOK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def exit_code(fn):
    try:
        fn()
    except SystemExit as e:
        return e.code
    return None


def main():
    m = load()

    # --- tool extraction ---
    name, inp = m._extract_tool({"command": "rm -rf /", "cwd": "/tmp"})
    assert name == "Shell" and inp["command"] == "rm -rf /", (name, inp)
    name, inp = m._extract_tool({"tool_name": "Edit", "tool_input": {"path": "a"}})
    assert name == "Edit" and inp == {"path": "a"}
    name, inp = m._extract_tool({"url": "https://x"})
    assert name == "MCP" and inp["url"] == "https://x"
    # beforeMCPExecution carries BOTH url and command — must classify as MCP,
    # not Shell (Codex P2, 2026-07-08).
    name, inp = m._extract_tool({"url": "https://mcp.example", "command": "tools/call"})
    assert name == "MCP" and inp["url"] == "https://mcp.example" and inp["command"] == "tools/call", (name, inp)

    # --- allow output shapes ---
    assert m._allow_output("cursor") == {"permission": "allow"}
    assert m._allow_output("copilot") == {"permissionDecision": "allow"}
    assert m._allow_output("qoder")["hookSpecificOutput"]["permissionDecision"] == "allow"
    assert m._allow_output("factory")["hookSpecificOutput"]["permissionDecision"] == "allow"
    assert m._allow_output("codebuddy")["hookSpecificOutput"]["permissionDecision"] == "allow"

    # --- decision denormalisation ---
    # Cursor deny speaks its documented JSON contract ({"permission": "deny"}),
    # not the exit-2 lever (exit-2 semantics are undocumented for Cursor).
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = exit_code(lambda: m._emit_third_party_decision("cursor", "deny", "x"))
    assert rc == 0, rc
    out = json.loads(buf.getvalue())
    assert out == {"permission": "deny", "agent_message": "x"}, out
    # Other third-party agents keep the universal exit-2 block lever.
    assert exit_code(lambda: m._emit_third_party_decision("factory", "deny", "x")) == 2
    assert exit_code(lambda: m._emit_third_party_decision("factory", "allow", "")) == 0
    assert exit_code(lambda: m._emit_third_party_decision("qoder", "ask", "")) == 0

    # --- gate normalisation: native event -> internal PermissionRequest ---
    m.send_event = lambda state: {"decision": "allow", "reason": ""}
    st = {"source": "cursor"}
    assert exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "beforeShellExecution", "command": "ls"}, "cursor", st)) == 0
    assert st["event"] == "PermissionRequest"
    assert st["status"] == "waiting_for_approval"
    assert st["tool"] == "Shell", st
    # P1: a gate event without a native tool_use_id must still carry one, or
    # HookSocketServer closes the request and we silently fail open.
    assert st["tool_use_id"].startswith("ghostwire-"), st
    # ...and a native tool_use_id is preserved when present.
    st2 = {"source": "cursor"}
    exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "preToolUse", "tool_name": "Bash", "tool_use_id": "tui-7"}, "cursor", st2))
    assert st2["tool_use_id"] == "tui-7", st2

    # deny path -> exit 2
    m.send_event = lambda state: {"decision": "deny", "reason": "blocked"}
    assert exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "preToolUse", "tool_name": "Bash", "tool_input": {}},
        "qoder", {"source": "qoder"})) == 2

    # no response from app -> fail open (exit 0)
    m.send_event = lambda state: None
    assert exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "preToolUse", "tool_name": "Bash"},
        "factory", {"source": "factory"})) == 0

    # telemetry event normalises name + status, no exit
    st = {"source": "copilot"}
    r = exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "postToolUse", "tool_name": "Read"}, "copilot", st))
    assert r is None and st["event"] == "PostToolUse" and st["status"] == "processing", (r, st)

    # --- GW-341: agent identity comes from the payload, not the config file ---
    # cursor-agent executes ~/.claude/settings.json hooks as well as its own, so
    # the Claude copy of this script receives Cursor payloads. Before the fix it
    # reported them as source=claude and every Cursor session wore a Claude tag.
    cursor_payload = {"hook_event_name": "preToolUse", "cursor_version": "2026.07.01",
                      "conversation_id": "c-1", "session_id": "s-1"}
    claude_payload = {"hook_event_name": "PreToolUse", "session_id": "s-1",
                      "transcript_path": "/x.jsonl"}

    assert m._detect_agent(cursor_payload, "claude") == "cursor"
    assert m._detect_agent(cursor_payload, "cursor") == "cursor"
    # Nothing to go on -> keep what the installer declared. Never guess a vendor.
    assert m._detect_agent(claude_payload, "claude") == "claude"
    assert m._detect_agent(claude_payload, "codex") == "codex"
    assert m._detect_agent({}, "codex") == "codex"

    # Suppression is conditional on the real agent having its own hook: with one
    # installed we'd otherwise double-report (two approvals for one tool call);
    # with none we are the only hook that will see the turn, so report it — under
    # the agent that actually ran.
    real_isfile = os.path.isfile
    try:
        os.path.isfile = lambda p: p.endswith(os.path.join(".cursor", "hooks", "ghostwire-hook.py"))
        assert m._agent_has_own_hook("cursor") is True
        os.path.isfile = lambda p: False
        assert m._agent_has_own_hook("cursor") is False
        # Agents with no third-party config dir (claude/codex) are never suppressed.
        assert m._agent_has_own_hook("claude") is False
        assert m._agent_has_own_hook("codex") is False
    finally:
        os.path.isfile = real_isfile

    print("test_ghostwire_hook: all adapter tests passed")


if __name__ == "__main__":
    main()
