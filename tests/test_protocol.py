import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from bridge.protocol import BridgeClient, BridgeError, BridgeTimeout
from version import BRIDGE_VERSION


class FakeGame(threading.Thread):
    """Tiny ddbridge emulator: reads cmd.txt and writes a complete resp.txt."""

    def __init__(self, data_dir, boot="boot-1"):
        super().__init__(daemon=True)
        self.data_dir = Path(data_dir)
        self.cmd = self.data_dir / "cmd.txt"
        self.resp = self.data_dir / "resp.txt"
        self.boot = boot
        self.stop = threading.Event()
        self.last_id = None
        self.seen = []

    def _write(self, body):
        tmp = self.resp.with_suffix(".fake.tmp")
        tmp.write_text(body, encoding="utf-8")
        # Windows can hold resp.txt open while the client reads it; retry
        # instead of dropping the response and making the test flaky.
        for _ in range(20):
            try:
                os.replace(tmp, self.resp)
                return
            except OSError:
                time.sleep(0.002)
        try:
            tmp.unlink()
        except OSError:
            pass

    def run(self):
        while not self.stop.is_set():
            try:
                text = self.cmd.read_text(encoding="utf-8")
            except OSError:
                time.sleep(0.005)
                continue
            text = text.rstrip("\r\n")
            if not text.endswith("|END"):
                time.sleep(0.005)
                continue
            parts = text[:-4].split("|")
            if len(parts) < 2:
                time.sleep(0.005)
                continue
            cmd_id, command = parts[0], parts[1]
            if cmd_id == self.last_id:
                time.sleep(0.005)
                continue
            self.last_id = cmd_id
            self.seen.append((command, parts[2:]))
            token = parts[-1] if parts[-1].startswith("B:") else None
            if command == "ping":
                self._write(
                    f"{cmd_id}|OK|pong ddbridge {BRIDGE_VERSION} boot={self.boot}|END")
            elif token != f"B:{self.boot}":
                self._write(f"{cmd_id}|ERR|STALE_SESSION|END")
            elif command == "echo":
                args = parts[2:-1] if token else parts[2:]
                self._write(f"{cmd_id}|OK|echo:{','.join(args)}|END")
            else:
                self._write(f"{cmd_id}|OK|ok|END")
            time.sleep(0.005)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.game = FakeGame(self.dir)
        self.game.start()
        self.client = BridgeClient(self.dir)

    def tearDown(self):
        self.game.stop.set()
        self.game.join(timeout=2)
        self.tmp.cleanup()

    def test_ping_exposes_boot_token(self):
        pong = self.client.ping(timeout=2)
        self.assertIn(f"pong ddbridge {BRIDGE_VERSION}", pong)
        self.assertEqual(self.client.boot_id, "boot-1")

    def test_send_carries_token_and_returns_payload(self):
        self.client.ping(timeout=2)
        self.assertEqual(self.client.send("echo", "a", "b", timeout=2), "echo:a,b")
        self.assertEqual(self.game.seen[-1][0], "echo")
        self.assertEqual(self.game.seen[-1][1][-1], "B:boot-1")

    def test_stale_token_triggers_reping_and_retry(self):
        self.client.ping(timeout=2)
        self.game.boot = "boot-2"
        self.assertEqual(self.client.send("echo", "x", timeout=2), "echo:x")
        self.assertEqual(self.client.boot_id, "boot-2")

    def test_timeout(self):
        # No fake game on this directory.
        with tempfile.TemporaryDirectory() as empty:
            client = BridgeClient(empty)
            with self.assertRaises(BridgeTimeout):
                client.ping(timeout=0.2)

    def test_cmd_file_is_cleared_on_start(self):
        path = Path(self.dir) / "cmd.txt"
        path.write_text("old|give_item|1|1|0|END\n", encoding="utf-8")
        BridgeClient(self.dir)
        self.assertFalse(path.exists())

    def test_complete_response_requires_sentinel(self):
        path = Path(self.dir) / "resp.txt"
        path.write_text("abc|OK|payload|END", encoding="utf-8")
        self.assertEqual(self.client._read_resp(), ("abc", "OK", "payload"))
        path.write_text("abc|OK|truncated", encoding="utf-8")
        self.assertEqual(self.client._read_resp(), (None, None, None))

    def test_argument_sanitization(self):
        with self.assertRaises(BridgeError):
            self.client._arg_text("a|b")
        with self.assertRaises(BridgeError):
            self.client._arg_text("a\nb")

    def test_command_line_shape(self):
        line = self.client._command_line("id", "echo", ["a", "b"], "boot")
        self.assertEqual(line, "id|echo|a|b|B:boot|END\n")


if __name__ == "__main__":
    unittest.main()
