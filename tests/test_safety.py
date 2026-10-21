import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from bridge import safety


class ClassificationTests(unittest.TestCase):
    def test_read_only_commands(self):
        for cmd in ("ping", "get_badges", "item_rows", "list_items",
                    "item_special_sweep", "wskill_probe"):
            self.assertFalse(safety.is_mutating(cmd), cmd)

    def test_mutating_commands(self):
        for cmd in ("set_badge", "fill_badges", "item_apply", "give_item",
                    "unlock_wskills", "warp_to_pin", "brand_new_command"):
            self.assertTrue(safety.is_mutating(cmd), cmd)


class SaveBackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.remote = root / "userdata" / "123" / "2054970" / "remote"
        self.remote.mkdir(parents=True)
        (self.remote / "data00-1.bin").write_bytes(b"save-bytes")
        self.config = root / "config"
        self.config.mkdir()
        env = mock.patch.dict(os.environ, {
            "ARISENS_SAVE_DIR": str(self.remote),
            "ARISENS_CONFIG_DIR": str(self.config),
        })
        env.start()
        self.addCleanup(env.stop)

    def test_backup_and_prune(self):
        dest = safety.backup_saves()
        self.assertIsNotNone(dest)
        self.assertEqual((Path(dest) / "data00-1.bin").read_bytes(),
                         b"save-bytes")
        self.assertEqual(len(safety.list_backups()), 1)

    def test_restore_roundtrip_with_pre_restore_backup(self):
        dest = safety.backup_saves()
        (self.remote / "data00-1.bin").write_bytes(b"corrupted")
        live, pre = safety.restore_backup(dest)
        self.assertEqual(Path(live), self.remote)
        self.assertEqual((self.remote / "data00-1.bin").read_bytes(),
                         b"save-bytes")
        self.assertIsNotNone(pre)  # the corrupted state was kept too

    def test_no_save_dir_returns_none(self):
        with mock.patch.dict(os.environ, {"ARISENS_SAVE_DIR": ""}):
            with mock.patch.object(safety, "_steam_roots", return_value=[]):
                self.assertIsNone(safety.backup_saves())


class CleanupAndBundleTests(unittest.TestCase):
    def test_cleanup_sidecars(self):
        with tempfile.TemporaryDirectory() as td:
            for name in ("items.txt", "abildump3.txt", "keep.txt"):
                Path(td, name).write_text("x")
            removed = safety.cleanup_sidecars(td)
            self.assertEqual(sorted(removed), ["abildump3.txt", "items.txt"])
            self.assertTrue(Path(td, "keep.txt").exists())

    def test_diagnostics_zip(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "diag.zip"
            log = Path(td) / "client.log"
            log.write_text("line1\nline2\n")
            safety.make_diagnostics_zip(
                str(out), versions={"client": "0.92"}, client=None,
                log_path=str(log))
            with zipfile.ZipFile(out) as z:
                names = z.namelist()
                self.assertIn("diagnostics.txt", names)
                self.assertIn("command_history.txt", names)
                self.assertIn("client.log", names)
                self.assertIn("client: 0.92",
                              z.read("diagnostics.txt").decode())


if __name__ == "__main__":
    unittest.main()
