"""Connection tab: find the game, install REFramework + ddbridge.lua, launch, connect."""
import glob
import os
import re
import shutil
import subprocess
import time

import customtkinter as ctk

from bridge import safety
from bridge.installer import (
    REFRAMEWORK_URL, REFW_MIN_BYTES, _backup_dll, _download,
    _extract_dinput8, download_reframework, file_sha256,
    looks_like_reframework,
)
from bridge.enums import parse_enums
from bridge.game_path import (
    config_dir, find_data_dir, data_dir_or_raise, game_dir_from_data_dir,
    bundled_lua_path, bundled_lua_version,
    get_custom_exe, set_custom_exe, clear_custom_exe, game_exe_name,
)
from bridge.protocol import BridgeClient, BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import Card, card_content, H1, Muted, PrimaryButton, GhostButton, run_async, Tooltip
from version import BRIDGE_MAJOR, BRIDGE_VERSION, CLIENT_VERSION

class ConnectionTab(BaseTab):
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
        Muted(self, help_text, row=4, column=0, sticky="w", pady=(8, 0))

        # saves & tools card (v0.92)
        card3 = Card(self, row=3, column=0, sticky="ew", padx=4, pady=6)
        cc3 = card_content(card3)
        ctk.CTkLabel(cc3, **T.body("Saves & tools")).grid(
            row=0, column=0, sticky="w", pady=(0, 6))
        srow = ctk.CTkFrame(cc3, fg_color="transparent")
        srow.grid(row=1, column=0, sticky="w")
        GhostButton(srow, text="Backup saves now", width=150,
                    command=self.backup_now).pack(side="left", padx=(0, 8))
        _restore = GhostButton(srow, text="Restore backup", width=130,
                    command=self.restore_backup)
        _restore.pack(side="left", padx=(0, 8))
        Tooltip(_restore, "Overwrites your live DD2 save with the newest "
                          "backup. Close the game first. Your current save "
                          "is backed up first, so this is undoable.")
        GhostButton(srow, text="Export diagnostics", width=150,
                    command=self.export_diagnostics).pack(side="left", padx=(0, 8))
        srow2 = ctk.CTkFrame(cc3, fg_color="transparent")
        srow2.grid(row=2, column=0, sticky="w", pady=(8, 0))
        GhostButton(srow2, text="Clean dump files", width=150,
                    command=self.clean_dumps).pack(side="left", padx=(0, 8))
        GhostButton(srow2, text="Reset installed files", width=170,
                    command=self.reset_installed).pack(side="left")
        self.saves_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc3, textvariable=self.saves_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=3, column=0, sticky="w", pady=(8, 0))
        self._refresh_saves_label()

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
            try:
                set_custom_exe(f)
            except OSError as e:
                self.app.set_status(f"Could not save the game path: {e}")
                return
            self.detect()
            self.app.set_status(f"Using {f} - press Start.")

    def reset(self):
        clear_custom_exe()
        self.detect()

    # -- saves & tools (v0.92) -------------------------------------------

    def _refresh_saves_label(self):
        try:
            backups = safety.list_backups()
            remotes = safety.find_save_remote_dirs()
            if remotes:
                self.saves_var.set(
                    f"Save folder: {remotes[0]}  |  backups: {len(backups)}")
            else:
                self.saves_var.set(
                    "Save folder not found yet (Steam userdata) - automatic "
                    "backups start once it is detected.")
        except Exception:
            self.saves_var.set("")

    def backup_now(self):
        def _do():
            try:
                dest = safety.backup_saves()
                msg = (f"Save backed up to {dest}" if dest else
                       "No DD2 save folder found - nothing to back up.")
            except Exception as e:
                msg = f"Backup failed: {e}"
            err = msg
            self.after(0, lambda: (self.app.set_status(err),
                                   self._refresh_saves_label()))
        run_async(self, _do)

    def restore_backup(self):
        import tkinter.messagebox as messagebox
        backups = safety.list_backups()
        if not backups:
            self.app.set_status("No backups to restore yet.")
            return
        if game_running():
            self.app.set_status(
                "Close DD2 first - restoring over a running game's save "
                "is not safe.")
            return
        newest = backups[0]
        if not messagebox.askyesno(
                "Restore backup",
                f"Restore the newest backup?\n\n{newest}\n\n"
                "Your current save is backed up first, so this is "
                "undoable."):
            return
        def _do():
            try:
                live, _pre = safety.restore_backup(newest)
                msg = f"Restored {os.path.basename(newest)} -> {live}"
            except Exception as e:
                msg = f"Restore failed: {e}"
            err = msg
            self.after(0, lambda: (self.app.set_status(err),
                                   self._refresh_saves_label()))
        run_async(self, _do)

    def export_diagnostics(self):
        from tkinter import filedialog
        default = os.path.join(
            config_dir(), f"arisens-diagnostics-{time.strftime('%Y%m%d-%H%M%S')}.zip")
        out = filedialog.asksaveasfilename(
            title="Export diagnostics bundle",
            defaultextension=".zip",
            filetypes=[("Zip archive", "*.zip")],
            initialdir=os.path.dirname(default),
            initialfile=os.path.basename(default))
        if not out:
            return
        client = self.app.client
        game_dir = None
        try:
            game_dir = game_dir_from_data_dir(
                getattr(self, "data_dir", None) or data_dir_or_raise())
        except Exception:
            pass
        versions = {"client": CLIENT_VERSION,
                    "bridge_bundled": BRIDGE_VERSION}
        if game_dir:
            dll = os.path.join(game_dir, "dinput8.dll")
            if os.path.isfile(dll):
                try:
                    versions["dinput8.dll_sha256"] = file_sha256(dll)
                    versions["dinput8.dll_looks_like_reframework"] = \
                        str(looks_like_reframework(dll))
                except OSError:
                    pass
        def _do():
            try:
                safety.make_diagnostics_zip(
                    out,
                    versions=versions,
                    client=client, game_dir=game_dir,
                    log_path=getattr(self.app, "log_path", None))
                msg = f"Diagnostics bundle written: {out}"
            except Exception as e:
                msg = f"Diagnostics export failed: {e}"
            err = msg
            self.after(0, lambda: self.app.set_status(err))
        run_async(self, _do)

    def clean_dumps(self):
        data_dir = getattr(self, "data_dir", None)
        if not data_dir:
            self.app.set_status("Game folder not detected yet.")
            return
        removed = safety.cleanup_sidecars(data_dir)
        self.app.set_status(
            f"Removed {len(removed)} dump file(s) from the bridge data "
            "folder." if removed else "No dump files to clean.")

    def reset_installed(self):
        import tkinter.messagebox as messagebox
        if game_running():
            self.app.set_status(
                "Close DD2 first - installed files are locked while the "
                "game runs.")
            return
        try:
            game_dir = game_dir_from_data_dir(
                getattr(self, "data_dir", None) or data_dir_or_raise())
        except Exception as e:
            self.app.set_status(str(e))
            return
        if not messagebox.askyesno(
                "Reset installed files",
                "Remove the installed ddbridge.lua (restoring its .bak "
                "if one exists) and restore the dinput8.dll .bak if one "
                "exists?\n\nThe game itself is not touched."):
            return
        done = []
        lua_dest = os.path.join(
            game_dir, "reframework", "autorun", "ddbridge.lua")
        try:
            if os.path.isfile(lua_dest + ".bak"):
                os.replace(lua_dest + ".bak", lua_dest)
                done.append("ddbridge.lua restored from .bak")
            elif os.path.isfile(lua_dest):
                os.remove(lua_dest)
                done.append("ddbridge.lua removed")
        except OSError as e:
            self.app.set_status(f"Could not reset ddbridge.lua: {e}")
            return
        dll = os.path.join(game_dir, "dinput8.dll")
        try:
            if os.path.isfile(dll + ".bak"):
                os.replace(dll + ".bak", dll)
                done.append("dinput8.dll restored from .bak")
        except OSError as e:
            self.app.set_status(f"Could not restore dinput8.dll: {e}")
            return
        self.app.set_status(
            "Reset installed files: " + ("; ".join(done) if done else
                                         "nothing to do."))

    def start_async(self):
        self.connect_btn.configure(state="disabled", text="Working...")

        def _worker():
            try:
                self._start()
            except Exception:
                # Never leave the Start button stuck on "Working..." if a
                # worker dies somewhere _start does not expect.
                self._done(False, "Unexpected error - see the log file.")
                raise

        run_async(self, _worker)

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
                    # Single .bak, replaced on the next update (v0.92).
                    shutil.copy2(dest, dest + ".bak")
                    for old in glob.glob(dest + ".bak-*"):
                        try:
                            os.remove(old)
                        except OSError:
                            pass
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
        m = re.search(r"pong\s+ddbridge\s+(\d+\.\d+\.\d+)", pong or "")
        if not m or not m.group(1).startswith(BRIDGE_MAJOR + "."):
            self._done(False,
                f"Version mismatch: game says '{pong}', client expects {BRIDGE_MAJOR}.x. "
                "Press Start again to update the game files.")
            return

        # 7. Connected: load enums, refresh pawns.
        self.app.set_client(client)
        try:
            n = client.send("list_enums", timeout=60)
            _enums_text = client.read_sidecar("enums.txt") or ""
            self.app.enum_data = parse_enums(_enums_text)
            self.app.cache_sidecar("enums.txt", _enums_text)
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
