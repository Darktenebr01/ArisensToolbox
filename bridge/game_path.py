"""Find the Arisen's Toolbox data directory: <game>/reframework/data/ddbridge/."""
import os
import sys

DATA_SUBDIR = os.path.join("reframework", "data", "ddbridge")

# DD2 Steam AppID
APP_ID = "2054970"

COMMON_PATHS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\Dragons Dogma 2",
    r"C:\Program Files\Steam\steamapps\common\Dragons Dogma 2",
    r"D:\Steam\steamapps\common\Dragons Dogma 2",
    r"E:\Steam\steamapps\common\Dragons Dogma 2",
    r"F:\Steam\steamapps\common\Dragons Dogma 2",
]


def _from_registry():
    """Try Windows registry for the Steam install location of DD2."""
    if sys.platform != "win32":
        return None
    try:
        import winreg
        for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
            for sub in (
                r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App " + APP_ID,
                r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App " + APP_ID,
            ):
                try:
                    with winreg.OpenKey(hive, sub) as key:
                        path, _ = winreg.QueryValueEx(key, "InstallLocation")
                        if path and os.path.isfile(os.path.join(path, "DD2.exe")):
                            return path
                except OSError:
                    continue
    except Exception:
        pass
    return None


def _from_steam_libraries():
    """Parse libraryfolders.vdf for other Steam libraries."""
    if sys.platform != "win32":
        return None
    candidates = [
        os.path.expandvars(r"%ProgramFiles(x86)%\Steam\steamapps\libraryfolders.vdf"),
        os.path.expandvars(r"%ProgramFiles%\Steam\steamapps\libraryfolders.vdf"),
    ]
    for vdf in candidates:
        try:
            with open(vdf, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
        except OSError:
            continue
        # crude but effective: find quoted paths, check for the game dir
        import re
        for m in re.finditer(r'"path"\s+"([^"]+)"', content):
            lib = m.group(1).replace("\\\\", "\\")
            game = os.path.join(lib, "steamapps", "common", "Dragons Dogma 2")
            if os.path.isfile(os.path.join(game, "DD2.exe")):
                return game
    return None


def find_game_dir():
    """Return the DD2 install folder, or None."""
    # 1. explicit override (dev/testing)
    override = os.environ.get("DD2_BRIDGE_GAME_DIR")
    if override and os.path.isfile(os.path.join(override, "DD2.exe")):
        return override
    # 2. registry
    path = _from_registry()
    if path:
        return path
    # 3. other Steam libraries
    path = _from_steam_libraries()
    if path:
        return path
    # 4. common paths
    for p in COMMON_PATHS:
        if os.path.isfile(os.path.join(p, "DD2.exe")):
            return p
    return None


def find_data_dir():
    """Return the ddbridge data dir, or None if the game wasn't found."""
    game = find_game_dir()
    if not game:
        return None
    return os.path.join(game, DATA_SUBDIR)


def data_dir_or_raise():
    d = find_data_dir()
    if not d:
        raise FileNotFoundError(
            "Could not find Dragon's Dogma 2. Set DD2_BRIDGE_GAME_DIR "
            "or choose the folder manually."
        )
    return d


def game_dir_from_data_dir(data_dir):
    """<game>/reframework/data/ddbridge -> <game>"""
    return os.path.dirname(os.path.dirname(os.path.dirname(data_dir)))


def bundled_lua_path():
    """Path to the ddbridge.lua shipped with the client."""
    if getattr(sys, "frozen", False):
        base = sys._MEIPASS  # PyInstaller bundle
    else:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, "bridge", "data", "ddbridge.lua")


def bundled_lua_version():
    try:
        with open(os.path.join(os.path.dirname(bundled_lua_path()), "version.txt")) as f:
            return f.read().strip()
    except OSError:
        return "?"
