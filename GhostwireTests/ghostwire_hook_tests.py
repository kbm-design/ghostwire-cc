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

    def test_permission_request_ask_response_fails_closed(self):
        code, stdout = self.run_main(self.permission_payload(), socket_response={"decision": "ask"})

        self.assertEqual(code, 0)
        decision = self.decision_from_stdout(stdout)
        self.assertEqual(decision["behavior"], "deny")

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
