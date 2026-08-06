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

    # GW-413 --------------------------------------------------------------
    # Ghostwire is complimentary, never a driver: if it is absent, broken, or
    # cannot show a request, the terminal must behave exactly as if Ghostwire
    # were never installed. So the hook denies for exactly one reason — a person
    # clicked Deny in the notch — and steps aside for every other outcome.
    #
    # This inverts what PR #77 asserted here. Fail-closed was defended as "a tool
    # nobody saw shouldn't run unseen", but Ghostwire is not the permission
    # boundary — the agent's own prompt is, and it still renders. Denying bought
    # no safety and cost the user their turn: quitting the app denied every tool
    # call in flight (GW-408), and a 27-in-7-days correlation miss rate denied
    # tools nobody ever looked at.

    def test_only_an_explicit_human_denial_produces_any_output(self):
        stepped_aside = [
            (None, "no reply at all — app down, socket gone, reply unparseable"),
            ({}, "a reply carrying no decision"),
            ({"decision": "ask"}, "the app explicitly handing the gate back"),
            ({"decision": "shrug"}, "a decision this hook does not recognise"),
        ]
        for response, why in stepped_aside:
            with self.subTest(why=why):
                code, stdout = self.run_main(self.permission_payload(), socket_response=response)
                self.assertEqual(code, 0, f"{why}: a nonzero exit reads as a block")
                self.assertEqual(
                    stdout, "",
                    f"{why}: any output at all overrides the agent's own prompt",
                )

        code, stdout = self.run_main(
            self.permission_payload(), socket_response={"decision": "deny"}
        )
        self.assertEqual(code, 0)
        self.assertEqual(self.decision_from_stdout(stdout)["behavior"], "deny")

    def test_the_one_denial_is_worded_as_the_users_own(self):
        _, stdout = self.run_main(self.permission_payload(), socket_response={"decision": "deny"})

        message = self.decision_from_stdout(stdout)["message"]
        # The agent reads this string. It is only ever written when a person
        # clicked Deny, so it must say so plainly.
        self.assertIn("Denied by you in Ghostwire", message)

    def test_malformed_hook_input_steps_aside(self):
        stdin = io.StringIO("{ this is not json")
        stdout = io.StringIO()
        with patch.object(sys, "stdin", stdin), patch("sys.stdout", stdout):
            with self.assertRaises(SystemExit) as exit_context:
                self.hook.main()

        self.assertEqual(exit_context.exception.code, 0,
                         "A payload we cannot parse is a gate we cannot show — not a verdict")
        self.assertEqual(stdout.getvalue(), "")

    def test_fail_closed_wording_is_gone_entirely(self):
        # The helper that produced "Blocked by Ghostwire" is deleted, not just
        # unreferenced. Leaving it invites the next reader to call it.
        self.assertFalse(
            hasattr(self.hook, "fail_closed_message"),
            "Ghostwire no longer has a non-human denial to word",
        )

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
