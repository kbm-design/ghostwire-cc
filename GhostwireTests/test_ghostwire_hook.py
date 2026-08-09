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

    # --- GW-174: gemini-cli ---
    # It has no hook `allow`: BeforeTool output can only block or escalate to
    # ask, so an allow is expressed by saying nothing.
    assert m._allow_output("gemini") is None

    # Deny speaks gemini-cli's documented BeforeTool contract on stdout, exit 0.
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = exit_code(lambda: m._emit_third_party_decision("gemini", "deny", "nope"))
    assert rc == 0, rc
    assert json.loads(buf.getvalue()) == {"decision": "deny", "reason": "nope"}, buf.getvalue()
    # Allow / ask both fall through to silence.
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        assert exit_code(lambda: m._emit_third_party_decision("gemini", "allow", "")) == 0
        assert exit_code(lambda: m._emit_third_party_decision("gemini", "ask", "")) == 0
    assert buf.getvalue() == "", buf.getvalue()

    # --- effective-policy step-aside (GW-174, Codex review) ---
    # The hook must mirror gemini's own effective policy, not just the shipped
    # read-only list: gating a call gemini was going to make automatically
    # invents an approval the user did not previously have.
    m._gemini_ancestor_command = lambda: ""
    m._gemini_settings = lambda cwd: {}
    assert m._gemini_should_step_aside("read_file", "/x") is True
    assert m._gemini_should_step_aside("invoke_agent", "/x") is True   # agents.toml
    assert m._gemini_should_step_aside("run_shell_command", "/x") is False
    assert m._gemini_should_step_aside("write_file", "/x") is False
    # Unknown / MCP tools default to ask_user in gemini, so they stay gated.
    assert m._gemini_should_step_aside("some_mcp_tool", "/x") is False

    # yolo allows `*` — Ghostwire must not reintroduce approvals the user
    # explicitly turned off.
    m._gemini_ancestor_command = lambda: "node /opt/gemini.js --yolo -p hi"
    assert m._gemini_should_step_aside("run_shell_command", "/x") is True
    m._gemini_ancestor_command = lambda: "node /opt/gemini.js --approval-mode=yolo"
    assert m._gemini_should_step_aside("write_file", "/x") is True
    m._gemini_ancestor_command = lambda: "node /opt/gemini.js --approval-mode autoEdit"
    assert m._gemini_should_step_aside("write_file", "/x") is True     # write.toml autoEdit
    assert m._gemini_should_step_aside("run_shell_command", "/x") is False

    # settings.general.defaultApprovalMode is honoured — except "yolo", which
    # gemini itself ignores from settings, so we ignore it too.
    m._gemini_ancestor_command = lambda: ""
    m._gemini_settings = lambda cwd: {"general": {"defaultApprovalMode": "autoEdit"}}
    assert m._gemini_should_step_aside("replace", "/x") is True
    m._gemini_settings = lambda cwd: {"general": {"defaultApprovalMode": "yolo"}}
    assert m._gemini_should_step_aside("run_shell_command", "/x") is False

    # tools.allowed steps aside on a bare name; a narrowed entry does not,
    # because a hook cannot evaluate the argument pattern.
    m._gemini_settings = lambda cwd: {"tools": {"allowed": ["run_shell_command"]}}
    assert m._gemini_should_step_aside("run_shell_command", "/x") is True
    m._gemini_settings = lambda cwd: {"tools": {"allowed": ["run_shell_command(git status)"]}}
    assert m._gemini_should_step_aside("run_shell_command", "/x") is False

    m._gemini_settings = lambda cwd: {}

    # BeforeTool on a tool gemini's own policy allows outright must NOT hold a
    # gate — that would invent an approval the user never had. It reports as
    # running-tool telemetry instead.
    sent = []
    m.send_event = lambda state: sent.append(dict(state)) or None
    st = {"source": "gemini"}
    assert exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "BeforeTool", "tool_name": "read_file",
         "tool_input": {"path": "a"}}, "gemini", st)) == 0
    assert st["event"] == "PreToolUse" and st["status"] == "running_tool", st
    assert "tool_use_id" not in st, st

    # A tool it does NOT auto-allow gates normally.
    m.send_event = lambda state: {"decision": "allow", "reason": ""}
    st = {"source": "gemini"}
    assert exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "BeforeTool", "tool_name": "run_shell_command",
         "tool_input": {"command": "ls"}}, "gemini", st)) == 0
    assert st["event"] == "PermissionRequest" and st["status"] == "waiting_for_approval", st
    assert st["tool"] == "run_shell_command"
    # gemini payloads carry no tool_use_id, so one must be synthesised or
    # HookSocketServer closes the request without waiting.
    assert st["tool_use_id"].startswith("ghostwire-"), st

    # AfterAgent is gemini's ONLY end-of-turn event and it also carries the
    # reply, so it fans out into AgentMessage + Stop.
    sent = []
    m.send_event = lambda state: sent.append(dict(state)) or None
    st = {"source": "gemini"}
    r = exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "AfterAgent", "prompt_response": "done"}, "gemini", st))
    assert r is None, r
    assert [e["event"] for e in sent] == ["AgentMessage", "Stop"], sent
    assert sent[0]["message"] == "done", sent
    assert sent[1]["status"] == "waiting_for_input", sent

    # A re-entrant AfterAgent (stop_hook_active) must not replay the reply —
    # gemini fires it again on a continuation when a co-located AfterAgent hook
    # blocks, and a replayed AgentMessage doubles the chat row.
    sent = []
    st = {"source": "gemini"}
    exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "AfterAgent", "prompt_response": "done",
         "stop_hook_active": True}, "gemini", st))
    assert [e["event"] for e in sent] == ["Stop"], sent

    # AfterTool forwards gemini's `tool_response` spelling of the output.
    sent = []
    st = {"source": "gemini"}
    exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "AfterTool", "tool_name": "write_file",
         "tool_response": {"ok": True}}, "gemini", st))
    assert st["event"] == "PostToolUse" and st["status"] == "processing", st
    assert st["message"] == json.dumps({"ok": True}), st

    # BeforeAgent is the UserPromptSubmit equivalent and carries the prompt.
    st = {"source": "gemini"}
    exit_code(lambda: m._handle_third_party(
        {"hook_event_name": "BeforeAgent", "prompt": "hi"}, "gemini", st))
    assert st["event"] == "UserPromptSubmit" and st["message"] == "hi", st

    # Identity: gemini stamps no vendor key on the payload, so the fingerprint
    # is GEMINI_SESSION_ID matching the payload's session_id.
    gemini_payload = {"hook_event_name": "BeforeTool", "session_id": "g-1"}
    real_env = os.environ.get("GEMINI_SESSION_ID")
    try:
        os.environ["GEMINI_SESSION_ID"] = "g-1"
        assert m._detect_agent(gemini_payload, "claude") == "gemini"
        # A stale exported value that does not match the payload proves nothing.
        os.environ["GEMINI_SESSION_ID"] = "stale"
        assert m._detect_agent(gemini_payload, "claude") == "claude"
        os.environ.pop("GEMINI_SESSION_ID")
        assert m._detect_agent(gemini_payload, "claude") == "claude"
    finally:
        if real_env is None:
            os.environ.pop("GEMINI_SESSION_ID", None)
        else:
            os.environ["GEMINI_SESSION_ID"] = real_env

    real_isfile = os.path.isfile
    try:
        os.path.isfile = lambda p: p.endswith(os.path.join(".gemini", "hooks", "ghostwire-hook.py"))
        assert m._agent_has_own_hook("gemini") is True
    finally:
        os.path.isfile = real_isfile

    print("test_ghostwire_hook: all adapter tests passed")


if __name__ == "__main__":
    main()
