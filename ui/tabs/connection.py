"""Connection tab: find the game, install REFramework + ddbridge.lua, launch, connect."""
import os
import re
import shutil
import threading
import time
import customtkinter as ctk

from bridge.game_path import (
    find_data_dir, data_dir_or_raise, game_dir_from_data_dir,
    bundled_lua_path, bundled_lua_version,
    get_custom_exe, set_custom_exe, clear_custom_exe, game_exe_name,
)
from bridge.protocol import BridgeClient, BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import Card, card_content, H1, Muted, PrimaryButton, GhostButton

EXPECTED_MAJOR = "1.89"  # must match ddbridge.lua's pong
REFRAMEWORK_URL = ("https://github.com/praydog/REFramework-nightly/releases/"
                   "latest/download/REFramework.zip")
DD2_STEAM_APPID = "2054970"


def installed_lua_version(path):
    """Read the version from an installed ddbridge.lua header, or None."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            head = f.read(4096)
    except OSError:
        return None
    m = re.search(r"ddbridge\.lua\s+v(\d+\.\d+\.\d+)", head)
    if m:
        return m.group(1)
    m = re.search(r"pong ddbridge (\d+\.\d+\.\d+)", head)
    return m.group(1) if m else None


def game_running():
    if os.name != "nt":
        return False
    import subprocess
    name = game_exe_name()
    try:
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {name}"],
                             capture_output=True, text=True, timeout=10).stdout
        return name.lower() in out.lower()
    except Exception:
        return False


def download_reframework(game_dir, progress_cb):
    """Download REFramework.zip and extract ONLY dinput8.dll (per the release notes)."""
    import urllib.request
    import zipfile
    import tempfile

    def _hook(blocks, block_size, total):
        if total > 0:
            pct = min(100, blocks * block_size * 100 // total)
            progress_cb(f"Downloading REFramework... {pct}%")

    progress_cb("Downloading REFramework...")
    tmp = tempfile.mktemp(suffix=".zip")
    try:
        urllib.request.urlretrieve(REFRAMEWORK_URL, tmp, reporthook=_hook)
        progress_cb("Installing REFramework...")
        with zipfile.ZipFile(tmp, "r") as z:
            name = next((n for n in z.namelist()
                         if n.lower().endswith("dinput8.dll")), None)
            if not name:
                raise RuntimeError("dinput8.dll not found in REFramework.zip")
            with open(os.path.join(game_dir, "dinput8.dll"), "wb") as f:
                f.write(z.read(name))
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def parse_enums(text):
    """Parse enums.txt (key\\tvalue\\tname lines) into the structure tabs need."""
    E = {}
    for line in text.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[1].lstrip("-").isdigit():
            E.setdefault(parts[0], []).append({"v": int(parts[1]), "n": parts[2]})

    def per_job(entries, strip, others=False):
        jobs = [{"labels": ["(none)"], "ids": [0]} for _ in range(10)]
        extra = []
        import re
        for ent in entries or []:
            m = re.match(r"^Job(\d\d)_", ent["n"])
            j = int(m.group(1)) if m else 0
            if 1 <= j <= 10:
                t = jobs[j - 1]
                label = re.sub(r"^Job\d\d_", "", ent["n"]) if strip else ent["n"]
                t["labels"].append(label)
                t["ids"].append(ent["v"])
            elif others and ent["v"] != 0:
                extra.append(ent)
        for t in jobs:
            for ent in extra:
                t["labels"].append("[other] " + ent["n"])
                t["ids"].append(ent["v"])
        return jobs

    import re
    data = {
        "jobsCustom": per_job(E.get("custom"), True),
        "jobsNormal": per_job(E.get("normal"), True),
        "jobsAbility": per_job(E.get("ability"), False, True),
        "customName": {e["v"]: re.sub(r"^Job\d\d_", "", e["n"]) for e in E.get("custom", [])},
        "normalName": {e["v"]: re.sub(r"^Job\d\d_", "", e["n"]) for e in E.get("normal", [])},
        "equipList": [(e["v"], e["n"]) for e in E.get("equipskill", [])],
        "equipName": {e["v"]: e["n"] for e in E.get("equipskill", [])},
        "enhLabels": [f"{e['n']} ({e['v']})" for e in E.get("enhance", [])],
        "enhVals": [e["v"] for e in E.get("enhance", [])],
        "levelLabels": [f"{e['n']} ({e['v']})" for e in E.get("level", [])],
        "levelValues": [e["v"] for e in E.get("level", [])],
    }
    if not data["levelValues"]:
        data["levelLabels"] = ["0", "1", "2"]
        data["levelValues"] = [0, 1, 2]
    return data


class ConnectionTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)

        H1(self, "Connection", row=0, column=0, sticky="w", pady=(0, 10))

        # game folder card
        card = Card(self, row=1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        ctk.CTkLabel(cc, **T.body("Game folder:")).grid(
            row=0, column=0, sticky="w")
        self.path_var = ctk.StringVar(value="(not detected)")
        ctk.CTkLabel(
            cc, textvariable=self.path_var, font=(T.FONT_FAMILY, 11),
            text_color=T.MUTED,
        ).grid(row=1, column=0, sticky="w", pady=(2, 10))
        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=2, column=0, sticky="w")
        GhostButton(brow, text="Detect", width=90,
                    command=self.detect).pack(side="left", padx=(0, 8))
        GhostButton(brow, text="Browse DD2.exe...", width=130,
                    command=self.browse).pack(side="left", padx=(0, 8))
        GhostButton(brow, text="Reset", width=90,
                    command=self.reset).pack(side="left")

        # connect card
        card2 = Card(self, row=2, column=0, sticky="ew", padx=4, pady=6)
        cc2 = card_content(card2)
        cc2.grid_columnconfigure(1, weight=1)
        self.connect_btn = PrimaryButton(
            cc2, text="Start", width=140, command=self.start_async
        )
        self.connect_btn.grid(row=0, column=0, sticky="w")
        self.info_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc2, textvariable=self.info_var,
                     font=(T.FONT_FAMILY, 12), text_color=T.TEXT).grid(
            row=0, column=1, sticky="w", padx=12)

        # help text
        help_text = (
            "Press Start and the client handles everything:\n"
            "1. Installs REFramework (dinput8.dll) if it's missing, or\n"
            "   refreshes it when the game was updated after it was installed\n"
            "   (keeps up with Title Updates like 4.0).\n"
            "2. Installs or updates ddbridge.lua to the bundled version.\n"
            "3. Launches Dragon's Dogma 2 - through Steam, or directly\n"
            "   from the DD2.exe you picked with \"Browse DD2.exe...\".\n"
            "4. Connects automatically once your save is loaded.\n\n"
            "No Steam needed: pick your DD2.exe once and the client\n"
            "remembers it. \"Reset\" goes back to auto-detection.\n\n"
            "The client talks to the game through text files in\n"
            "reframework/data/ddbridge/ - no memory scanning."
        )
        Muted(self, help_text, row=3, column=0, sticky="w", pady=(8, 0))

        self.detect()

    # -- actions ------------------------------------------------------

    def detect(self):
        from bridge.game_path import find_game_dir
        g = find_game_dir()
        self.data_dir = find_data_dir()
        if g:
            tag = " (your pick)" if get_custom_exe() else " (auto-detected)"
            self.path_var.set(g + tag)
        else:
            self.path_var.set("(not detected - use Browse DD2.exe...)")
        self.app.set_status("Game folder detected." if g else "Game folder not found.")

    def browse(self):
        from tkinter import filedialog
        f = filedialog.askopenfilename(
            title="Select DD2.exe",
            filetypes=[("DD2.exe", "DD2.exe"),
                       ("Executables", "*.exe"),
                       ("All files", "*.*")])
        if f:
            set_custom_exe(f)
            self.detect()
            self.app.set_status(f"Using {f} - press Start.")

    def reset(self):
        clear_custom_exe()
        self.detect()

    def start_async(self):
        self.connect_btn.configure(state="disabled", text="Working...")
        threading.Thread(target=self._start, daemon=True).start()

    def _status(self, msg):
        self.after(0, lambda: (self.info_var.set(msg), self.app.set_status(msg)))

    def _start(self):
        try:
            data_dir = getattr(self, "data_dir", None) or data_dir_or_raise()
        except FileNotFoundError as e:
            self._done(False, str(e))
            return
        game_dir = game_dir_from_data_dir(data_dir)
        was_running = game_running()
        changed = []

        # 1. REFramework present? Install it if not. Also refresh it when the
        #    game was updated after REFramework was installed (e.g. Title
        #    Update 4.0, 2026-10-09): a nightly built before the new game
        #    build may not have its TDB layout and can fail to initialize.
        refw_dll = os.path.join(game_dir, "dinput8.dll")
        game_exe = os.path.join(game_dir, "DD2.exe")
        refw_stale = (
            os.path.isfile(refw_dll) and os.path.isfile(game_exe)
            and os.path.getmtime(game_exe) > os.path.getmtime(refw_dll)
        )
        if not os.path.isfile(refw_dll) or refw_stale:
            if was_running:
                # dinput8.dll is locked while the game runs.
                self._done(False,
                    "REFramework is missing or older than the game install "
                    "(the game was updated after it was installed). "
                    "Close DD2 first, then press Start again.")
                return
            try:
                download_reframework(game_dir, self._status)
                changed.append("REFramework installed"
                               + (" (refreshed for the updated game)" if refw_stale else ""))
            except Exception as e:
                self._done(False, f"Could not install REFramework: {e}")
                return

        # 2. ddbridge.lua: install if missing, upgrade if outdated (backup first).
        dest = os.path.join(game_dir, "reframework", "autorun", "ddbridge.lua")
        src = bundled_lua_path()
        bver = bundled_lua_version()
        iver = installed_lua_version(dest) if os.path.isfile(dest) else None
        if iver != bver:
            if not os.path.isfile(src):
                self._done(False,
                    f"Bundled ddbridge.lua not found ({src}). Reinstall the client.")
                return
            try:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if os.path.isfile(dest):
                    shutil.copy2(dest, dest + f".bak-{iver or 'unknown'}")
                shutil.copy2(src, dest)
                changed.append(
                    f"ddbridge.lua v{bver} installed"
                    + (f" (old v{iver} backed up)" if iver else ""))
            except OSError as e:
                self._done(False, f"Could not install ddbridge.lua: {e}")
                return

        # 3. Fresh installs only take effect at game start.
        if was_running and changed:
            self._done(False,
                "Installed: " + "; ".join(changed) + ". "
                "The game was already running — restart DD2, then press Start again.")
            return

        # 4. Launch the game (no-op if already running).
        if not was_running:
            custom = get_custom_exe()
            try:
                if custom:
                    self._status(
                        f"Starting {os.path.basename(custom)} directly...")
                    import subprocess
                    subprocess.Popen([custom], cwd=game_dir)
                else:
                    self._status("Starting Dragon's Dogma 2 via Steam...")
                    if os.name == "nt":
                        os.startfile(f"steam://run/{DD2_STEAM_APPID}")
                    else:
                        import webbrowser
                        webbrowser.open(f"steam://run/{DD2_STEAM_APPID}")
            except Exception as e:
                self._done(False,
                    f"Could not launch the game: {e}. "
                    "Start it manually, then press Start again.")
                return

        # 5. Wait for the bridge (game boot + save load).
        self._status("Waiting for the game — load your save, "
                     "the client connects automatically...")
        client = BridgeClient(data_dir)
        pong = None
        deadline = time.time() + 300
        while time.time() < deadline:
            try:
                pong = client.ping(timeout=5)
                break
            except (BridgeError, BridgeTimeout):
                time.sleep(5)
        if not pong:
            self._done(False,
                "The game didn't respond in 5 minutes. Make sure DD2 is running "
                "with your save loaded, then press Start again.")
            return

        # 6. Version check.
        if EXPECTED_MAJOR not in pong:
            self._done(False,
                f"Version mismatch: game says '{pong}', client expects {EXPECTED_MAJOR}. "
                "Press Start again to update the game files.")
            return

        # 7. Connected: load enums, refresh pawns.
        self.app.set_client(client)
        try:
            n = client.send("list_enums", timeout=60)
            self.app.enum_data = parse_enums(client.read_sidecar("enums.txt") or "")
            enum_msg = f", {n} enum entries"
        except (BridgeError, BridgeTimeout) as e:
            enum_msg = f" (enum load failed: {e})"
        msg = f"Connected: {pong}{enum_msg}"
        if changed:
            msg = "Installed: " + "; ".join(changed) + ". " + msg
        self._done(True, msg)
        self.after(0, self.app.refresh_pawns)

    def _done(self, ok, msg):
        def _ui():
            self.connect_btn.configure(state="normal", text="Start")
            self.info_var.set(msg)
            self.app.set_status(msg)
        self.after(0, _ui)
