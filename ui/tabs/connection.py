"""Connection tab: install the bridge, launch the game, connect."""
import glob
import os
import re
import shutil
import subprocess
import threading
import time

import customtkinter as ctk

from bridge import safety
from bridge.enums import parse_enums
from bridge.game_path import (
    config_dir, find_data_dir, data_dir_or_raise, game_dir_from_data_dir,
    bundled_lua_path, bundled_lua_version,
    get_custom_exe, set_custom_exe, clear_custom_exe,
    game_running, installed_lua_version, APP_ID as DD2_STEAM_APPID,
)
from bridge.installer import (
    download_reframework, file_sha256, looks_like_reframework,
)
from bridge.protocol import BridgeClient, BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ScrollArea, caption, run_async,
    PrimaryButton, GhostButton, QuietButton, Tooltip,
)
from version import BRIDGE_MAJOR, BRIDGE_VERSION, CLIENT_VERSION


class ConnectionTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.data_dir = None
        self._cancel = threading.Event()
        self._busy = False
        self._detect_seq = 0
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        PageHeader(
            self, "Connection",
            "Install the game-side bridge, launch DD2, and connect once "
            "your save is loaded.").grid(row=0, column=0, sticky="ew",
                                         pady=(0, T.PAD_L))
        self.scroll = ScrollArea(self)
        self.scroll.grid(row=1, column=0, sticky="nsew")

        install = Section(
            self.scroll, "Game installation",
            hint="Detected automatically, or pick DD2.exe yourself. "
                 "\"Reset\" returns to auto-detection.",
            **{"row": 0, "column": 0, "sticky": "ew", "pady": (0, T.PAD_M)})
        body = install.body
        self.path_var = ctk.StringVar(value="Looking for Dragon's Dogma 2...")
        ctk.CTkLabel(body, textvariable=self.path_var,
                     font=T.font(T.SIZE_BODY, "bold"), text_color=T.TEXT,
                     anchor="w", justify="left").grid(
            row=0, column=0, columnspan=2, sticky="ew")
        buttons = Row(body)
        buttons.grid(row=1, column=0, columnspan=2, sticky="w",
                     pady=(T.PAD_M, 0))
        buttons.add(GhostButton(buttons, "Detect", width=96,
                                command=self.detect))
        buttons.add(GhostButton(buttons, "Browse DD2.exe", width=150,
                                command=self.browse))
        buttons.add(QuietButton(buttons, "Reset", width=76, command=self.reset))

        session = Section(self.scroll, "Session", **{"row": 1, "column": 0,
                                                    "sticky": "ew",
                                                    "pady": (0, T.PAD_M)})
        body = session.body
        start_row = Row(body)
        start_row.grid(row=0, column=0, sticky="ew")
        self.connect_btn = PrimaryButton(start_row, text="Start", width=132,
                                         command=self.start_async)
        self.connect_btn.pack(side="left")
        self.cancel_btn = GhostButton(start_row, text="Cancel", width=92,
                                      command=self.cancel,
                                      state="disabled")
        self.cancel_btn.pack(side="left", padx=T.PAD_S)
        self.info_var = ctk.StringVar(
            value="Ready. Press Start and the client does the rest.")
        self.info_label = ctk.CTkLabel(
            body, textvariable=self.info_var, font=T.font(T.SIZE_BODY),
            text_color=T.TEXT_SOFT, anchor="w", justify="left")
        self.info_label.grid(row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        caption(body,
                "Start installs REFramework when missing or older than the "
                "game, updates ddbridge.lua, launches DD2 through Steam (or "
                "your own exe), and connects when the save is loaded.",
                row=2, column=0, sticky="ew", pady=(T.PAD_XS, 0))

        details = Section(self.scroll, "Versions & files",
                          **{"row": 2, "column": 0, "sticky": "ew"})
        self.details_body = details.body
        self.details_body.grid_columnconfigure(1, weight=1)
        self._detail_vars = {}
        for i, (key, label) in enumerate((
                ("client", "Client"),
                ("bridge_bundled", "Bridge (bundled)"),
                ("bridge_installed", "Bridge (installed)"),
                ("reframework", "REFramework"))):
            ctk.CTkLabel(self.details_body, text=label,
                         font=T.font(T.SIZE_BODY), text_color=T.MUTED,
                         anchor="w", width=150).grid(
                row=i, column=0, sticky="w", pady=3)
            var = ctk.StringVar(value="-")
            ctk.CTkLabel(self.details_body, textvariable=var,
                         font=T.font(T.SIZE_BODY), text_color=T.TEXT_SOFT,
                         anchor="e").grid(row=i, column=1, sticky="e")
            self._detail_vars[key] = var
        self.saves_var = ctk.StringVar(value="")
        ctk.CTkLabel(self.details_body, textvariable=self.saves_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                     anchor="w", justify="left").grid(
            row=5, column=0, columnspan=2, sticky="ew", pady=(T.PAD_M, 0))

        tools = Row(self.details_body)
        tools.grid(row=6, column=0, columnspan=2, sticky="w",
                   pady=(T.PAD_M, 0))
        tools.add(GhostButton(tools, "Backup saves", width=124,
                              command=self.backup_now))
        restore = GhostButton(tools, "Restore backup", width=128,
                              command=self.restore_backup)
        tools.add(restore)
        Tooltip(restore, "Overwrites the live DD2 save with the newest "
                         "backup. Close the game first; the current save is "
                         "backed up before the swap, so this is undoable.")
        tools.add(GhostButton(tools, "Diagnostics", width=112,
                              command=self.export_diagnostics))
        tools.add(QuietButton(tools, "Clean dumps", width=100,
                              command=self.clean_dumps))
        tools.add(QuietButton(tools, "Uninstall files", width=112,
                              command=self.reset_installed))

        self.install_status = ctk.CTkLabel(
            self.details_body, text="", font=T.font(T.SIZE_SMALL),
            text_color=T.MUTED, anchor="w", justify="left")
        self.install_status.grid(row=7, column=0, columnspan=2, sticky="ew",
                                 pady=(T.PAD_S, 0))

        self._detail_vars["client"].set(f"v{CLIENT_VERSION}")
        self._detail_vars["bridge_bundled"].set(f"v{BRIDGE_VERSION}")
        self.detect()

    # -- discovery -----------------------------------------------------

    def detect(self, quiet=False):
        """Scan for the install in the background; never block the UI."""
        if not quiet:
            self.path_var.set("Looking for Dragon's Dogma 2...")
        self._detect_seq += 1
        seq = self._detect_seq

        def _do():
            from bridge.game_path import find_game_dir
            game = find_game_dir()
            data = find_data_dir()
            info = {}
            if game:
                refw = os.path.join(game, "dinput8.dll")
                exe = os.path.join(game, "DD2.exe")
                if os.path.isfile(refw):
                    size = os.path.getsize(refw)
                    info["reframework"] = f"installed ({size / 1_000_000:.1f} MB)"
                else:
                    info["reframework"] = "not installed"
                if not os.path.isfile(exe):
                    info["reframework"] += " - DD2.exe not found"
                lua = os.path.join(game, "reframework", "autorun",
                                   "ddbridge.lua")
                ver = installed_lua_version(lua) if os.path.isfile(lua) else None
                info["bridge_installed"] = f"v{ver}" if ver else "not installed"
            else:
                info["reframework"] = "game folder not found"
                info["bridge_installed"] = "not installed"
            saves = self._saves_text()
            # Discard a result if another scan started meanwhile.
            self.after(0, lambda: self._apply_detect(game, data, info, saves,
                                                     quiet)
                       if seq == self._detect_seq else None)
        run_async(self, _do)

    def _apply_detect(self, game, data, info, saves_text="", quiet=False):
        self.data_dir = data
        if game:
            tag = "custom path" if get_custom_exe() else "auto-detected"
            self.path_var.set(f"{game}   ·   {tag}")
        else:
            self.path_var.set("Not found - use Browse DD2.exe to point at it.")
        for key, value in info.items():
            if key in self._detail_vars:
                self._detail_vars[key].set(value)
        if saves_text:
            self.saves_var.set(saves_text)
        if not quiet:
            self.app.set_status("Game folder detected." if game
                                else "Game folder not found.")

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

    def _saves_text(self):
        """Save-folder line. Runs on a worker thread - it touches the disk."""
        try:
            backups = safety.list_backups()
            remotes = safety.find_save_remote_dirs()
            if remotes:
                return (f"Save folder: {remotes[0]}   ·   "
                        f"{len(backups)} backup(s)")
            return ("Save folder not found yet - automatic backups start "
                    "once it is detected.")
        except Exception:
            return ""

    def _refresh_saves_async(self):
        def _do():
            text = self._saves_text()
            if text:
                self.after(0, lambda: self.saves_var.set(text))
        run_async(self, _do)

    # -- saves & tools --------------------------------------------------

    def backup_now(self):
        def _do():
            try:
                dest = safety.backup_saves()
                msg = (f"Save backed up to {dest}" if dest else
                       "No DD2 save folder found - nothing to back up.")
            except Exception as e:
                msg = f"Backup failed: {e}"
            self.after(0, lambda: (self.app.set_status(msg),
                                   self._refresh_saves_async()))
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
            self.after(0, lambda: (self.app.set_status(msg),
                                   self._refresh_saves_async()))
        run_async(self, _do)

    def export_diagnostics(self):
        from tkinter import filedialog
        default = os.path.join(
            config_dir(),
            f"arisens-diagnostics-{time.strftime('%Y%m%d-%H%M%S')}.zip")
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
                    out, versions=versions, client=client,
                    game_dir=game_dir,
                    log_path=getattr(self.app, "log_path", None))
                msg = f"Diagnostics bundle written: {out}"
            except Exception as e:
                msg = f"Diagnostics export failed: {e}"
            self.after(0, lambda: self.app.set_status(msg))
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
                "Uninstall installed files",
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
        self.detect()

    # -- start ----------------------------------------------------------

    def start_async(self):
        if self._busy:
            return
        self._busy = True
        self._cancel.clear()
        self.connect_btn.configure(state="disabled", text="Working...")
        self.cancel_btn.configure(state="normal")

        def _worker():
            try:
                self._start()
            except Exception:
                self._done(False, "Unexpected error - see the log file.")
                raise

        run_async(self, _worker)

    def cancel(self):
        self._cancel.set()
        self.app.set_status("Cancelling...")

    def _status(self, msg):
        self.after(0, lambda: (self.info_var.set(msg),
                               self.app.set_status(msg)))

    def _start(self):
        try:
            data_dir = getattr(self, "data_dir", None) or data_dir_or_raise()
        except FileNotFoundError as e:
            self._done(False, str(e))
            return
        game_dir = game_dir_from_data_dir(data_dir)
        was_running = game_running()
        changed = []

        # 1. REFramework: install when missing, refresh when the game was
        #    updated after it was installed (a stale nightly may fail on a
        #    new title update).
        refw_dll = os.path.join(game_dir, "dinput8.dll")
        game_exe = os.path.join(game_dir, "DD2.exe")
        refw_stale = (
            os.path.isfile(refw_dll) and os.path.isfile(game_exe)
            and os.path.getmtime(game_exe) > os.path.getmtime(refw_dll)
        )
        if not os.path.isfile(refw_dll) or refw_stale:
            if was_running:
                self._done(False,
                           "REFramework is missing or older than the game "
                           "install. Close DD2, then press Start again.")
                return
            try:
                download_reframework(game_dir, self._status)
                changed.append("REFramework installed"
                               + (" (refreshed)" if refw_stale else ""))
            except Exception as e:
                self._done(False, f"Could not install REFramework: {e}")
                return
        if self._cancel.is_set():
            self._done(False, "Cancelled.")
            return

        # 2. ddbridge.lua: install or upgrade, keeping one .bak.
        dest = os.path.join(game_dir, "reframework", "autorun", "ddbridge.lua")
        src = bundled_lua_path()
        bver = bundled_lua_version()
        iver = installed_lua_version(dest) if os.path.isfile(dest) else None
        if iver != bver:
            if not os.path.isfile(src):
                self._done(False,
                           f"Bundled ddbridge.lua not found ({src}). "
                           "Reinstall the client.")
                return
            try:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if os.path.isfile(dest):
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

        # 3. Installed files only take effect at game start.
        if was_running and changed:
            self._done(False,
                       "Installed: " + "; ".join(changed) + ". "
                       "The game was already running - restart DD2, then "
                       "press Start again.")
            return

        # 4. Launch the game (no-op when it is already running).
        if not was_running:
            custom = get_custom_exe()
            try:
                if custom:
                    self._status(
                        f"Starting {os.path.basename(custom)} directly...")
                    subprocess.Popen([custom], cwd=game_dir)
                else:
                    self._status("Starting Dragon's Dogma 2 through Steam...")
                    if os.name == "nt":
                        os.startfile(f"steam://run/{DD2_STEAM_APPID}")
                    else:
                        import webbrowser
                        webbrowser.open(f"steam://run/{DD2_STEAM_APPID}")
            except Exception as e:
                self._done(False,
                           f"Could not launch the game: {e}. Start it "
                           "manually, then press Start again.")
                return

        # 5. Wait for the bridge (game boot + save load).
        self._status("Waiting for the game - load your save and the client "
                     "connects automatically...")
        client = BridgeClient(data_dir)
        pong = None
        deadline = time.time() + 300
        while time.time() < deadline:
            if self._cancel.is_set():
                self._done(False, "Cancelled - the game was left running.")
                return
            try:
                pong = client.ping(timeout=5)
                break
            except (BridgeError, BridgeTimeout):
                time.sleep(3)
        if not pong:
            self._done(False,
                       "The game didn't respond within 5 minutes. Make sure "
                       "DD2 is running with your save loaded.")
            return

        # 6. Version check.
        m = re.search(r"pong\s+ddbridge\s+(\d+\.\d+\.\d+)", pong or "")
        if not m or not m.group(1).startswith(BRIDGE_MAJOR + "."):
            self._done(False,
                       f"Version mismatch: game says '{pong}', client "
                       f"expects {BRIDGE_MAJOR}.x. Press Start again to "
                       "update the game files.")
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
        # Refresh the file/version panel without overwriting the
        # "Connected: ..." status message.
        self.after(0, lambda: self.detect(quiet=True))

    def _done(self, ok, msg):
        def _ui():
            self._busy = False
            self.connect_btn.configure(state="normal", text="Start")
            self.cancel_btn.configure(state="disabled")
            self.info_var.set(msg)
            self.app.set_status(msg)
            self._refresh_saves_async()
        self.after(0, _ui)
