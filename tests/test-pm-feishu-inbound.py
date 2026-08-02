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


if __name__ == "__main__":
    unittest.main()
