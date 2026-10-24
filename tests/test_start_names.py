"""v0.96 regression: the v0.93 restructure dropped three names that
ui/tabs/connection.py still used (game_running, installed_lua_version,
DD2_STEAM_APPID), so Start died with 'NameError: name game_running is
not defined' (user's client.log, 2026-10-22). Guard the wiring."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bridge import game_path


class TestStartNames(unittest.TestCase):
    def test_connection_module_resolves_names(self):
        from ui.tabs import connection
        self.assertTrue(callable(connection.game_running))
        self.assertTrue(callable(connection.installed_lua_version))
        self.assertEqual(connection.DD2_STEAM_APPID, "2054970")

    def test_game_running_returns_bool_without_game(self):
        # No tasklist on this host -> exception path -> False, not a crash.
        self.assertIs(game_path.game_running(), False)

    def test_installed_lua_version_parses_header(self):
        with tempfile.NamedTemporaryFile(
                "w", suffix=".lua", delete=False) as f:
            f.write("-- ddbridge.lua  v1.89.4  (protocol v2)\n")
            path = f.name
        try:
            self.assertEqual(game_path.installed_lua_version(path), "1.89.4")
        finally:
            os.unlink(path)

    def test_installed_lua_version_missing_file(self):
        self.assertIsNone(
            game_path.installed_lua_version("/nonexistent/ddbridge.lua"))


if __name__ == "__main__":
    unittest.main()
