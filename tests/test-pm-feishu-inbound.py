#!/usr/bin/env python3
"""Tests for Feishu-to-Claude command intake and execution."""

from __future__ import annotations

import importlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
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

    def process(self, text: str) -> mock.Mock:
        process = mock.Mock()
        process.communicate.return_value = (
            json.dumps({"type": "result", "result": text}),
            "",
        )
        process.returncode = 0
        return process

    def test_first_command_creates_model_neutral_max_permission_session(self) -> None:
        runner = mock.Mock(return_value=self.process("portfolio ready"))

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
            side_effect=[self.process("first"), self.process("second")]
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
        runner = mock.Mock(return_value=self.process("done"))
        inbound.execute_remote_command("回到 beer-lens 继续最高优先级任务", runner=runner)
        prompt = runner.call_args.args[0][-1]
        self.assertIn("回到 beer-lens 继续最高优先级任务", prompt)
        self.assertIn("authorized Feishu boss command", prompt)

    def test_failed_or_invalid_claude_result_raises_bounded_error(self) -> None:
        failed = mock.Mock(returncode=1)
        failed.communicate.return_value = ("", "provider unavailable")
        with self.assertRaisesRegex(RuntimeError, "provider unavailable"):
            inbound.execute_remote_command("run", runner=mock.Mock(return_value=failed))

        invalid = mock.Mock(returncode=0)
        invalid.communicate.return_value = ("not-json", "")
        with self.assertRaisesRegex(RuntimeError, "invalid JSON"):
            inbound.execute_remote_command("run", runner=mock.Mock(return_value=invalid))

    def test_stale_creating_session_rotates_identifier(self) -> None:
        stale_id = "11111111-1111-4111-8111-111111111111"
        pm_feishu._atomic_json(
            pm_feishu.runtime_dir() / inbound.REMOTE_SESSION_FILE,
            {"session_id": stale_id, "phase": "creating"},
        )
        runner = mock.Mock(return_value=self.process("recovered"))

        inbound.execute_remote_command("continue", runner=runner)

        command = runner.call_args.args[0]
        new_id = command[command.index("--session-id") + 1]
        self.assertNotEqual(stale_id, new_id)
        self.assertEqual("ready", inbound.load_remote_session()["phase"])

    def test_stop_event_terminates_active_claude_process(self) -> None:
        stop_event = threading.Event()
        process = mock.Mock(returncode=None)

        def communicate(timeout=None):
            if process.terminate.called:
                process.returncode = -15
                return "", "terminated"
            if timeout is not None:
                raise subprocess.TimeoutExpired("claude", timeout)
            return "", ""

        process.communicate.side_effect = communicate
        process.wait.return_value = -15
        runner = mock.Mock(return_value=process)
        errors = []

        thread = threading.Thread(
            target=lambda: self._capture_remote_error(
                errors, stop_event, runner
            )
        )
        thread.start()
        time.sleep(0.05)
        stop_event.set()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        process.terminate.assert_called_once()
        self.assertTrue(errors)
        self.assertIsInstance(errors[0], inbound.RemoteCommandCancelled)

    @staticmethod
    def _capture_remote_error(errors, stop_event, runner) -> None:
        try:
            inbound.execute_remote_command(
                "long task", stop_event=stop_event, runner=runner
            )
        except Exception as error:
            errors.append(error)


class InboundExecutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.previous_hub = os.environ.get("PM_HUB_HOME")
        os.environ["PM_HUB_HOME"] = self.temp.name
        pm_feishu.save_lark_channel(
            "oc_owner_chat",
            owner_open_id="ou_owner",
            boss_root="/Volumes/SanDisk2TB",
        )
        pm_feishu.set_enabled(True)
        inbound.enqueue_inbound_event(message_event())

    def tearDown(self) -> None:
        if self.previous_hub is None:
            os.environ.pop("PM_HUB_HOME", None)
        else:
            os.environ["PM_HUB_HOME"] = self.previous_hub
        self.temp.cleanup()

    def test_pending_command_is_acknowledged_executed_and_replied(self) -> None:
        executor = mock.Mock(return_value="所有项目状态已汇总。")
        replier = mock.Mock(
            side_effect=[
                {"ok": True, "data": {"message_id": "om_ack"}},
                {"ok": True, "data": {"message_id": "om_result"}},
            ]
        )

        self.assertEqual(
            (1, 0),
            inbound.process_pending_once(executor=executor, replier=replier),
        )

        executor.assert_called_once_with("/do 汇报所有项目当前状态")
        self.assertEqual("om_message_1", replier.call_args_list[0].args[0])
        self.assertIn("已收到", replier.call_args_list[0].args[1])
        self.assertIn("所有项目状态已汇总", replier.call_args_list[1].args[1])
        self.assertEqual([], inbound.pending_commands())
        self.assertEqual(1, len(list(inbound.inbound_dirs()["processed"].glob("*.json"))))

    def test_interrupted_running_command_is_not_executed_again(self) -> None:
        pending = inbound.pending_commands()[0]
        running = inbound.claim_pending(pending)
        executor = mock.Mock()
        replier = mock.Mock(return_value={"ok": True})

        self.assertEqual(
            (0, 1),
            inbound.process_pending_once(executor=executor, replier=replier),
        )

        executor.assert_not_called()
        self.assertIn("不会自动重试", replier.call_args.args[1])
        self.assertEqual(1, len(list(inbound.inbound_dirs()["failed"].glob("*.json"))))
        self.assertFalse(running.exists())

    def test_reply_failure_retries_reply_without_reexecuting(self) -> None:
        executor = mock.Mock(return_value="已完成。")
        replier = mock.Mock(
            side_effect=[{"ok": True}, RuntimeError("reply unavailable")]
        )

        self.assertEqual(
            (0, 1),
            inbound.process_pending_once(executor=executor, replier=replier),
        )
        running = list(inbound.inbound_dirs()["running"].glob("*.json"))
        self.assertEqual(1, len(running))
        record = json.loads(running[0].read_text(encoding="utf-8"))
        self.assertEqual("reply_pending", record["phase"])
        self.assertEqual("已完成。", record["result"])

        retry_replier = mock.Mock(return_value={"ok": True})
        self.assertEqual(
            (1, 0),
            inbound.process_pending_once(
                executor=executor, replier=retry_replier
            ),
        )
        executor.assert_called_once()
        retry_replier.assert_called_once_with("om_message_1", "已完成。")

    def test_failed_command_replies_and_moves_to_failed(self) -> None:
        executor = mock.Mock(side_effect=RuntimeError("provider unavailable"))
        replier = mock.Mock(return_value={"ok": True})

        self.assertEqual(
            (0, 1),
            inbound.process_pending_once(executor=executor, replier=replier),
        )

        self.assertIn("provider unavailable", replier.call_args_list[-1].args[1])
        self.assertEqual(1, len(list(inbound.inbound_dirs()["failed"].glob("*.json"))))

    def test_disabled_gateway_leaves_inbound_queue_untouched(self) -> None:
        pm_feishu.set_enabled(False)
        executor = mock.Mock()
        replier = mock.Mock()
        self.assertEqual(
            (0, 0),
            inbound.process_pending_once(executor=executor, replier=replier),
        )
        executor.assert_not_called()
        replier.assert_not_called()
        self.assertEqual(1, len(inbound.pending_commands()))

    def test_event_line_queues_valid_json_and_ignores_invalid_json(self) -> None:
        inbound.pending_commands()[0].unlink()
        self.assertFalse(inbound.handle_event_line("not-json"))
        self.assertTrue(
            inbound.handle_event_line(json.dumps(message_event(), ensure_ascii=False))
        )


class FakeEventProcess:
    def __init__(self, stdout: str, stderr: str) -> None:
        self.stdout = io.StringIO(stdout)
        self.stderr = io.StringIO(stderr)
        self.stdin = io.StringIO()
        self.returncode = None
        self.terminated = False

    def poll(self):
        return self.returncode

    def wait(self, timeout=None) -> int:
        self.returncode = 0
        return 0

    def terminate(self) -> None:
        self.terminated = True
        self.returncode = 0


class LarkEventListenerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.previous_hub = os.environ.get("PM_HUB_HOME")
        os.environ["PM_HUB_HOME"] = self.temp.name
        pm_feishu.save_lark_channel(
            "oc_owner_chat",
            owner_open_id="ou_owner",
            boss_root="/Volumes/SanDisk2TB",
        )
        pm_feishu.set_enabled(True)

    def tearDown(self) -> None:
        if self.previous_hub is None:
            os.environ.pop("PM_HUB_HOME", None)
        else:
            os.environ["PM_HUB_HOME"] = self.previous_hub
        self.temp.cleanup()

    def test_listener_waits_for_ready_and_queues_ndjson_event(self) -> None:
        process = FakeEventProcess(
            json.dumps(message_event(), ensure_ascii=False) + "\n",
            "[event] ready event_key=im.message.receive_v1\n",
        )
        popen = mock.Mock(return_value=process)

        received = inbound.run_lark_listener(threading.Event(), popen=popen)

        self.assertEqual(1, received)
        self.assertEqual(1, len(inbound.pending_commands()))
        command = popen.call_args.args[0]
        self.assertEqual("event", command[1])
        self.assertIn("im.message.receive_v1", command)
        self.assertTrue(process.stdin.closed)

    def test_listener_rejects_stream_without_ready_marker(self) -> None:
        process = FakeEventProcess("", "connection failed\n")
        with self.assertRaisesRegex(RuntimeError, "ready"):
            inbound.run_lark_listener(
                threading.Event(), popen=mock.Mock(return_value=process)
            )

    def test_listener_stop_before_ready_exits_without_startup_error(self) -> None:
        process = FakeEventProcess("", "")
        stop_event = threading.Event()
        stop_event.set()

        received = inbound.run_lark_listener(
            stop_event, popen=mock.Mock(return_value=process)
        )

        self.assertEqual(0, received)
        self.assertTrue(process.terminated or process.stdin.closed)

    def test_listener_drains_stderr_after_ready_marker(self) -> None:
        stderr = "".join(
            [
                "[event] ready event_key=im.message.receive_v1\n",
                "post-ready diagnostic\n",
            ]
        )
        process = FakeEventProcess("", stderr)

        inbound.run_lark_listener(
            threading.Event(), popen=mock.Mock(return_value=process)
        )

        self.assertEqual(len(stderr), process.stderr.tell())
        self.assertEqual("offline", inbound.listener_runtime_status())

    def test_cloud_off_ignores_new_event_lines(self) -> None:
        pm_feishu.set_enabled(False)
        self.assertFalse(
            inbound.handle_event_line(json.dumps(message_event(), ensure_ascii=False))
        )
        self.assertEqual([], inbound.pending_commands())


if __name__ == "__main__":
    unittest.main()
