#!/usr/bin/env python3
"""
Ghostwire Hook
- Sends session state to Ghostwire.app via Unix socket (local) or TCP (remote)
- For PermissionRequest: waits for user decision from the app

Environment variables:
  GHOSTWIRE_HOST    If set (e.g. "localhost:9999"), connect over TCP instead of
                a Unix socket. Intended for Claude Code running on a remote
                VM with an SSH reverse port-forward back to the Mac running
                Ghostwire. Always tunnel over SSH — events may include prompts,
                tool calls, and file paths.
  GHOSTWIRE_SOCKET  Override the default Unix socket path (/tmp/com.ghostwire.notch.sock).
                Ignored when GHOSTWIRE_HOST is set.
"""
import json
import os
import socket
import sys
import uuid

GHOSTWIRE_SOCKET = os.environ.get("GHOSTWIRE_SOCKET", "/tmp/com.ghostwire.notch.sock")
GHOSTWIRE_HOST = os.environ.get("GHOSTWIRE_HOST")
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions

if GHOSTWIRE_HOST:
    _host = GHOSTWIRE_HOST.rpartition(":")[0].strip("[]")
    if _host not in ("localhost", "127.0.0.1", "::1"):
        print(
            f"ghostwire-hook: warning: GHOSTWIRE_HOST={GHOSTWIRE_HOST!r} is not a loopback "
            "address; events contain prompts and tool inputs — only use over "
            "an SSH tunnel.",
            file=sys.stderr,
        )


def _connect_to_ghostwire():
    """Open a connection to Ghostwire (TCP if GHOSTWIRE_HOST is set, else Unix socket)."""
    if GHOSTWIRE_HOST:
        host, sep, port = GHOSTWIRE_HOST.rpartition(":")
        if not sep or not host:
            raise OSError(f"GHOSTWIRE_HOST must be host:port, got {GHOSTWIRE_HOST!r}")
        try:
            port_num = int(port)
        except ValueError:
            raise OSError(f"GHOSTWIRE_HOST port must be an integer, got {port!r}")
        if not 0 < port_num <= 65535:
            raise OSError(f"GHOSTWIRE_HOST port {port_num} out of range (1-65535)")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect((host, port_num))
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(GHOSTWIRE_SOCKET)
    return sock


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def get_cmux_surface():
    """Get the cmux workspace and surface refs for the current terminal"""
    import subprocess
    import shutil

    cmux = shutil.which("cmux")
    if not cmux:
        # Check common locations
        for path in ["/Applications/cmux.app/Contents/Resources/bin/cmux"]:
            if os.path.isfile(path):
                cmux = path
                break
    if not cmux:
        return None, None

    try:
        result = subprocess.run(
            [cmux, "--json", "identify"],
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            caller = data.get("caller") or data.get("focused", {})
            return caller.get("workspace_ref"), caller.get("surface_ref")
    except Exception:
        pass
    return None, None


def send_event(state):
    """Send event to app, return response if any"""
    try:
        sock = _connect_to_ghostwire()
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


# ---------------------------------------------------------------------------
# Third-party agent adapter (GW-175 + cluster)
#
# Claude and Codex speak Ghostwire's native hook vocabulary directly
# (PreToolUse telemetry + a dedicated blocking PermissionRequest, decided via
# {hookSpecificOutput:{decision:{behavior}}}). Every other agent we support
# (Cursor, Copilot, Factory droid, Qoder, CodeBuddy) instead gates on a single
# pre-tool event and honours a universal block signal: exit code 2.
#
# So for those agents this hook NORMALISES on the way in (their native gate
# event -> internal "PermissionRequest" so the existing socket/approval path
# fires unchanged) and DENORMALISES on the way out (deny -> exit 2 + stderr
# reason; allow -> the agent's native allow decision; ask/no-response -> exit 0,
# deferring to the agent's own permission UI). No Swift socket/approval changes.
#
# Field spelling per agent should be re-confirmed against current vendor docs;
# see the plan / GW-175.
# ---------------------------------------------------------------------------

_THIRD_PARTY_AGENTS = {"cursor", "copilot", "factory", "qoder", "codebuddy"}

# Native pre-tool events (lowercased) that should block and wait for the notch.
_GATE_EVENTS = {
    "cursor": {"pretooluse", "beforeshellexecution", "beforemcpexecution"},
    "copilot": {"pretooluse"},
    "factory": {"pretooluse"},
    "qoder": {"pretooluse"},
    "codebuddy": {"pretooluse"},
}

# Native telemetry events (lowercased) -> internal (event name, status).
_TELEMETRY_EVENTS = {
    "posttooluse": ("PostToolUse", "processing"),
    "aftershellexecution": ("PostToolUse", "processing"),
    "userpromptsubmit": ("UserPromptSubmit", "processing"),
    "userpromptsubmitted": ("UserPromptSubmit", "processing"),
    "beforesubmitprompt": ("UserPromptSubmit", "processing"),
    "stop": ("Stop", "waiting_for_input"),
    "sessionstart": ("SessionStart", "waiting_for_input"),
    "sessionend": ("SessionEnd", "ended"),
}


def _extract_tool(data):
    """Pull (tool_name, tool_input) from a third-party gate payload.

    Most agents mirror Claude's tool_name/tool_input. Cursor's
    beforeShellExecution carries `command`/`cwd` instead, and
    beforeMCPExecution carries `url`/`command`."""
    name = data.get("tool_name")
    tool_input = data.get("tool_input", {})
    if not name:
        if data.get("command") is not None:
            name = "Shell"
            tool_input = {"command": data.get("command"), "cwd": data.get("cwd")}
        elif data.get("url"):
            name = "MCP"
            tool_input = {"url": data.get("url")}
    return name, tool_input


def _allow_output(source):
    """Native allow decision so the agent doesn't re-prompt after a notch allow.
    None -> just exit 0 (exit-code-only agents)."""
    if source in ("factory", "qoder", "codebuddy"):
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}
    if source == "copilot":
        return {"permissionDecision": "allow"}
    if source == "cursor":
        return {"permission": "allow"}
    return None


def _emit_third_party_decision(source, decision, reason):
    """Denormalise the notch decision into the agent's native contract."""
    if decision == "deny":
        if source == "cursor":
            # Cursor's documented contract is a JSON permission response
            # ({"permission": "deny"}); exit-2 semantics are undocumented
            # for it, so speak the documented protocol.
            print(json.dumps({
                "permission": "deny",
                "agent_message": reason or "Denied by user via Ghostwire",
            }))
            sys.exit(0)
        # Universal block lever across the other third-party agents.
        sys.stderr.write(reason or "Denied by user via Ghostwire")
        sys.exit(2)
    if decision == "allow":
        out = _allow_output(source)
        if out is not None:
            print(json.dumps(out))
        sys.exit(0)
    # "ask" / unknown: defer to the agent's own permission UI.
    sys.exit(0)


def _handle_third_party(data, source, state):
    """Route a third-party agent event through the normalise/denormalise path."""
    raw = data.get("hook_event_name", "").lower()

    if raw in _GATE_EVENTS.get(source, set()):
        name, tool_input = _extract_tool(data)
        state["event"] = "PermissionRequest"  # normalise to the internal gate
        state["status"] = "waiting_for_approval"
        state["tool"] = name
        state["tool_input"] = tool_input
        # HookSocketServer correlates a held PermissionRequest by tool_use_id;
        # with none (e.g. Cursor's beforeShellExecution carries no id) it closes
        # the request without waiting and we'd silently fail open. Synthesise a
        # stable id so the direct-correlation path keeps the socket open. There
        # is no preceding PreToolUse for these agents, so the cache never has it.
        state["tool_use_id"] = data.get("tool_use_id") or f"ghostwire-{uuid.uuid4().hex}"

        response = send_event(state)
        if response:
            _emit_third_party_decision(
                source, response.get("decision", "ask"), response.get("reason", "")
            )
        # No response (app down / timeout) -> fail open, let the agent proceed.
        sys.exit(0)

    mapped = _TELEMETRY_EVENTS.get(raw)
    if mapped:
        state["event"], state["status"] = mapped
        if state["status"] == "processing" and raw in ("posttooluse", "aftershellexecution"):
            name, tool_input = _extract_tool(data)
            state["tool"] = name
            state["tool_input"] = tool_input
    else:
        state["status"] = "unknown"
    send_event(state)


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    # Claude/Codex send session_id; Cursor sends conversation_id (its stable
    # per-conversation id, verified against Cursor's hooks docs 2026-07).
    session_id = data.get("session_id") or data.get("conversation_id") or "unknown"
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    # Authoritative transcript location. cwd can lag behind for worktree sessions
    # (Claude keys the projects dir by launch cwd), so forward the hook's own
    # transcript_path and let Swift prefer it over cwd-derivation (GW-205).
    transcript_path = data.get("transcript_path", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()
    cmux_workspace, cmux_surface = get_cmux_surface()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        # Which agent installed this hook (set by the installer); defaults to claude
        "source": os.environ.get("GHOSTWIRE_AGENT", "claude"),
    }

    # Forward the transcript path when the agent provides one (GW-205).
    if transcript_path:
        state["transcript_path"] = transcript_path

    # Include cmux surface info if running in cmux
    if cmux_workspace and cmux_surface:
        state["cmux_workspace"] = cmux_workspace
        state["cmux_surface"] = cmux_surface

    # Third-party agents (Cursor, Copilot, droid, Qoder, CodeBuddy) speak their
    # own event/decision dialect — normalise in, denormalise out. Claude/Codex
    # fall through to the native path below unchanged.
    if state["source"] in _THIRD_PARTY_AGENTS:
        _handle_third_party(data, state["source"], state)
        return

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via Ghostwire",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - usually means back to waiting
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
