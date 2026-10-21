"""Save protection + diagnostics helpers (v0.92).

Every headline feature of this app mutates persistent character state, and
DD2 saves are fragile. This module provides:

- ``find_save_remote_dirs()`` - locate Steam's DD2 save folders.
- ``backup_saves()`` / ``list_backups()`` / ``restore_backup()`` - timestamped
  copies under ``%LOCALAPPDATA%\\ArisensToolbox\\backups`` (last 10 kept).
- ``is_mutating(command)`` - protocol classification used to trigger the
  automatic backup before the first mutating command of a session.
- ``make_diagnostics_zip()`` - one-file bundle for bug reports.
- ``cleanup_sidecars()`` - remove probe/dump sidecar files from the data dir.
"""
import os
import re
import shutil
import sys
import time
import zipfile

from bridge.game_path import config_dir, APP_ID

# Commands that only read game state (getters, listers, read-only probes).
# Anything NOT in this set is treated as mutating (default-deny), so a new
# command gets save protection automatically.
READ_ONLY_COMMANDS = {
    "ping", "list_items", "list_enums", "list_pawns",
    "get_info", "get_rating", "get_fav", "get_arisen_name",
    "get_main_pawn_name", "get_augments", "get_badges", "get_core",
    "get_nstate", "get_wskills", "get_wstate",
    "item_get", "item_get_name", "item_get_element", "item_get_elem_store",
    "item_get_enh", "item_get_special", "item_get_stats", "item_rows",
    "item_totals", "item_owners", "dup_rows", "dup_owners",
    "jump_get", "movespeed_get", "respawn_get", "respawn_defaults",
    "eqmap_valid", "eqmap_build", "item_special_sweep",
    # probes/dumps write sidecar files + the REFramework log, never the save
    "badge_probe", "badge_probe2", "badge_probe3", "dup_probe",
    "probe_arisen", "probe_name", "item_name_diag", "item_type_probe",
    "item_special_probe", "item_element_probe", "item_equipdata_probe",
    "item_methods_probe", "item_weaponparam_probe", "abil_dump",
    "abil_dump2", "abil_dump3", "augment_dump", "core_dump",
    "item_stat_dump", "jump_probe", "timemgr_dump", "timeskip_probe",
    "timeskip_sig", "warp_probe", "wskill_probe", "wskill_detail",
    "wskill_enabled_dump", "eqability_probe", "eqability_probe2",
    "stat_search",
}

# Sidecar dump/probe files the cleanup command may delete from the data dir.
SIDECAR_DUMPS = [
    "items.txt", "enums.txt", "specialsweep.txt", "abildump.txt",
    "abildump2.txt", "abildump3.txt", "augdump.txt", "coredump.txt",
    "itemstatdump.txt", "wskill_info.txt", "wskill_detail.txt",
    "wskill_enabled.txt", "eqability.txt", "eqability2.txt",
    "badges.txt", "badgenames.txt", "timemgr.txt", "jumpdump.txt",
    "dupprobe.txt", "nameprobe.txt", "itemnames.txt",
]

MAX_BACKUPS = 10


def is_mutating(command):
    return command not in READ_ONLY_COMMANDS


# -- Steam save discovery -------------------------------------------------

def _steam_roots():
    roots = []
    env_override = os.environ.get("ARISENS_STEAM_DIR")
    if env_override:
        roots.append(env_override)
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                r"Software\Valve\Steam") as key:
                path, _ = winreg.QueryValueEx(key, "SteamPath")
                if path:
                    roots.append(path.replace("/", "\\"))
        except Exception:
            pass
    for var in ("%ProgramFiles(x86)%", "%ProgramFiles%"):
        p = os.path.expandvars(var)
        if p and "%" not in p:
            roots.append(os.path.join(p, "Steam"))
    # A library install (<root>\steamapps\common\Dragons Dogma 2) implies
    # the Steam root three levels up from the game folder.
    try:
        from bridge.game_path import find_game_dir
        game = find_game_dir()
        if game:
            up = os.path.dirname(os.path.dirname(os.path.dirname(game)))
            if os.path.basename(up).lower() == "steam" or \
                    os.path.isdir(os.path.join(up, "userdata")):
                roots.append(up)
    except Exception:
        pass
    seen, out = set(), []
    for r in roots:
        if r and os.path.isdir(r) and r.lower() not in seen:
            seen.add(r.lower())
            out.append(r)
    return out


def find_save_remote_dirs():
    """All ``userdata/<id>/2054970/remote`` folders that actually exist.

    Tests/users may point ``ARISENS_SAVE_DIR`` straight at a remote folder.
    """
    direct = os.environ.get("ARISENS_SAVE_DIR")
    if direct and os.path.isdir(direct):
        return [direct]
    found = []
    for root in _steam_roots():
        userdata = os.path.join(root, "userdata")
        if not os.path.isdir(userdata):
            continue
        try:
            accounts = sorted(os.listdir(userdata))
        except OSError:
            continue
        for acct in accounts:
            remote = os.path.join(userdata, acct, APP_ID, "remote")
            if os.path.isdir(remote) and os.listdir(remote):
                found.append(remote)
    # Most recently modified first: that is the account actually playing.
    found.sort(key=lambda p: _newest_mtime(p), reverse=True)
    return found


def _newest_mtime(path):
    newest = 0.0
    for base, _dirs, files in os.walk(path):
        for name in files:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(base, name)))
            except OSError:
                pass
    return newest


def backups_dir():
    path = os.path.join(config_dir(), "backups")
    os.makedirs(path, exist_ok=True)
    return path


def backup_saves():
    """Copy the active save folder into backups/<timestamp>/.

    Returns the backup folder path, or None when no save folder was found.
    Keeps the newest ``MAX_BACKUPS`` backups.
    """
    remotes = find_save_remote_dirs()
    if not remotes:
        return None
    src = remotes[0]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    account = os.path.basename(os.path.dirname(os.path.dirname(src)))
    dest = os.path.join(backups_dir(), f"{stamp}-{account}")
    suffix = 1
    base = dest
    while os.path.exists(dest):
        suffix += 1
        dest = f"{base}-{suffix}"
    shutil.copytree(src, dest)
    prune_backups()
    return dest


def list_backups():
    root = backups_dir()
    out = []
    for name in sorted(os.listdir(root), reverse=True):
        path = os.path.join(root, name)
        if os.path.isdir(path):
            out.append(path)
    return out


def prune_backups(keep=MAX_BACKUPS):
    for old in list_backups()[keep:]:
        shutil.rmtree(old, ignore_errors=True)


def restore_backup(backup_path):
    """Copy a backup back over the live save folder.

    The current live save is backed up first (as a ``pre-restore`` copy),
    so a restore is itself undoable. Returns the live folder restored to.
    """
    remotes = find_save_remote_dirs()
    if not remotes:
        raise FileNotFoundError("No DD2 save folder found to restore into.")
    live = remotes[0]
    safety = backup_saves()
    tmp = live + ".restore-tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(backup_path, tmp)
    # Swap: move live aside, move tmp in, drop the old tree.
    aside = live + ".old"
    shutil.rmtree(aside, ignore_errors=True)
    os.replace(live, aside)
    try:
        os.replace(tmp, live)
    except OSError:
        os.replace(aside, live)  # roll back
        raise
    shutil.rmtree(aside, ignore_errors=True)
    return live, safety


# -- sidecar cleanup ------------------------------------------------------

def cleanup_sidecars(data_dir):
    """Delete known dump/probe sidecars from the bridge data dir."""
    removed = []
    for name in SIDECAR_DUMPS:
        path = os.path.join(data_dir, name)
        try:
            os.remove(path)
            removed.append(name)
        except OSError:
            pass
    return removed


# -- diagnostics bundle ---------------------------------------------------

def make_diagnostics_zip(out_path, *, versions, client=None, game_dir=None,
                         log_path=None, extra_files=None):
    """Write a single .zip a user can attach to a bug report."""
    lines = []
    for k, v in versions.items():
        lines.append(f"{k}: {v}")
    if client is not None:
        lines.append(f"bridge_version: {client.bridge_version}")
        lines.append(f"boot_token_present: {bool(client.boot_id)}")
        lines.append(f"data_dir: {client.data_dir}")
    if game_dir:
        exe = os.path.join(game_dir, "DD2.exe")
        if os.path.isfile(exe):
            st = os.stat(exe)
            lines.append(f"DD2.exe size: {st.st_size}")
            lines.append(f"DD2.exe mtime: {time.ctime(st.st_mtime)}")
    history = list(getattr(client, "history", []) or [])
    hist_text = "\n".join(
        f"{h.get('ts', '')} {h.get('command', '')} "
        f"args={h.get('argc', 0)} {h.get('ms', 0):.0f}ms {h.get('result', '')}"
        for h in history[-200:]
    )
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("diagnostics.txt", "\n".join(lines) + "\n")
        z.writestr("command_history.txt", hist_text + "\n")
        if log_path and os.path.isfile(log_path):
            try:
                with open(log_path, "r", encoding="utf-8",
                          errors="replace") as f:
                    tail = f.readlines()[-400:]
                z.writestr("client.log", "".join(tail))
            except OSError:
                pass
        for arc, path in (extra_files or {}).items():
            if path and os.path.isfile(path):
                try:
                    z.write(path, arcname=arc)
                except OSError:
                    pass
    return out_path
