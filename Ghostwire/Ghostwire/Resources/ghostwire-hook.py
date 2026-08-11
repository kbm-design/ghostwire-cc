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
        target = (host, port_num)
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        target = GHOSTWIRE_SOCKET
    # Close before re-raising: a failed connect otherwise leaks the fd for the
    # life of the hook process.
    try:
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(target)
    except Exception:
        sock.close()
        raise
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
    sock = None
    try:
        sock = _connect_to_ghostwire()
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            # A person has to look at this — give them as long as the agent does.
            sock.settimeout(DECISION_TIMEOUT_SECONDS)
            response = sock.recv(4096)
            if response:
                return json.loads(response.decode())

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


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
    """GW-413: reachable from exactly one place — an explicit `deny` from the app,
    which the app in turn only ever sends when a person clicked Deny in the notch.

    That invariant is the whole contract. Ghostwire is complimentary, never a
    driver: it may not decide anything a human did not decide. If you find
    yourself wanting to call this because something went wrong, you want
    `emit_passthrough` instead.
    """
    output = permission_output({
        "behavior": "deny",
        "message": message,
    })
    print(json.dumps(output))
    sys.exit(0)


def emit_passthrough():
    """Ghostwire steps aside — the agent's own approval flow handles this gate.

    Emitting nothing at all is how a permission hook says "no opinion", which
    drops the decision back to the agent's own prompt. This is the default for
    every outcome that is not a human clicking a button, because the terminal
    prompt — not Ghostwire — is the actual permission boundary. Stepping aside
    never removes a gate from the user; it only moves where they answer it.

    Reached on an explicit `{"decision": "ask"}` (the app is shutting down, the
    turn ended, the tool resolved elsewhere, a newer gate superseded this one)
    and on any failure to reach the app at all (GW-413). Silence used to deny
    here, which meant quitting Ghostwire destroyed every tool call in flight.
    """
    sys.exit(0)


def _request_marker(session_id, tool_name):
    return f"{session_id}:{tool_name or 'unknown'}:{os.getpid()}"


def user_denial_message(session_id, tool_name, detail):
    """A person looked at this and said no. The only denial Ghostwire ever writes."""
    return f"Denied by you in Ghostwire: {detail} (request {_request_marker(session_id, tool_name)})."


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
# gemini-cli (GW-174) joins the same path with two differences, both verified
# against @google/gemini-cli 0.54.0 source rather than docs:
#
#  1. Its BeforeTool hook runs to completion BEFORE the policy engine is
#     consulted (`scheduler`: evaluateBeforeToolHook -> checkPolicy ->
#     resolveConfirmation), and a hook that says nothing leaves the policy
#     decision exactly as it was. **Silence is a true step-aside on Gemini** —
#     the native ask_user prompt still renders. Every GW-413 escape hatch
#     (`ask`, no reply, unparseable payload) therefore behaves as designed.
#  2. There is no hook `allow`. BeforeTool output can only BLOCK
#     (decision block/deny) or ESCALATE (decision ask); `decision = policy`
#     unless the hook asks for more. So an Allow click in the notch releases the
#     hold and nothing more — if Gemini's own policy would have prompted, it
#     still prompts. The notch gate is authoritative for DENY, and is the only
#     gate when Gemini would have auto-allowed.
# ---------------------------------------------------------------------------

_THIRD_PARTY_AGENTS = {"cursor", "copilot", "factory", "qoder", "codebuddy", "gemini"}

# Native pre-tool events (lowercased) that should block and wait for the notch.
_GATE_EVENTS = {
    "cursor": {"pretooluse", "beforeshellexecution", "beforemcpexecution"},
    "copilot": {"pretooluse"},
    "factory": {"pretooluse"},
    "qoder": {"pretooluse"},
    "codebuddy": {"pretooluse"},
    "gemini": {"beforetool"},
}

# Tools gemini-cli's own shipped policy ALLOWS outright (bundle
# policies/read-only.toml, @google/gemini-cli 0.54.0). Gemini never prompts for
# these, so holding a gate on one would ADD an approval the user did not have —
# Ghostwire is complimentary, never a driver. They report as telemetry instead.
# Anything not on this list defaults to ask_user in an interactive session, so
# gating it mirrors a prompt the user was going to get anyway.
_GEMINI_POLICY_ALLOWED_TOOLS = {
    # agents.toml — allowed in default/autoEdit/yolo.
    "invoke_agent",
    # read-only.toml
    "glob",
    "grep_search",
    "list_directory",
    "read_file",
    "google_web_search",
    "codebase_investigator",
    "cli_help",
    "get_internal_docs",
    "tracker_create_task",
    "tracker_update_task",
    "tracker_get_task",
    "tracker_list_tasks",
    "tracker_add_dependency",
    "tracker_visualize",
    "update_topic",
    "complete_task",
    "read_mcp_resource",
    "list_mcp_resources",
}

# write.toml grants these outright in autoEdit ("accepting edits") mode.
_GEMINI_AUTO_EDIT_ALLOWED_TOOLS = {"replace", "write_file", "web_fetch"}


def _gemini_settings(cwd):
    """Merged-ish view of gemini's settings: workspace over user. Best effort —
    a missing or unreadable file simply contributes nothing."""
    merged = {}
    for base in (os.path.expanduser("~"), cwd or ""):
        if not base:
            continue
        path = os.path.join(base, ".gemini", "settings.json")
        try:
            with open(path, encoding="utf-8") as f:
                loaded = json.load(f)
        except Exception:
            continue
        if isinstance(loaded, dict):
            merged.update(loaded)
    return merged


def _gemini_effective_mode(settings):
    """gemini's approval mode, as far as a hook can see it.

    Only `general.defaultApprovalMode` is readable — and gemini deliberately
    ignores that key when it says "yolo", so we ignore it there too (verified in
    @google/gemini-cli 0.54.0 config loading).

    KNOWN GAPS, both of which cause Ghostwire to gate a tool gemini would have
    run silently: a `--yolo` / `--approval-mode` flag passed on the command
    line, and Shift+Tab cycling the mode mid-session. Neither leaves anything a
    hook can read. We used to walk the process tree for the flag; that was four
    `ps` spawns per gate to guess at another tool's argv, and it bought only the
    launch-flag case. Erring toward gating is the safe direction — an extra
    prompt is recoverable, a missed one is not — and the per-agent toggle in
    Settings is the real escape hatch for someone who wants none of this.
    """
    configured = (settings.get("general") or {}).get("defaultApprovalMode")
    if isinstance(configured, str) and configured != "yolo":
        return configured
    return "default"


def _gemini_should_step_aside(tool_name, cwd):
    """Whether gemini would run this tool without ever asking.

    Ghostwire is complimentary, never a driver: holding a gate on a call the
    agent was going to make automatically INVENTS an approval the user did not
    previously have. So mirror gemini's own effective policy as closely as a
    hook can see it, and when in doubt gate — an extra prompt in the notch is
    recoverable, a missed one is not.
    """
    settings = _gemini_settings(cwd)
    mode = _gemini_effective_mode(settings)
    if mode == "yolo":
        # yolo.toml allows `*`. Ghostwire must not reintroduce approvals the
        # user explicitly turned off.
        return True
    if tool_name in _GEMINI_POLICY_ALLOWED_TOOLS:
        return True
    if mode == "autoEdit" and tool_name in _GEMINI_AUTO_EDIT_ALLOWED_TOOLS:
        return True
    allowed = ((settings.get("tools") or {}).get("allowed")) or []
    if isinstance(allowed, list):
        # A narrowed entry ("run_shell_command(git status)") allows only SOME
        # invocations, and a hook cannot evaluate the pattern — keep gating.
        if any(entry == tool_name for entry in allowed if isinstance(entry, str)):
            return True
    return False

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
    # gemini-cli's names (GW-174). It has no Stop event: AfterAgent both ends
    # the turn and carries the reply, so it is fanned out into an AgentMessage
    # followed by the Stop below.
    "aftertool": ("PostToolUse", "processing"),
    "beforeagent": ("UserPromptSubmit", "processing"),
    "afteragent": ("Stop", "waiting_for_input"),
    "precompress": ("PreCompact", "compacting"),
    "notification": ("Notification", "notification"),
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
    "gemini": ".gemini",
    "copilot": ".copilot",
    "factory": ".factory",
    "qoder": ".qoder",
    "codebuddy": ".codebuddy",
}


def _looks_like_gemini(data):
    """gemini-cli's payload carries no vendor-unique key, so the fingerprint is
    the environment it hands its hook children: `GEMINI_SESSION_ID`, set to the
    same session id it puts in the payload (verified in @google/gemini-cli
    0.54.0 `hookRunner.ts`). Matching the two rules out a stale exported value
    from the user's shell.

    Note it also exports `CLAUDE_PROJECT_DIR` "for compatibility" — which is why
    that variable can never be used to infer Claude.
    """
    gemini_session = os.environ.get("GEMINI_SESSION_ID")
    return bool(gemini_session) and gemini_session == data.get("session_id")


def _detect_agent(data, declared):
    """The agent that actually produced this payload, or `declared` if unsure."""
    for agent, marker in _AGENT_FINGERPRINTS:
        if marker in data:
            return agent
    if _looks_like_gemini(data):
        return "gemini"
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
    # gemini-cli has NO hook allow: BeforeTool output can only block or escalate
    # to ask, so an allow is expressed by saying nothing and letting its policy
    # engine's own decision stand (GW-174). Falls through to None.
    return None


def _emit_third_party_decision(source, decision, reason):
    """Denormalise the notch decision into the agent's native contract."""
    if decision == "deny":
        if source == "gemini":
            # gemini-cli's documented BeforeTool block: a `deny` (or `block`)
            # decision on stdout, exit 0. Its runner also reads a nonzero exit
            # with text as a deny, but stdout JSON is the sanctioned contract
            # and keeps us inside the "no hook path exits nonzero" rule.
            print(json.dumps({
                "decision": "deny",
                "reason": reason or "Denied by user via Ghostwire",
            }))
            sys.exit(0)
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

        if source == "gemini" and _gemini_should_step_aside(name, state.get("cwd")):
            # Gemini's BeforeTool fires for EVERY tool, including the ones its
            # own policy allows without ever asking. Holding those would invent
            # an approval the user did not previously have, so they report as
            # running-tool telemetry and the hook gets out of the way.
            state["event"] = "PreToolUse"
            state["status"] = "running_tool"
            state["tool"] = name
            state["tool_input"] = tool_input
            send_event(state)
            sys.exit(0)

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
        if raw in ("beforesubmitprompt", "beforeagent"):
            # GW-311: carry the prompt text so the notch mirrors the user's turn.
            prompt = data.get("prompt")
            if prompt:
                state["message"] = _stringify(prompt)
        elif raw == "notification":
            state["notification_type"] = data.get("notification_type")
            message = data.get("message")
            if message:
                state["message"] = _stringify(message)
        elif raw == "afteragent":
            # gemini-cli has no Stop event and no separate reply event: AfterAgent
            # is both. Send the assistant's prose as its own AgentMessage first,
            # then fall through to the mapped Stop so the session lands in
            # waitingForInput exactly as it does for every other agent.
            # stop_hook_active marks a re-entrant AfterAgent — gemini fires it
            # again on a continuation when a co-located AfterAgent hook blocks.
            # Replaying the reply would double the chat row and re-drive Stop.
            reply = None if data.get("stop_hook_active") else data.get("prompt_response")
            if reply:
                message_state = dict(state)
                message_state["event"] = "AgentMessage"
                message_state["status"] = "processing"
                message_state["message"] = _stringify(reply)
                send_event(message_state)
        elif raw in ("posttooluse", "aftershellexecution", "aftertool"):
            name, tool_input = _extract_tool(data)
            state["tool"] = name
            state["tool_input"] = tool_input
            # Correlate with the tool row created at gate time (GW-311).
            tool_use_id = data.get("tool_use_id")
            if tool_use_id:
                state["tool_use_id"] = tool_use_id
            # Cursor's transcript rarely carries results in real time, so the
            # tool output only reliably arrives here — forward it for the chat.
            # gemini-cli spells the same field `tool_response`.
            output = data.get("tool_output")
            if output is None:
                output = data.get("tool_response")
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
    except Exception:
        # GW-413: a payload we cannot parse is a gate we cannot show. Step aside
        # rather than exiting nonzero — a hook failure is not a verdict, and the
        # agent must prompt exactly as it would with Ghostwire uninstalled.
        # Deliberately broader than JSONDecodeError: a UnicodeDecodeError or a
        # closed stdin used to traceback out with exit 1.
        emit_passthrough()

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

        # GW-413: everything that is not an explicit allow/deny steps aside —
        # an explicit `ask` (app shutting down, turn ended, tool resolved
        # elsewhere, superseded gate), an unrecognised decision, and above all
        # no reply at all. The terminal's own prompt is the permission boundary;
        # Ghostwire failing must look exactly like Ghostwire not being installed.
        emit_passthrough()

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
    try:
        main()
    except SystemExit:
        # emit_allow / emit_deny / emit_passthrough all exit through here.
        raise
    except Exception:
        # GW-413 backstop: no bug in this hook may ever cost the user a tool
        # call. Whatever broke, the agent's own prompt is still the right
        # outcome, and a nonzero exit is read as a block by the agents that
        # gate on exit codes.
        sys.exit(0)
