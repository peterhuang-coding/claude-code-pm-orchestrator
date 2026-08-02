#!/usr/bin/env python3
"""Tests for Feishu-to-Claude command intake and execution."""

from __future__ import annotations

import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / ".claude" / "skills" / "pm-orchestrator" / "scripts"
sys.path.insert(0, str(SCRIPTS))

pm_feishu = importlib.import_module("pm_feishu")
inbound = importlib.import_module("pm_feishu_inbound")


def message_event(**overrides: object) -> dict[str, object]:
    event: dict[str, object] = {
        "type": "im.message.receive_v1",
        "chat_id": "oc_owner_chat",
        "chat_type": "group",
        "message_id": "om_message_1",
        "message_type": "text",
        "sender_id": "ou_owner",
        "sender_type": "user",
        "content": "/do 汇报所有项目当前状态",
        "create_time": "1785680000000",
    }
    event.update(overrides)
    return event


class InboundPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.previous_hub = os.environ.get("PM_HUB_HOME")
        os.environ["PM_HUB_HOME"] = self.temp.name
        pm_feishu.save_lark_channel(
            "oc_owner_chat",
            owner_open_id="ou_owner",
            boss_root="/Volumes/SanDisk2TB",
        )

    def tearDown(self) -> None:
        if self.previous_hub is None:
            os.environ.pop("PM_HUB_HOME", None)
        else:
            os.environ["PM_HUB_HOME"] = self.previous_hub
        self.temp.cleanup()

    def test_owner_text_in_configured_chat_is_queued(self) -> None:
        self.assertTrue(inbound.enqueue_inbound_event(message_event()))
        pending = inbound.pending_commands()
        self.assertEqual(1, len(pending))
        record = json.loads(pending[0].read_text(encoding="utf-8"))
        self.assertEqual("/do 汇报所有项目当前状态", record["content"])
        self.assertEqual("om_message_1", record["message_id"])

    def test_bot_message_is_ignored(self) -> None:
        self.assertFalse(
            inbound.enqueue_inbound_event(
                message_event(sender_type="bot", sender_id="ou_bot")
            )
        )

    def test_wrong_chat_is_ignored(self) -> None:
        self.assertFalse(
            inbound.enqueue_inbound_event(message_event(chat_id="oc_other"))
        )

    def test_wrong_user_is_ignored(self) -> None:
        self.assertFalse(
            inbound.enqueue_inbound_event(message_event(sender_id="ou_other"))
        )

    def test_empty_or_unsupported_message_is_ignored(self) -> None:
        self.assertFalse(inbound.enqueue_inbound_event(message_event(content="  ")))
        self.assertFalse(
            inbound.enqueue_inbound_event(
                message_event(message_id="om_image", message_type="image")
            )
        )

    def test_duplicate_message_id_is_queued_once(self) -> None:
        self.assertTrue(inbound.enqueue_inbound_event(message_event()))
        self.assertFalse(inbound.enqueue_inbound_event(message_event()))
        self.assertEqual(1, len(inbound.pending_commands()))

    def test_processed_and_failed_ids_are_not_requeued(self) -> None:
        self.assertTrue(inbound.enqueue_inbound_event(message_event()))
        pending = inbound.pending_commands()[0]
        inbound.mark_processed(pending, {"result": "done"})
        self.assertFalse(inbound.enqueue_inbound_event(message_event()))

        second = message_event(message_id="om_message_2")
        self.assertTrue(inbound.enqueue_inbound_event(second))
        inbound.mark_failed(inbound.pending_commands()[0], "failed")
        self.assertFalse(inbound.enqueue_inbound_event(second))


class RemoteClaudeSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.previous_hub = os.environ.get("PM_HUB_HOME")
        os.environ["PM_HUB_HOME"] = self.temp.name
        pm_feishu.save_lark_channel(
            "oc_owner_chat",
            owner_open_id="ou_owner",
            boss_root="/Volumes/SanDisk2TB",
        )

    def tearDown(self) -> None:
        if self.previous_hub is None:
            os.environ.pop("PM_HUB_HOME", None)
        else:
            os.environ["PM_HUB_HOME"] = self.previous_hub
        self.temp.cleanup()

    def result(self, text: str) -> mock.Mock:
        return mock.Mock(
            returncode=0,
            stdout=json.dumps({"type": "result", "result": text}),
            stderr="",
        )

    def test_first_command_creates_model_neutral_max_permission_session(self) -> None:
        runner = mock.Mock(return_value=self.result("portfolio ready"))

        output = inbound.execute_remote_command(
            "/do 汇报所有项目", runner=runner, executable="claude"
        )

        self.assertEqual("portfolio ready", output)
        command = runner.call_args.args[0]
        self.assertIn("--print", command)
        self.assertIn("--session-id", command)
        self.assertNotIn("--resume", command)
        self.assertEqual(
            "bypassPermissions", command[command.index("--permission-mode") + 1]
        )
        self.assertEqual("max", command[command.index("--effort") + 1])
        self.assertNotIn("--model", command)
        self.assertEqual("/Volumes/SanDisk2TB", runner.call_args.kwargs["cwd"])
        self.assertNotIn("PM_FEISHU_BOSS", runner.call_args.kwargs["env"])

    def test_second_command_resumes_same_session(self) -> None:
        runner = mock.Mock(
            side_effect=[self.result("first"), self.result("second")]
        )
        inbound.execute_remote_command("first command", runner=runner)
        session_id = inbound.load_remote_session()["session_id"]

        output = inbound.execute_remote_command("second command", runner=runner)

        self.assertEqual("second", output)
        command = runner.call_args.args[0]
        self.assertIn("--resume", command)
        self.assertEqual(session_id, command[command.index("--resume") + 1])
        self.assertNotIn("--session-id", command)

    def test_user_command_is_preserved_inside_remote_prompt(self) -> None:
        runner = mock.Mock(return_value=self.result("done"))
        inbound.execute_remote_command("回到 beer-lens 继续最高优先级任务", runner=runner)
        prompt = runner.call_args.args[0][-1]
        self.assertIn("回到 beer-lens 继续最高优先级任务", prompt)
        self.assertIn("authorized Feishu boss command", prompt)

    def test_failed_or_invalid_claude_result_raises_bounded_error(self) -> None:
        failed = mock.Mock(returncode=1, stdout="", stderr="provider unavailable")
        with self.assertRaisesRegex(RuntimeError, "provider unavailable"):
            inbound.execute_remote_command("run", runner=mock.Mock(return_value=failed))

        invalid = mock.Mock(returncode=0, stdout="not-json", stderr="")
        with self.assertRaisesRegex(RuntimeError, "invalid JSON"):
            inbound.execute_remote_command("run", runner=mock.Mock(return_value=invalid))


if __name__ == "__main__":
    unittest.main()
