import tempfile
import threading
import time
import unittest
from pathlib import Path

import test_protocol as tp
from bridge.protocol import BridgeClient, BridgeError, BridgeTimeout


class SessionChangeTests(unittest.TestCase):
    def test_new_boot_token_resets_hook_and_fires_callback(self):
        with tempfile.TemporaryDirectory() as td:
            game = tp.FakeGame(td, boot="boot-1")
            game.start()
            try:
                client = BridgeClient(td)
                fired = []
                client.on_session_changed = lambda: fired.append(True)
                client.ping(timeout=2)
                self.assertEqual(fired, [])  # first token is not a change
                client._mutation_hook_done = True
                game.boot = "boot-2"  # game "restarted"
                client.ping(timeout=2)
                self.assertEqual(fired, [True])
                self.assertFalse(client._mutation_hook_done)
                self.assertEqual(client.boot_id, "boot-2")
            finally:
                game.stop.set()
                game.join(timeout=2)


class HookAbortTests(unittest.TestCase):
    def test_hook_error_aborts_command_and_stays_armed(self):
        with tempfile.TemporaryDirectory() as td:
            game = tp.FakeGame(td)
            game.start()
            try:
                client = BridgeClient(td)
                client.ping(timeout=2)

                def bad_hook(_cmd):
                    raise BridgeError("backup failed")

                client.on_before_first_mutation = bad_hook
                with self.assertRaises(BridgeError):
                    client.send("echo", "x", timeout=2)
                seen_cmds = [c for c, _a in game.seen]
                self.assertNotIn("echo", seen_cmds)  # never written
                self.assertFalse(client._mutation_hook_done)

                client.on_before_first_mutation = lambda _cmd: None
                self.assertEqual(client.send("echo", "x", timeout=2), "echo:x")
                self.assertTrue(client._mutation_hook_done)
            finally:
                game.stop.set()
                game.join(timeout=2)


class TimeoutCleanupTests(unittest.TestCase):
    def test_mutating_timeout_deletes_cmd_and_warns(self):
        with tempfile.TemporaryDirectory() as td:
            game = tp.FakeGame(td)
            game.start()
            client = BridgeClient(td)
            client.ping(timeout=2)
            game.stop.set()
            game.join(timeout=2)  # game "minimized/crashed": no answers now
            with self.assertRaises(BridgeTimeout) as ctx:
                client.send("set_badge", "PB001", "5", timeout=0.6)
            self.assertIn("may or may not have run", str(ctx.exception))
            self.assertFalse((Path(td) / "cmd.txt").exists())

    def test_readonly_timeout_leaves_cmd_file(self):
        with tempfile.TemporaryDirectory() as td:
            game = tp.FakeGame(td)
            game.start()
            client = BridgeClient(td)
            client.ping(timeout=2)
            game.stop.set()
            game.join(timeout=2)
            with self.assertRaises(BridgeTimeout):
                client.send("get_badges", timeout=0.6)
            self.assertTrue((Path(td) / "cmd.txt").exists())


class TryPingTests(unittest.TestCase):
    def test_try_ping_skips_while_command_in_flight(self):
        with tempfile.TemporaryDirectory() as td:
            game = tp.FakeGame(td)
            game.start()
            client = BridgeClient(td)
            client.ping(timeout=2)
            game.stop.set()
            game.join(timeout=2)

            def long_send():
                try:
                    client.send("get_info", timeout=3)
                except BridgeError:
                    pass

            worker = threading.Thread(target=long_send, daemon=True)
            worker.start()
            time.sleep(0.3)  # let it take the send lock
            started = time.monotonic()
            self.assertIs(client.try_ping(timeout=1), False)
            self.assertLess(time.monotonic() - started, 1.0)
            worker.join(timeout=5)

    def test_try_ping_none_when_game_silent(self):
        with tempfile.TemporaryDirectory() as td:
            client = BridgeClient(td)
            self.assertIsNone(client.try_ping(timeout=0.4))


if __name__ == "__main__":
    unittest.main()
