import re
import unittest
from pathlib import Path

from version import BRIDGE_MAJOR, BRIDGE_VERSION, CLIENT_VERSION

ROOT = Path(__file__).resolve().parent.parent


class VersionConsistencyTests(unittest.TestCase):
    def test_versions_are_sane(self):
        self.assertRegex(CLIENT_VERSION, r"^\d+\.\d+$")
        self.assertRegex(BRIDGE_VERSION, r"^\d+\.\d+\.\d+$")
        self.assertTrue(BRIDGE_VERSION.startswith(BRIDGE_MAJOR + "."))

    def test_bundled_version_file_matches(self):
        text = (ROOT / "bridge" / "data" / "version.txt").read_text(
            encoding="utf-8").strip()
        self.assertEqual(text, BRIDGE_VERSION)

    def test_lua_header_pong_and_log_match(self):
        lua = (ROOT / "bridge" / "data" / "ddbridge.lua").read_text(
            encoding="utf-8")
        header = re.search(r"ddbridge\.lua\s+v(\d+\.\d+\.\d+)", lua)
        pong = re.search(r"pong ddbridge (\d+\.\d+\.\d+)", lua)
        self.assertIsNotNone(header)
        self.assertIsNotNone(pong)
        self.assertEqual(header.group(1), BRIDGE_VERSION)
        self.assertEqual(pong.group(1), BRIDGE_VERSION)
        self.assertIn(f"v{BRIDGE_VERSION} ready", lua)

    def test_no_duplicate_version_constants(self):
        app = (ROOT / "ui" / "app.py").read_text(encoding="utf-8")
        conn = (ROOT / "ui" / "tabs" / "connection.py").read_text(
            encoding="utf-8")
        self.assertNotIn('CLIENT_VERSION = "', app)
        self.assertNotIn("EXPECTED_MAJOR =", conn)
        self.assertIn("from version import", app)
        self.assertIn("from version import", conn)


if __name__ == "__main__":
    unittest.main()
