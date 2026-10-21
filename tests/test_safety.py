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
                    "unlock_wskills", "warp_to_pin", "brand_new_command",
                    "timeskip_probe"):  # installs capture hooks in-game
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
        backups = safety.list_backups()
        regular = [b for b in backups if "pinned-" not in b]
        pinned = [b for b in backups if "pinned-" in b]
        self.assertEqual(len(regular), 1)
        self.assertEqual(len(pinned), 1)  # first backup is pinned (v0.93)

    def test_restore_roundtrip_with_pre_restore_backup(self):
        dest = safety.backup_saves()
        (self.remote / "data00-1.bin").write_bytes(b"corrupted")
        live, pre = safety.restore_backup(dest)
        self.assertEqual(Path(live), self.remote)
        self.assertEqual((self.remote / "data00-1.bin").read_bytes(),
                         b"save-bytes")
        self.assertIsNotNone(pre)  # the corrupted state was kept too

    def test_pinned_backup_survives_pruning(self):
        for _ in range(12):
            safety.backup_saves()
        backups = safety.list_backups()
        pinned = [b for b in backups if "pinned-" in b]
        regular = [b for b in backups if "pinned-" not in b]
        self.assertEqual(len(pinned), 1)
        self.assertEqual(len(regular), safety.MAX_BACKUPS)

    def test_restore_targets_the_backups_own_account(self):
        root = Path(self.tmp.name)
        remote_a = root / "userdata" / "111" / "2054970" / "remote"
        remote_b = root / "userdata" / "222" / "2054970" / "remote"
        for r in (remote_a, remote_b):
            r.mkdir(parents=True, exist_ok=True)
            (r / "data00-1.bin").write_bytes(b"save")
        dest = safety.backup_saves(remote=str(remote_a))
        self.assertTrue(dest.endswith("-111"))
        (remote_a / "data00-1.bin").write_bytes(b"corrupted-a")
        (remote_b / "data00-1.bin").write_bytes(b"live-b")
        with mock.patch.object(
                safety, "find_save_remote_dirs",
                return_value=[str(remote_b), str(remote_a)]):
            live, _pre = safety.restore_backup(dest)
        self.assertEqual(Path(live), remote_a)
        self.assertEqual((remote_a / "data00-1.bin").read_bytes(), b"save")
        self.assertEqual((remote_b / "data00-1.bin").read_bytes(), b"live-b")

    def test_restore_refuses_when_account_missing_and_ambiguous(self):
        root = Path(self.tmp.name)
        remote_a = root / "userdata" / "111" / "2054970" / "remote"
        remote_b = root / "userdata" / "222" / "2054970" / "remote"
        remote_c = root / "userdata" / "333" / "2054970" / "remote"
        for r in (remote_a, remote_b, remote_c):
            r.mkdir(parents=True, exist_ok=True)
            (r / "data00-1.bin").write_bytes(b"save")
        dest = safety.backup_saves(remote=str(remote_a))
        with mock.patch.object(
                safety, "find_save_remote_dirs",
                return_value=[str(remote_b), str(remote_c)]):
            with self.assertRaises(FileNotFoundError):
                safety.restore_backup(dest)

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


class CleanupTests(unittest.TestCase):
    def test_itemnames_survives_cleanup(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td, "itemnames.txt").write_text("names", encoding="utf-8")
            Path(td, "items.txt").write_text("dump", encoding="utf-8")
            removed = safety.cleanup_sidecars(td)
            self.assertEqual(removed, ["items.txt"])
            self.assertTrue(Path(td, "itemnames.txt").exists())


if __name__ == "__main__":
    unittest.main()
