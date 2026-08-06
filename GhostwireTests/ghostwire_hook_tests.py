import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "Ghostwire" / "Ghostwire" / "Resources" / "ghostwire-hook.py"


def load_hook_module():
    spec = importlib.util.spec_from_file_location("ghostwire_hook_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GhostwireHookPermissionTests(unittest.TestCase):
    def setUp(self):
        self.hook = load_hook_module()

    def permission_payload(self, tool_name="Bash", tool_input=None):
        return {
            "session_id": "hook-test-session",
            "hook_event_name": "PermissionRequest",
            "cwd": "/tmp/ghostwire-hook-tests",
            "tool_name": tool_name,
            "tool_input": tool_input or {"command": "echo should-not-run"},
        }

    def run_main(self, payload, socket_response):
        stdin = io.StringIO(json.dumps(payload))
        stdout = io.StringIO()
        with patch.object(sys, "stdin", stdin), patch("sys.stdout", stdout), patch.object(
            self.hook, "send_event", return_value=socket_response
        ):
            with self.assertRaises(SystemExit) as exit_context:
                self.hook.main()
        return exit_context.exception.code, stdout.getvalue()

    def decision_from_stdout(self, stdout):
        output = json.loads(stdout)
        return output["hookSpecificOutput"]["decision"]

    def test_permission_request_missing_socket_fails_closed(self):
        code, stdout = self.run_main(self.permission_payload(), socket_response=None)

        self.assertEqual(code, 0)
        decision = self.decision_from_stdout(stdout)
        self.assertEqual(decision["behavior"], "deny")
        self.assertIn("Ghostwire", decision["message"])

    # GW-408 --------------------------------------------------------------
    # This used to assert that "ask" fails closed. It no longer does, and the
    # reversal is the point: "ask" is the app explicitly saying "not mine to
    # rule on" (shutting down, turn ended, tool resolved elsewhere, superseded
    # by a newer gate). Denying those destroyed the turn — most visibly,
    # quitting Ghostwire denied every tool call in flight. Silence still fails
    # closed; only an explicit hand-back passes through.

    def test_ask_response_hands_the_gate_back_to_the_agent(self):
        code, stdout = self.run_main(self.permission_payload(), socket_response={"decision": "ask"})

        self.assertEqual(code, 0)
        self.assertEqual(
            stdout, "",
            "An 'ask' must emit no decision at all — any output overrides the agent's own prompt",
        )

    def test_blocked_message_is_distinguishable_from_a_user_denial(self):
        _, blocked_stdout = self.run_main(self.permission_payload(), socket_response=None)
        _, denied_stdout = self.run_main(
            self.permission_payload(), socket_response={"decision": "deny"}
        )

        blocked = self.decision_from_stdout(blocked_stdout)["message"]
        denied = self.decision_from_stdout(denied_stdout)["message"]

        self.assertEqual(self.decision_from_stdout(blocked_stdout)["behavior"], "deny")
        self.assertEqual(self.decision_from_stdout(denied_stdout)["behavior"], "deny")
        # The agent reads these strings. They must not both read as "the user
        # said no" — that taught the model a rejection that never happened.
        self.assertIn("Blocked by Ghostwire", blocked)
        self.assertIn("not a decision by you", blocked)
        self.assertNotIn("Denied by you", blocked)
        self.assertIn("Denied by you in Ghostwire", denied)
        self.assertNotIn("Blocked by Ghostwire", denied)

    def test_decision_wait_is_not_shorter_than_the_registered_hook_timeout(self):
        # GW-408: the hook must not invent a deadline the agent never asked for.
        # 300s against the installers' registered 86400 meant stepping away for
        # six minutes denied the tool you were about to approve.
        self.assertGreaterEqual(
            self.hook.DECISION_TIMEOUT_SECONDS, 86400,
            "The agent owns the approval deadline — Ghostwire must not time out first",
        )
        self.assertLess(
            self.hook.TIMEOUT_SECONDS, 60,
            "Connect/send is local; a long timeout there just hangs on a broken socket",
        )

    def test_app_supplied_denial_reason_is_passed_through_verbatim(self):
        reason = "Ghostwire could not match this Bash request to the tool call it belongs to."
        _, stdout = self.run_main(
            self.permission_payload(), socket_response={"decision": "deny", "reason": reason}
        )

        self.assertEqual(self.decision_from_stdout(stdout)["message"], reason)

    def test_exit_plan_mode_allow_forwards_updated_input(self):
        tool_input = {"plan": "Implement the reviewed plan.", "title": "Audit remediation"}

        code, stdout = self.run_main(
            self.permission_payload(tool_name="ExitPlanMode", tool_input=tool_input),
            socket_response={"decision": "allow", "updatedInput": tool_input},
        )

        self.assertEqual(code, 0)
        decision = self.decision_from_stdout(stdout)
        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(decision["updatedInput"], tool_input)


if __name__ == "__main__":
    unittest.main()
