import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LUA = ROOT / "bridge" / "data" / "ddbridge.lua"


class LuaBridgeTests(unittest.TestCase):
    def test_session_guard_and_sentinel_are_present(self):
        text = LUA.read_text(encoding="utf-8")
        self.assertIn("local BOOT =", text)
        self.assertIn('"B:" .. BOOT', text)
        self.assertIn("STALE_SESSION", text)
        self.assertIn('|END', text)
        self.assertIn("local function write_resp", text)

    def test_lua_syntax_if_interpreter_available(self):
        luac = shutil.which("luac") or shutil.which("luac5.4")
        if not luac:
            self.skipTest("luac is not installed")
        proc = subprocess.run([luac, "-p", str(LUA)],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
