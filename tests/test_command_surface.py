"""Cross-checks between the Python client and ddbridge.lua.

Encodes the external review's manual verification as CI tests: every
read-only command really exists in the Lua, every command the UI sends
exists in the Lua, and the respawn override stays gated on its flag.
"""
import re
import unittest
from pathlib import Path

from bridge import safety

ROOT = Path(__file__).resolve().parents[1]
LUA = (ROOT / "bridge" / "data" / "ddbridge.lua").read_text(encoding="utf-8")


def lua_commands():
    return set(re.findall(r"COMMANDS\.([A-Za-z0-9_]+)\s*=", LUA))


def client_sends():
    cmds = set()
    for path in (ROOT / "ui").rglob("*.py"):
        text = path.read_text(encoding="utf-8")
        cmds.update(re.findall(r"""\.send\(\s*["']([A-Za-z0-9_]+)["']""", text))
        cmds.update(re.findall(r"""do_respawn|send\(\s*["']ping""", text))
    return {c for c in cmds if c not in ("do_respawn",)}


class CommandSurfaceTests(unittest.TestCase):
    def test_read_only_set_exists_in_lua(self):
        missing = safety.READ_ONLY_COMMANDS - lua_commands()
        self.assertEqual(missing, set())

    def test_every_ui_send_exists_in_lua(self):
        missing = client_sends() - lua_commands()
        self.assertEqual(missing, set())

    def test_timeskip_probe_not_read_only(self):
        # It installs capture hooks in the game process; not side-effect free.
        self.assertTrue(safety.is_mutating("timeskip_probe"))

    def test_itemnames_never_cleaned(self):
        # The Lua persists custom item names in itemnames.txt.
        self.assertNotIn("itemnames.txt", safety.SIDECAR_DUMPS)

    def test_respawn_hooks_gated_on_active_flag(self):
        gates = LUA.count("if not RESPAWN.active then return retval end")
        self.assertEqual(gates, 2)  # repop-time hook + repop-day hook
        self.assertIn("active = false, is_boss = false", LUA)
        self.assertIn("RESPAWN.active = true", LUA)   # respawn_set
        self.assertIn("RESPAWN.active = false", LUA)  # respawn_reset

    def test_core_skill_unlearn_commands(self):
        # Unlearning removes ids from SkillContext.EnableNormalSkills; the
        # commands must exist and keep the read-back path.
        cmds = lua_commands()
        self.assertIn("disable_nskill", cmds)
        self.assertIn("disable_nskills", cmds)
        self.assertIn("EnableNormalSkills", LUA)
        self.assertIn("isNormalSkillEnable", LUA)

    def test_weapon_skill_unlearn_commands(self):
        # Weapon skills are entries in EnabledCustomSkills, so unlearning
        # removes entries and verifies with isCustomSkillEnable.
        cmds = lua_commands()
        self.assertIn("disable_wskill", cmds)
        self.assertIn("disable_wskills", cmds)
        self.assertIn("EnabledCustomSkills", LUA)
        self.assertIn("isCustomSkillEnable", LUA)

    def test_give_item_bounds_in_lua(self):
        self.assertIn("qty > 9999", LUA)


if __name__ == "__main__":
    unittest.main()
