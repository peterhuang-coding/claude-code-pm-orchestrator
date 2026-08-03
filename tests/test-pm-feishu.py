#!/usr/bin/env python3
"""Unit tests for the Claude Feishu gateway core."""

from __future__ import annotations

import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / ".claude" / "skills" / "pm-orchestrator" / "scripts"
sys.path.insert(0, str(SCRIPTS))

pm_feishu = importlib.import_module("pm_feishu")


def stop_event(session_id: str, message: str = "Work complete.") -> dict[str, object]:
    return {
        "hook_event_name": "Stop",
        "session_id": session_id,
        "cwd": "/Volumes/SanDisk2TB",
        "last_assistant_message": message,
    }


class FeishuGatewayCoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.previous_hub = os.environ.get("PM_HUB_HOME")
        os.environ["PM_HUB_HOME"] = self.temp.name

    def tearDown(self) -> None:
        if self.previous_hub is None:
            os.environ.pop("PM_HUB_HOME", None)
        else:
            os.environ["PM_HUB_HOME"] = self.previous_hub
        self.temp.cleanup()

    def test_state_defaults_off_and_persists(self) -> None:
        self.assertFalse(pm_feishu.load_state()["enabled"])
        state = pm_feishu.set_enabled(True)
        self.assertTrue(state["enabled"])
        self.assertTrue(pm_feishu.load_state()["enabled"])

    def test_only_active_boss_stop_is_queued(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")

        self.assertTrue(pm_feishu.enqueue_hook_event(stop_event("boss-1")))
        self.assertFalse(pm_feishu.enqueue_hook_event(stop_event("worker-1")))
        self.assertEqual(1, len(pm_feishu.pending_events()))

    def test_disabled_mode_does_not_queue_stop(self) -> None:
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        self.assertFalse(pm_feishu.enqueue_hook_event(stop_event("boss-1")))
        self.assertEqual([], pm_feishu.pending_events())

    def test_disabled_mode_does_not_deliver_existing_queue(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        self.assertTrue(pm_feishu.enqueue_hook_event(stop_event("boss-1")))
        pm_feishu.set_enabled(False)
        with mock.patch.object(pm_feishu, "send_payload") as sender:
            self.assertEqual((0, 0), pm_feishu.deliver_pending())
        sender.assert_not_called()

    def test_turning_off_during_drain_stops_remaining_messages(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        self.assertTrue(pm_feishu.enqueue_hook_event(stop_event("boss-1", "first")))
        self.assertTrue(pm_feishu.enqueue_hook_event(stop_event("boss-1", "second")))

        def send_then_disable(*_args, **_kwargs):
            pm_feishu.set_enabled(False)
            return {"code": 0}

        with mock.patch.object(
            pm_feishu, "send_payload", side_effect=send_then_disable
        ) as sender:
            delivered, failed = pm_feishu.deliver_pending()
        self.assertEqual((1, 0), (delivered, failed))
        self.assertEqual(1, sender.call_count)
        self.assertEqual(1, len(pm_feishu.pending_events()))

    def test_filesystem_error_during_delivery_is_bounded(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        self.assertTrue(pm_feishu.enqueue_hook_event(stop_event("boss-1")))
        with mock.patch.object(
            pm_feishu, "send_payload", return_value={"code": 0}
        ):
            with mock.patch.object(
                pm_feishu, "mark_delivered", side_effect=OSError("disk unavailable")
            ):
                self.assertEqual((0, 1), pm_feishu.deliver_pending())
        self.assertEqual(1, len(pm_feishu.pending_events()))

    def test_duplicate_stop_is_queued_once(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        event = stop_event("boss-1", "same response")

        self.assertTrue(pm_feishu.enqueue_hook_event(event))
        self.assertFalse(pm_feishu.enqueue_hook_event(event))
        self.assertEqual(1, len(pm_feishu.pending_events()))

    def test_same_text_from_different_transcript_revisions_is_not_dropped(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        transcript = Path(self.temp.name) / "session.jsonl"
        transcript.write_text("first\n", encoding="utf-8")
        event = stop_event("boss-1", "same response")
        event["transcript_path"] = str(transcript)
        self.assertTrue(pm_feishu.enqueue_hook_event(event))

        transcript.write_text("first\nsecond\n", encoding="utf-8")
        self.assertTrue(pm_feishu.enqueue_hook_event(event))
        self.assertEqual(2, len(pm_feishu.pending_events()))

    def test_exact_switch_phrases_only(self) -> None:
        self.assertEqual(True, pm_feishu.apply_switch_phrase("我现在外出了"))
        self.assertTrue(pm_feishu.load_state()["enabled"])
        self.assertIsNone(pm_feishu.apply_switch_phrase("也许我一会儿外出"))
        self.assertTrue(pm_feishu.load_state()["enabled"])
        self.assertEqual(False, pm_feishu.apply_switch_phrase("我回来了"))
        self.assertFalse(pm_feishu.load_state()["enabled"])
        self.assertEqual(False, pm_feishu.apply_switch_phrase("我没外出"))

    def test_message_payload_is_bounded_and_identifies_boss(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-session-123456", "/Volumes/SanDisk2TB")
        pm_feishu.enqueue_hook_event(stop_event("boss-session-123456", "中" * 30_000))
        event = json.loads(
            pm_feishu.pending_events()[0].read_text(encoding="utf-8")
        )

        payload = pm_feishu.format_feishu_payload(event)
        text = payload["content"]["text"]
        request_body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.assertLessEqual(len(request_body), 20_000)
        self.assertIn("boss-ses", text)
        self.assertIn("Claude", text)

    def test_message_identifies_registered_project_and_summary(self) -> None:
        config = Path(self.temp.name) / "config"
        config.mkdir()
        (config / "projects.tsv").write_text(
            "beer-lens\t/Volumes/SanDisk2TB/beer-lens\n",
            encoding="utf-8",
        )
        event = {
            "event": "Stop",
            "session_id": "boss-project",
            "created_at": "now",
            "last_assistant_message": "Beer Lens 发布流程修复完成\n测试全部通过。",
        }
        text = pm_feishu.format_feishu_payload(event)["content"]["text"]
        self.assertIn("项目：beer-lens", text)
        self.assertIn("摘要：Beer Lens 发布流程修复完成", text)

    def test_stale_pending_events_expire_instead_of_sending(self) -> None:
        pm_feishu.set_enabled(True)
        pm_feishu.bind_boss("boss-1", "/Volumes/SanDisk2TB")
        self.assertTrue(pm_feishu.enqueue_hook_event(stop_event("boss-1")))
        pending = pm_feishu.pending_events()[0]
        os.utime(pending, (1, 1))
        self.assertEqual(1, pm_feishu.expire_stale_events(max_age_seconds=1))
        self.assertEqual([], pm_feishu.pending_events())
        self.assertEqual(
            1, len(list((pm_feishu.runtime_dir() / "expired").glob("*.json")))
        )

    def test_lark_cli_channel_is_configured_without_webhook(self) -> None:
        pm_feishu.save_lark_channel("oc_test_channel")
        with mock.patch.object(
            pm_feishu.shutil, "which", return_value="/usr/bin/lark-cli"
        ):
            self.assertTrue(pm_feishu.is_configured())

    def test_lark_cli_channel_delivers_text_as_bot(self) -> None:
        pm_feishu.save_lark_channel("oc_test_channel")
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "ok": True,
                    "identity": "bot",
                    "data": {"message_id": "om_test"},
                }
            ),
            stderr="",
        )
        with mock.patch.object(
            pm_feishu.shutil, "which", return_value="/usr/bin/lark-cli"
        ):
            with mock.patch.object(
                pm_feishu.subprocess, "run", return_value=completed
            ) as runner:
                response = pm_feishu.send_text("hello from Claude", retries=1)

        self.assertTrue(response["ok"])
        command = runner.call_args.args[0]
        self.assertIn("+messages-send", command)
        self.assertEqual(
            "oc_test_channel", command[command.index("--chat-id") + 1]
        )
        self.assertEqual(
            "hello from Claude", command[command.index("--text") + 1]
        )

    def test_lark_cli_replies_to_source_message_as_bot(self) -> None:
        pm_feishu.save_lark_channel("oc_test_channel")
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {"ok": True, "identity": "bot", "data": {"message_id": "om_reply"}}
            ),
            stderr="",
        )
        with mock.patch.object(
            pm_feishu.shutil, "which", return_value="/usr/bin/lark-cli"
        ):
            with mock.patch.object(
                pm_feishu.subprocess, "run", return_value=completed
            ) as runner:
                response = pm_feishu.reply_text(
                    "om_source", "remote result", retries=1
                )

        self.assertTrue(response["ok"])
        command = runner.call_args.args[0]
        self.assertIn("+messages-reply", command)
        self.assertEqual("om_source", command[command.index("--message-id") + 1])
        self.assertEqual("remote result", command[command.index("--text") + 1])

    def test_invalid_lark_chat_id_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            pm_feishu.save_lark_channel("not-a-chat")

    def test_api_response_without_explicit_success_code_is_rejected(self) -> None:
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b'{"msg":"failure without code"}'

        with mock.patch.object(pm_feishu, "webhook_url", return_value="https://x"):
            with mock.patch.object(
                pm_feishu.urllib.request, "urlopen", return_value=Response()
            ):
                with self.assertRaises(RuntimeError):
                    pm_feishu.send_payload(
                        {"msg_type": "text", "content": {"text": "x"}},
                        retries=1,
                    )

    def test_only_one_gateway_process_lock_can_be_held(self) -> None:
        first = pm_feishu.acquire_gateway_lock()
        self.addCleanup(first.close)
        with self.assertRaises(RuntimeError):
            pm_feishu.acquire_gateway_lock()

    def run_hook(
        self,
        event: dict[str, object],
        *,
        boss: bool = False,
        launch_token: str = "",
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if boss:
            env["PM_FEISHU_BOSS"] = "1"
            if launch_token:
                env["PM_FEISHU_BOSS_LAUNCH_TOKEN"] = launch_token
        else:
            env.pop("PM_FEISHU_BOSS", None)
            env.pop("PM_FEISHU_BOSS_LAUNCH_TOKEN", None)
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "pm-feishu-hook.py")],
            input=json.dumps(event, ensure_ascii=False),
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_session_start_binds_only_explicit_boss(self) -> None:
        ordinary = self.run_hook(
            {
                "hook_event_name": "SessionStart",
                "session_id": "ordinary",
                "cwd": "/Volumes/SanDisk2TB",
            }
        )
        self.assertEqual(0, ordinary.returncode)
        self.assertIsNone(pm_feishu.load_boss()["session_id"])

        boss = self.run_hook(
            {
                "hook_event_name": "SessionStart",
                "session_id": "boss-2",
                "cwd": "/Volumes/SanDisk2TB",
            },
            boss=True,
        )
        self.assertEqual(0, boss.returncode)
        self.assertEqual("{}", boss.stdout.strip())
        self.assertEqual("boss-2", pm_feishu.load_boss()["session_id"])

    def test_hook_switches_and_queues_boss_response(self) -> None:
        self.run_hook(
            {
                "hook_event_name": "SessionStart",
                "session_id": "boss-3",
                "cwd": "/Volumes/SanDisk2TB",
            },
            boss=True,
        )
        enabled = self.run_hook(
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "boss-3",
                "cwd": "/Volumes/SanDisk2TB",
                "prompt": "我现在外出了",
            }
        )
        self.assertEqual(0, enabled.returncode)
        self.assertTrue(pm_feishu.load_state()["enabled"])

        stopped = self.run_hook(stop_event("boss-3", "Visible in Feishu"))
        self.assertEqual(0, stopped.returncode)
        self.assertEqual(1, len(pm_feishu.pending_events()))

        disabled = self.run_hook(
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "boss-3",
                "cwd": "/Volumes/SanDisk2TB",
                "prompt": "我回来了",
            }
        )
        self.assertEqual(0, disabled.returncode)
        self.assertFalse(pm_feishu.load_state()["enabled"])

    def test_same_boss_launch_token_cannot_be_hijacked_by_later_session(self) -> None:
        first = self.run_hook(
            {
                "hook_event_name": "SessionStart",
                "session_id": "visible-main",
                "cwd": "/Volumes/SanDisk2TB",
            },
            boss=True,
            launch_token="launch-a",
        )
        later = self.run_hook(
            {
                "hook_event_name": "SessionStart",
                "session_id": "background-worker",
                "cwd": "/Volumes/SanDisk2TB/project",
            },
            boss=True,
            launch_token="launch-a",
        )

        self.assertEqual(0, first.returncode)
        self.assertEqual(0, later.returncode)
        self.assertEqual("visible-main", pm_feishu.load_boss()["session_id"])
        self.assertEqual("launch-a", pm_feishu.load_boss()["launch_token"])

    def test_new_boss_launch_token_replaces_previous_visible_session(self) -> None:
        pm_feishu.bind_boss(
            "old-visible", "/Volumes/SanDisk2TB", launch_token="launch-old"
        )

        self.run_hook(
            {
                "hook_event_name": "SessionStart",
                "session_id": "new-visible",
                "cwd": "/Volumes/SanDisk2TB",
            },
            boss=True,
            launch_token="launch-new",
        )

        self.assertEqual("new-visible", pm_feishu.load_boss()["session_id"])

    def test_ordinary_session_cannot_toggle_away_mode(self) -> None:
        pm_feishu.bind_boss("boss-4", "/Volumes/SanDisk2TB")
        ordinary = self.run_hook(
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "worker-4",
                "cwd": "/Volumes/SanDisk2TB/project",
                "prompt": "我现在外出了",
            }
        )
        self.assertEqual(0, ordinary.returncode)
        self.assertFalse(pm_feishu.load_state()["enabled"])

    def test_invalid_hook_input_never_blocks_claude(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "pm-feishu-hook.py")],
            input="{broken",
            text=True,
            capture_output=True,
            env=os.environ.copy(),
            check=False,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual("{}", result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
