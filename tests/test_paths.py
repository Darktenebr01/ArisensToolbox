import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bridge import game_path


class ConfigPathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = mock.patch.dict(
            os.environ, {"ARISENS_CONFIG_DIR": self.tmp.name})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.exe = Path(self.tmp.name) / "game folder" / "DD2.exe"
        self.exe.parent.mkdir(parents=True, exist_ok=True)
        self.exe.write_bytes(b"fake exe")

    def test_config_dir_uses_override(self):
        self.assertEqual(game_path.config_dir(), self.tmp.name)

    def test_set_get_and_clear(self):
        game_path.set_custom_exe(str(self.exe))
        self.assertEqual(game_path.get_custom_exe(), str(self.exe))
        self.assertTrue((Path(self.tmp.name) / "dd2_exe.txt").is_file())
        game_path.clear_custom_exe()
        self.assertIsNone(game_path.get_custom_exe())

    def test_missing_file_is_ignored(self):
        game_path.set_custom_exe(str(self.exe.with_name("missing.exe")))
        self.assertIsNone(game_path.get_custom_exe())

    def test_legacy_setting_is_migrated(self):
        legacy = Path(self.tmp.name) / "legacy-dd2_exe.txt"
        legacy.write_text(str(self.exe), encoding="utf-8")
        with mock.patch.object(game_path, "_legacy_exe_file",
                               return_value=str(legacy)):
            self.assertEqual(game_path.get_custom_exe(), str(self.exe))
        self.assertTrue((Path(self.tmp.name) / "dd2_exe.txt").is_file())


if __name__ == "__main__":
    unittest.main()
