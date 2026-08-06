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
# Connecting and sending are local and instant; anything slower is a broken
# socket, not a busy one.
TIMEOUT_SECONDS = 10

# GW-408: how long to wait for a human. This deliberately matches the `timeout`
# the installers register on the PermissionRequest hook (86400, see
# HookInstaller.swift / CodexHookInstaller.swift) so that **the agent owns the
# deadline, not Ghostwire**.
#
# It used to be 300s, which was 288x shorter than what the agent allowed. Before
# PR #77 that was merely pointless — the hook exited 0 and the terminal asked.
# After PR #77 it was destructive: step away for six minutes and the tool you
# were about to approve got denied, worded as a Ghostwire delivery failure, while
# the notch still showed a live gate over a socket that was already dead.
#
# Ghostwire must never manufacture a verdict out of elapsed time. If the user
# never answers, the agent's own hook timeout ends the turn — the same way it
# would if Ghostwire were not installed at all.
DECISION_TIMEOUT_SECONDS = 86400

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
            # A person has to look at this — give them as long as the agent does.
            sock.settimeout(DECISION_TIMEOUT_SECONDS)
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def permission_output(decision):
    return {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }


def emit_allow(updated_input=None):
    decision = {"behavior": "allow"}
    if updated_input is not None:
        decision["updatedInput"] = updated_input
    print(json.dumps(permission_output(decision)))
    sys.exit(0)


def emit_deny(message):
    output = permission_output({
        "behavior": "deny",
        "message": message,
    })
    print(json.dumps(output))
    sys.exit(0)


def emit_passthrough():
    """GW-408: Ghostwire declines to rule on this gate — the agent asks instead.

    Emitting nothing at all is how a permission hook says "no opinion", which
    drops the decision back to the agent's own approval UI. That is strictly
    better than a deny whenever Ghostwire simply could not take part: the tool
    still does not run unattended, the user is still asked, and the turn is not
    destroyed because the app quit or the socket was reclaimed.

    Only reached on an explicit `{"decision": "ask"}` from the app. A silent
    socket still fails closed below — the app not answering at all is not the
    same as the app saying "not mine to answer".
    """
    sys.exit(0)


def _request_marker(session_id, tool_name):
    return f"{session_id}:{tool_name or 'unknown'}:{os.getpid()}"


def user_denial_message(session_id, tool_name, detail):
    """A person looked at this and said no."""
    return f"Denied by you in Ghostwire: {detail} (request {_request_marker(session_id, tool_name)})."


def fail_closed_message(session_id, tool_name, detail):
    """GW-408: nobody decided this — Ghostwire could not deliver the request.

    Worded so the agent (and the user reading the terminal) can tell it apart
    from a real denial. Conflating the two taught the model that the user had
    rejected something they were never shown.
    """
    return (
        f"Blocked by Ghostwire — this was not a decision by you: {detail} "
        f"(request {_request_marker(session_id, tool_name)})."
    )


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
    # GW-311: Cursor's transcript is written lazily/incompletely, so the notch
    # chat is sourced from the hook stream instead. afterAgentResponse carries
    # the assistant's natural-language reply for that turn.
    "afteragentresponse": ("AgentMessage", "processing"),
}


def _stringify(value):
    """Flatten a hook field that may be a string or structured JSON to text."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value)
    except (TypeError, ValueError):
        return str(value)


def _extract_tool(data):
    """Pull (tool_name, tool_input) from a third-party gate payload.

    Most agents mirror Claude's tool_name/tool_input. Cursor's
    beforeShellExecution carries `command`/`cwd` instead, and
    beforeMCPExecution carries `url`/`command`."""
    name = data.get("tool_name")
    tool_input = data.get("tool_input", {})
    if not name:
        # Check url before command: beforeMCPExecution carries BOTH, and
        # classifying it as Shell would drop the URL from the approval UI
        # (Codex P2, 2026-07-08).
        if data.get("url"):
            name = "MCP"
            tool_input = {"url": data.get("url"), "command": data.get("command")}
        elif data.get("command") is not None:
            name = "Shell"
            tool_input = {"command": data.get("command"), "cwd": data.get("cwd")}
    return name, tool_input


# GW-341: GHOSTWIRE_AGENT says which CONFIG FILE this hook lives in, not which
# agent is running. cursor-agent also executes ~/.claude/settings.json hooks, so
# a single Cursor turn fires BOTH configs: the Cursor copy reports source=cursor
# and the Claude copy reports the same event again as source=claude. Whichever
# landed last owned the session's identity — which is why every Cursor session in
# the notch wore a Claude tag.
#
# The payload doesn't lie: Cursor stamps `cursor_version` on every event it
# sends. Verified live 2026-07-29 against cursor-agent 2026.07.01 — present on
# sessionStart/preToolUse/postToolUse/beforeShellExecution/beforeMCPExecution/
# sessionEnd, and absent from every Claude Code payload.
_AGENT_FINGERPRINTS = (
    ("cursor", "cursor_version"),
)

# Where each agent's own hook lives, so we can tell "its hook already reported
# this" from "we're the only hook that will".
_AGENT_CONFIG_DIRS = {
    "cursor": ".cursor",
    "copilot": ".copilot",
    "factory": ".factory",
    "qoder": ".qoder",
    "codebuddy": ".codebuddy",
}


def _detect_agent(data, declared):
    """The agent that actually produced this payload, or `declared` if unsure."""
    for agent, marker in _AGENT_FINGERPRINTS:
        if marker in data:
            return agent
    return declared


def _agent_has_own_hook(agent):
    """Whether `agent`'s own ghostwire hook is installed. Uninstall removes the
    script, so its presence tracks installation."""
    config_dir = _AGENT_CONFIG_DIRS.get(agent)
    if not config_dir:
        return False
    return os.path.isfile(
        os.path.expanduser(os.path.join("~", config_dir, "hooks", "ghostwire-hook.py"))
    )


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
        if raw == "beforesubmitprompt":
            # GW-311: carry the prompt text so the notch mirrors the user's turn.
            prompt = data.get("prompt")
            if prompt:
                state["message"] = _stringify(prompt)
        elif raw in ("posttooluse", "aftershellexecution"):
            name, tool_input = _extract_tool(data)
            state["tool"] = name
            state["tool_input"] = tool_input
            # Correlate with the tool row created at gate time (GW-311).
            tool_use_id = data.get("tool_use_id")
            if tool_use_id:
                state["tool_use_id"] = tool_use_id
            # Cursor's transcript rarely carries results in real time, so the
            # tool output only reliably arrives here — forward it for the chat.
            output = data.get("tool_output")
            if output is not None:
                state["message"] = _stringify(output)
        elif raw == "afteragentresponse":
            # Field spelling varies by version; take the first populated one.
            text = (data.get("response") or data.get("text")
                    or data.get("message") or data.get("content"))
            if text:
                state["message"] = _stringify(text)
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
    # GW-311: some payloads carry no cwd (Cursor's beforeSubmitPrompt/stop), which
    # left sessions titled "/" — the lastPathComponent of an empty path. Every
    # Cursor payload also carries workspace_roots; use the first as the fallback.
    if not cwd:
        roots = data.get("workspace_roots") or []
        if isinstance(roots, list) and roots and isinstance(roots[0], str):
            cwd = roots[0]
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

    # GW-341: trust the payload over the config file we happen to live in.
    actual = _detect_agent(data, state["source"])
    if actual != state["source"]:
        if _agent_has_own_hook(actual):
            # That agent's own hook is installed and reports this same event.
            # Sending it twice re-stamps the session's identity and, for a gate,
            # raises a second approval for one tool call. Stay quiet.
            sys.exit(0)
        # We're the only hook that will see this turn — report it, but under the
        # agent that actually ran, never under the one whose config we're in.
        state["source"] = actual

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
                # GW-322: ExitPlanMode is the one tool where a bare
                # {"behavior": "allow"} is SILENTLY DISCARDED. Measured on live
                # Claude Code 2.1.222: bare allow -> no PostToolUse, the terminal's
                # own plan menu stays up, the verdict simply vanishes (reproduced
                # twice). Echoing the tool_input back as `updatedInput` accepts it
                # -> PostToolUse fires and permission_mode moves plan -> default.
                #
                # Scoped to ExitPlanMode on purpose: a bare allow was verified to
                # work for Write, so State A's shipped approval path stays
                # byte-identical rather than round-tripping every payload through
                # this hook's JSON encoder for no reason.
                updated_input = response.get("updatedInput")
                if updated_input is None and data.get("tool_name") == "ExitPlanMode":
                    updated_input = tool_input or {}
                emit_allow(updated_input)

            elif decision == "deny":
                emit_deny(reason or user_denial_message(
                    session_id,
                    state.get("tool"),
                    "the request was denied",
                ))

            elif decision == "ask":
                # GW-408: the app is explicitly handing this gate back (it is
                # shutting down, the turn ended, the tool resolved elsewhere, a
                # newer request superseded this one). Let the agent ask.
                emit_passthrough()

        emit_deny(fail_closed_message(
            session_id,
            state.get("tool"),
            "Ghostwire could not be reached for an approval decision, so the tool was blocked "
            "rather than run unseen. Re-run it to be asked again",
        ))

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
