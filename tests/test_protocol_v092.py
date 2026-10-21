import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from bridge.protocol import BridgeClient


class LegacyGame(threading.Thread):
    """Pre-1.89.1 bridge: answers ping without boot token or |END."""

    def __init__(self, data_dir):
        super().__init__(daemon=True)
        self.dir = Path(data_dir)
        self.stop = threading.Event()
        self.last_id = None

    def run(self):
        while not self.stop.is_set():
            try:
                text = (self.dir / "cmd.txt").read_text(encoding="utf-8")
            except OSError:
                time.sleep(0.005)
                continue
            text = text.rstrip("\r\n")
            if not text.endswith("|END"):
                time.sleep(0.005)
                continue
            parts = text[:-4].split("|")
            if len(parts) < 2 or parts[0] == self.last_id:
                time.sleep(0.005)
                continue
            self.last_id = parts[0]
            (self.dir / "resp.txt").write_text(
                f"{parts[0]}|OK|pong ddbridge 1.89.0", encoding="utf-8")
            time.sleep(0.005)


class LegacyPingTests(unittest.TestCase):
    def test_old_bridge_ping_still_parses(self):
        with tempfile.TemporaryDirectory() as td:
            game = LegacyGame(td)
            game.start()
            try:
                client = BridgeClient(td)
                pong = client.ping(timeout=1.0)
                self.assertIn("1.89.0", pong)
                self.assertEqual(client.bridge_version, "1.89.0")
                self.assertIsNone(client.boot_id)
            finally:
                game.stop.set()
                game.join(timeout=2)


class MutationHookTests(unittest.TestCase):
    def test_hook_fires_once_before_first_mutation_only(self):
        import test_protocol as tp  # FakeGame from the v0.91 suite
        with tempfile.TemporaryDirectory() as td:
            game = tp.FakeGame(td)
            game.start()
            try:
                client = BridgeClient(td)
                calls = []
                client.on_before_first_mutation = calls.append
                client.ping(timeout=2)
                self.assertEqual(calls, [])  # ping is read-only
                client.send("echo", "a", timeout=2)  # unknown to safety: mutating
                client.send("echo", "b", timeout=2)
                self.assertEqual(calls, ["echo"])  # exactly once
                self.assertEqual(len(client.history), 3)
            finally:
                game.stop.set()
                game.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
