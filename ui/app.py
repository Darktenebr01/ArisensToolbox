"""Arisen's Toolbox standalone client - main window."""
import json
import logging
import os
import queue
import re
import sys
import threading
import tkinter.messagebox as messagebox
from logging.handlers import RotatingFileHandler

import customtkinter as ctk

from bridge import safety
from bridge.game_path import config_dir
from ui.tabs.connection import ConnectionTab
from ui.tabs.item_giver import ItemGiverTab
from ui.tabs.item_editor import ItemEditorTab
from ui.tabs.item_stats import ItemStatsTab
from ui.tabs.duplicate_items import DuplicateItemsTab
from ui.tabs.pawn import PawnTab
from ui.tabs.names import NamesTab
from ui.tabs.weapon_skills import WeaponSkillsTab
from ui.tabs.upgraded_skills import UpgradedSkillsTab
from ui.tabs.core_augments import CoreAugmentsTab
from ui.tabs.level_stats import LevelStatsTab
from ui.tabs.stat_search import StatSearchTab
from ui.tabs.mods import ModsTab
from ui.widgets import JOB_LABELS, run_async, PrimaryButton, GhostButton, Combo, Tooltip
from ui import theme as T
from version import BRIDGE_VERSION, CLIENT_VERSION

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")


def setup_logging():
    """Log to %LOCALAPPDATA%\\ArisensToolbox\\logs\\client.log."""
    log_dir = os.path.join(config_dir(), "logs")
    try:
        os.makedirs(log_dir, exist_ok=True)
    except OSError:
        pass
    path = os.path.join(log_dir, "client.log")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    if not any(isinstance(h, RotatingFileHandler) for h in root.handlers):
        try:
            handler = RotatingFileHandler(path, maxBytes=1_000_000,
                                          backupCount=3, encoding="utf-8")
        except OSError:
            # A read-only profile must not stop the app from starting.
            return path
        handler.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)s [%(threadName)s] %(name)s: %(message)s"))
        root.addHandler(handler)
    return path


# Tabs hidden from the sidebar in normal use (still importable/shown by code).
# (The Signatures tab was removed in v0.92 - see safety notes in README.)
DEV_TABS = {"Level & Stats", "Stat Search"}


def dev_mode():
    """Enable with DD2BRIDGE_DEV=1 or a dev_mode.txt next to the app."""
    if os.environ.get("DD2BRIDGE_DEV") == "1":
        return True
    try:
        base = (os.path.dirname(sys.executable) if getattr(sys, "frozen", False)
                else os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        return os.path.isfile(os.path.join(base, "dev_mode.txt"))
    except OSError:
        return False


class BridgeApp(ctk.CTk):
    def __init__(self, client=None):
        super().__init__()
        self.log_path = setup_logging()
        self._ui_queue = queue.Queue()
        self.client = client
        self.title("Arisen's Toolbox")
        self.geometry("1100x760")
        self.minsize(960, 640)
        # window icon (exe or source run)
        try:
            import os, sys
            if getattr(sys, "frozen", False):
                icon = os.path.join(sys._MEIPASS, "assets", "icon.ico")
            else:
                icon = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                    "assets", "icon.ico")
            if os.path.isfile(icon):
                self.iconbitmap(icon)
        except Exception:
            pass

        # shared state
        self.selected_item_row = None   # Item Editor <-> Item Stats
        self.enum_data = {}             # enums loaded at connect
        self._refreshables = []         # tabs with refresh() for target/vocation change
        self.dev_mode = dev_mode()      # hidden dev tabs visible?
        self._undo_stack = []           # [(label, undo_fn(client)->str)]
        self._current_tab = "Connection"
        self._hb_failures = 0           # consecutive heartbeat ping failures
        self._connected = False
        self._ui_state = self._load_ui_state()

        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(1, weight=1)

        self._build_header()
        self._build_sidebar()
        self._build_content()
        self._build_statusbar()

        self._register_tabs()
        self._build_nav()
        self._install_excepthooks()
        self._restore_ui_state()
        self.show_tab(self._ui_state.get("tab") or "Connection")
        self.after(30, self._pump_ui)
        self.after(5000, self._heartbeat_tick)
        self.bind_all("<Control-f>", lambda e: self._shortcut_search())
        self.bind_all("<Control-F>", lambda e: self._shortcut_search())
        self.bind_all("<F5>", lambda e: self._shortcut_refresh())
        self.bind_all("<Escape>", lambda e: self._shortcut_escape())
        self.bind_all("<Control-z>", lambda e: self.undo_last())
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # -- UI thread dispatcher ------------------------------------------

    def call_soon(self, fn, *args):
        """Queue a callback to run on the Tk main thread."""
        self._ui_queue.put((fn, args))

    def _pump_ui(self):
        while True:
            try:
                fn, args = self._ui_queue.get_nowait()
            except queue.Empty:
                break
            try:
                fn(*args)
            except Exception:
                logging.getLogger("arisens.ui").exception("UI callback failed")
        try:
            self.after(30, self._pump_ui)
        except Exception:
            pass

    def _install_excepthooks(self):
        log = logging.getLogger("arisens")

        def _hook(exc_type, exc, tb):
            log.error("uncaught exception", exc_info=(exc_type, exc, tb))
            self.call_soon(self.set_status,
                           "Unexpected error - see the log file.")

        def _thread_hook(args):
            name = args.thread.name if args.thread else "?"
            log.error("uncaught thread exception in %s", name,
                      exc_info=(args.exc_type, args.exc_value,
                                args.exc_traceback))
            self.call_soon(self.set_status,
                           "Unexpected error - see the log file.")

        sys.excepthook = _hook
        threading.excepthook = _thread_hook

    # -- header bar: target + vocation + pawn picker --------------------

    def _build_header(self):
        h = ctk.CTkFrame(self, fg_color=T.SURFACE, border_color=T.BORDER,
                         border_width=1, corner_radius=0)
        h.grid(row=0, column=0, columnspan=2, sticky="ew", padx=8, pady=(8, 0))
        h.grid_columnconfigure(99, weight=1)

        ctk.CTkLabel(h, **T.muted("Target:")).grid(
            row=0, column=0, padx=(12, 4), pady=8, sticky="w")
        self.target_var = ctk.StringVar(value="Main pawn")
        self.target_combo = Combo(
            h, variable=self.target_var, values=["Main pawn", "Player (Arisen)"],
            width=150, command=lambda _: self.refresh_all_target(),
        )
        self.target_combo.grid(row=0, column=1, padx=2, pady=8)

        ctk.CTkLabel(h, **T.muted("Vocation:")).grid(
            row=0, column=2, padx=(16, 4), pady=8, sticky="w")
        self.job_var = ctk.StringVar(value=JOB_LABELS[0])
        self.job_combo = Combo(
            h, variable=self.job_var, values=JOB_LABELS,
            width=180, command=lambda _: self.refresh_skill_tabs(),
        )
        self.job_combo.grid(row=0, column=3, padx=2, pady=8)

        GhostButton(h, text="Use current vocation", width=150,
                    command=self.use_current_vocation).grid(row=0, column=4, padx=8, pady=8)
        PrimaryButton(h, text="Set vocation", width=110,
                      command=self.set_vocation).grid(row=0, column=5, padx=2, pady=8)
        _unlock_btn = GhostButton(h, text="Unlock all", width=90,
                    command=self.unlock_all_vocations)
        _unlock_btn.grid(row=0, column=6, padx=2, pady=8)
        Tooltip(_unlock_btn, "Writes to your save: unlocks every vocation "
                             "for the selected target.")

        ctk.CTkLabel(h, **T.muted("Pawn:")).grid(
            row=1, column=0, padx=(12, 4), pady=(0, 10), sticky="w")
        self.pawn_var = ctk.StringVar(value="(not loaded)")
        self.pawn_combo = Combo(
            h, variable=self.pawn_var, values=["(not loaded)"],
            width=340, command=self._on_pawn_pick,
        )
        self.pawn_combo.grid(row=1, column=1, columnspan=3, padx=2, pady=(0, 10), sticky="w")
        self._pawn_idx = []
        GhostButton(h, text="Refresh pawns", width=120,
                    command=self.refresh_pawns).grid(row=1, column=4, padx=8, pady=(0, 10))
        self.undo_btn = GhostButton(h, text="Undo last change", width=140,
                    command=self.undo_last, state="disabled")
        self.undo_btn.grid(row=1, column=5, padx=2, pady=(0, 10))
        Tooltip(self.undo_btn, "Re-applies the previous value of the last "
                               "edit that recorded one (rating, badges, "
                               "vocation, item edit, rename...).")

    def target(self):
        return "player" if self.target_var.get() == "Player (Arisen)" else "pawn"

    def job(self):
        try:
            return JOB_LABELS.index(self.job_var.get()) + 1
        except ValueError:
            return 1

    def _client_or_msg(self):
        if not self.client:
            self.set_status("Not connected - go to the Connection tab first.")
            return None
        return self.client

    def use_current_vocation(self):
        client = self._client_or_msg()
        if not client:
            return
        def _do():
            try:
                res = client.send("get_info", self.target(), timeout=10)
                import re
                m = re.match(r"^(\d+),", res or "")
                j = int(m.group(1)) if m else 0
                if 1 <= j <= 10:
                    self.call_soon(lambda: (
                        self.job_var.set(JOB_LABELS[j - 1]),
                        self.refresh_skill_tabs(),
                    ))
                else:
                    self.call_soon(lambda: self.set_status(f"Vocation unknown: {res}"))
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(lambda: self.set_status(err))
        run_async(self, _do)

    def set_vocation(self):
        client = self._client_or_msg()
        if not client:
            return
        j = self.job()
        if self.target() == "pawn" and j > 6:
            self.set_status("Pawns can only use vocations 1-6.")
            return
        tgt = self.target()
        def _do():
            try:
                prev = None
                try:
                    info = client.send("get_info", tgt, timeout=10)
                    m = re.match(r"^(\d+),", info or "")
                    if m:
                        prev = int(m.group(1))
                except Exception:
                    pass
                res = client.send("set_vocation", tgt, j, timeout=15)
                if prev and prev != j:
                    self.record_undo(
                        f"vocation {prev}",
                        lambda c, t=tgt, p=prev: c.send(
                            "set_vocation", t, p, timeout=15))
                self.call_soon(lambda: (self.set_status(f"Vocation set: {res}"),
                                       self.refresh_all_target()))
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(lambda: self.set_status(err))
        run_async(self, _do)

    def unlock_all_vocations(self):
        client = self._client_or_msg()
        if not client:
            return
        if not self.confirm_bulk(
                "Unlock all vocations",
                f"This writes to your save: all 10 vocations will be "
                f"unlocked for {self.target_var.get()}."):
            return
        def _do():
            try:
                res = client.send("unlock_all_vocations", self.target(), timeout=15)
                self.call_soon(lambda: self.set_status(res))
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(lambda: self.set_status(err))
        run_async(self, _do)

    def refresh_pawns(self):
        client = self._client_or_msg()
        if not client:
            return
        def _do():
            try:
                res = client.send("list_pawns", timeout=15)
                idx, labels = [], []
                for row in (res or "").split(";"):
                    if "," in row:
                        i, lab = row.split(",", 1)
                        if i.strip().isdigit():
                            idx.append(int(i))
                            labels.append(f"{i.strip()}: {lab.strip()}")
                self.call_soon(lambda: self._set_pawns(idx, labels))
            except Exception as e:
                err = f"Pawn list: {e}"
                self.call_soon(lambda: self.set_status(err))
        run_async(self, _do)

    def _set_pawns(self, idx, labels):
        self._pawn_idx = idx
        if labels:
            self.pawn_combo.configure(values=labels)
            self.pawn_var.set(labels[0])
            self.set_status(f"{len(labels)} pawn(s) found.")
        else:
            self.pawn_combo.configure(values=["(none)"])
            self.pawn_var.set("(none)")

    def _on_pawn_pick(self, _value):
        try:
            values = list(self.pawn_combo.cget("values"))
            i = self._pawn_idx[values.index(self.pawn_var.get())]
        except (ValueError, IndexError):
            return
        client = self._client_or_msg()
        if not client:
            return
        def _do():
            try:
                res = client.send("select_pawn", i, timeout=15)
                self.call_soon(lambda: self._after_pawn_pick(res))
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(lambda: self.set_status(err))
        run_async(self, _do)

    def _after_pawn_pick(self, res):
        self.set_status(f"Now editing {res}")
        if self.target() == "pawn":
            self.refresh_all_target()
        # refresh pawn tab if visible
        frame = self._tab_frames.get("Rating & Badges")
        if frame and hasattr(frame, "refresh"):
            frame.refresh()

    # -- refreshable tabs ----------------------------------------------

    def register_refreshable(self, tab):
        self._refreshables.append(tab)

    def refresh_skill_tabs(self):
        for t in self._refreshables:
            if hasattr(t, "refresh_skills"):
                t.refresh_skills()

    def refresh_all_target(self):
        self.refresh_skill_tabs()
        for t in self._refreshables:
            if hasattr(t, "refresh_all"):
                t.refresh_all()

    # -- sidebar / content / status -------------------------------------

    def _build_sidebar(self):
        self.sidebar = ctk.CTkFrame(self, width=200, corner_radius=0, fg_color=T.SIDEBAR_BG)
        self.sidebar.grid(row=1, column=0, sticky="nsew", padx=(8, 0), pady=8)
        self.sidebar.grid_rowconfigure(99, weight=1)
        # title — stacked wordmark
        ctk.CTkLabel(self.sidebar, text="ARISEN'S",
                     font=(T.FONT_FAMILY, 17, "bold"), text_color=T.ACCENT,
                     ).grid(row=0, column=0, sticky="w", padx=14, pady=(12, 0))
        ctk.CTkLabel(self.sidebar, text="TOOLBOX",
                     font=(T.FONT_FAMILY, 17, "bold"), text_color=T.ACCENT,
                     ).grid(row=1, column=0, sticky="w", padx=14, pady=(0, 8))
        self._nav_start_row = 2
        self._nav_buttons = {}

    def _build_content(self):
        self.configure(fg_color=T.BG)
        self.content = ctk.CTkFrame(self, corner_radius=0, fg_color=T.BG)
        self.content.grid(row=1, column=1, sticky="nsew", padx=8, pady=8)
        self.content.grid_columnconfigure(0, weight=1)
        self.content.grid_rowconfigure(0, weight=1)

    def _build_statusbar(self):
        bar = ctk.CTkFrame(self, fg_color="transparent", height=24)
        bar.grid(row=2, column=0, columnspan=2, sticky="ew", padx=12, pady=(0, 4))
        self.conn_dot = ctk.CTkLabel(
            bar, text="●", font=(T.FONT_FAMILY, 12), text_color=T.FAINT,
            width=16,
        )
        self.conn_dot.pack(side="left")
        self.status_var = ctk.StringVar(value="Not connected.")
        self.statusbar = ctk.CTkLabel(
            bar, textvariable=self.status_var, anchor="w", height=24,
            font=(T.FONT_FAMILY, 11), text_color=T.MUTED,
        )
        self.statusbar.pack(side="left", fill="x", expand=True)

    def _set_conn_dot(self, connected):
        self._connected = connected
        try:
            self.conn_dot.configure(
                text_color=T.ACCENT if connected else "#c0392b")
        except Exception:
            pass

    def _register_tabs(self):
        self.tabs = [
            ("SETUP", "Connection", ConnectionTab),
            ("ITEMS", "Item Giver", ItemGiverTab),
            ("ITEMS", "Item Editor", ItemEditorTab),
            ("ITEMS", "Item Stats", ItemStatsTab),
            ("ITEMS", "Duplicate Items", DuplicateItemsTab),
            ("PAWN", "Rating & Badges", PawnTab),
            ("PAWN", "Names", NamesTab),
            ("CHARACTER", "Weapon Skills", WeaponSkillsTab),
            ("CHARACTER", "Upgraded Skills", UpgradedSkillsTab),
            ("CHARACTER", "Core Skills & Augments", CoreAugmentsTab),
            ("CHARACTER", "Level & Stats", LevelStatsTab),
            ("CHARACTER", "Stat Search", StatSearchTab),
            ("PLAYER", "Mods", ModsTab),
        ]
        self._tab_frames = {label: None for _, label, _ in self.tabs}

    def _build_nav(self):
        row = self._nav_start_row
        last_cat = None
        visible = [(c, l, f) for c, l, f in self.tabs
                   if l not in DEV_TABS or self.dev_mode]
        for cat, label, _ in visible:
            if cat != last_cat:
                ctk.CTkLabel(
                    self.sidebar, text=cat,
                    font=(T.FONT_FAMILY, 10, "bold"), text_color=T.FAINT,
                ).grid(row=row, column=0, sticky="w", padx=14, pady=(12 if row > 2 else 4, 2))
                row += 1
                last_cat = cat
            btn = ctk.CTkButton(
                self.sidebar, text=label, anchor="w", corner_radius=8,
                fg_color="transparent", hover_color=T.SURFACE2,
                text_color=T.MUTED, font=(T.FONT_FAMILY, 12),
                command=lambda l=label: self.show_tab(l),
            )
            btn.grid(row=row, column=0, sticky="ew", padx=8, pady=1)
            row += 1
            self._nav_buttons[label] = btn
        ctk.CTkLabel(
            self.sidebar, text=f"v{CLIENT_VERSION}  ·  bridge {BRIDGE_VERSION}",
            font=(T.FONT_FAMILY, 10), text_color=T.FAINT,
        ).grid(row=99, column=0, sticky="sw", padx=14, pady=10)

    def show_tab(self, label):
        if label not in self._tab_frames:
            label = "Connection"
        self._current_tab = label
        self._save_ui_state()
        for frame in self._tab_frames.values():
            if frame is not None:
                frame.grid_forget()
        frame = self._tab_frames[label]
        if frame is None:
            factory = next(f for _, l, f in self.tabs if l == label)
            frame = factory(self.content, self)
            self._tab_frames[label] = frame
        frame.grid(row=0, column=0, sticky="nsew")
        # highlight active nav button
        for name, btn in self._nav_buttons.items():
            if name == label:
                btn.configure(fg_color=T.ACCENT_DIM, text_color=T.ACCENT,
                              font=(T.FONT_FAMILY, 12, "bold"))
            else:
                btn.configure(fg_color="transparent", text_color=T.MUTED,
                              font=(T.FONT_FAMILY, 12))

    def set_status(self, text):
        if hasattr(self, "status_var"):
            self.status_var.set(text)

    def set_client(self, client):
        self.client = client
        if client is not None:
            # Save protection: back the save up before this session's
            # first mutating command reaches the game.
            client.on_before_first_mutation = self._ensure_save_backup
            self._hb_failures = 0
            self._set_conn_dot(True)

    # -- save protection / undo / bulk confirm (v0.92) ---------------------

    def _ensure_save_backup(self, command):
        """Protocol hook (worker thread): back up saves pre-mutation."""
        try:
            dest = safety.backup_saves()
        except Exception:
            logging.getLogger("arisens.safety").exception("save backup failed")
            dest = None
        if dest:
            self.call_soon(self.set_status,
                           f"Save backed up before '{command}': {dest}")
        else:
            logging.getLogger("arisens.safety").warning(
                "no DD2 save folder found; %s proceeds without a backup",
                command)
            self.call_soon(self.set_status,
                           "Warning: no DD2 save folder found, so no "
                           "automatic backup was made.")

    def record_undo(self, label, undo_fn):
        """Push an undo entry. undo_fn(client) re-applies previous values
        and returns a status string. Called from worker threads."""
        def _push():
            self._undo_stack.append((label, undo_fn))
            del self._undo_stack[:-10]
            try:
                self.undo_btn.configure(state="normal")
            except Exception:
                pass
        self.call_soon(_push)

    def undo_last(self, *_):
        client = self._client_or_msg()
        if not client or not self._undo_stack:
            if not self._undo_stack:
                self.set_status("Nothing to undo.")
            return
        label, undo_fn = self._undo_stack.pop()
        if not self._undo_stack:
            try:
                self.undo_btn.configure(state="disabled")
            except Exception:
                pass
        def _do():
            try:
                res = undo_fn(client)
                self.call_soon(lambda: (
                    self.set_status(f"Undid {label}: {res}"),
                    self.refresh_all_target()))
            except Exception as e:
                err = f"Undo failed: {e}"
                self.call_soon(lambda: self.set_status(err))
        run_async(self, _do)

    def confirm_bulk(self, title, what):
        """Yes/No confirm for bulk save-writing operations (main thread)."""
        return bool(messagebox.askyesno(title, what + "\n\nContinue?"))

    # -- sidecar cache (offline Item Giver / enums) ------------------------

    def _cache_path(self, name):
        ver = (self.client.bridge_version if self.client else None) \
            or BRIDGE_VERSION
        folder = os.path.join(config_dir(), "cache", ver)
        try:
            os.makedirs(folder, exist_ok=True)
        except OSError:
            pass
        return os.path.join(folder, name)

    def cache_sidecar(self, name, text):
        if not text:
            return
        try:
            with open(self._cache_path(name), "w", encoding="utf-8") as f:
                f.write(text)
        except OSError:
            pass

    def read_cached_sidecar(self, name):
        # Newest cached copy, whatever bridge version wrote it.
        root = os.path.join(config_dir(), "cache")
        best, best_mtime = None, -1
        try:
            versions = os.listdir(root)
        except OSError:
            return None
        for ver in versions:
            path = os.path.join(root, ver, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if mtime > best_mtime:
                best, best_mtime = path, mtime
        if not best:
            return None
        try:
            with open(best, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None

    # -- connection heartbeat ----------------------------------------------

    def _heartbeat_tick(self):
        try:
            client = self.client
            if client is not None:
                def _beat():
                    try:
                        client.ping(timeout=3)
                        self._hb_failures = 0
                        self.call_soon(lambda: self._set_conn_dot(True))
                    except Exception:
                        self._hb_failures += 1
                        if self._hb_failures >= 2:
                            self.call_soon(lambda: (
                                self._set_conn_dot(False),
                                self.set_status(
                                    "Connection lost - waiting for the "
                                    "game (auto-reconnect is on).")))
                run_async(self, _beat)
        finally:
            try:
                self.after(5000, self._heartbeat_tick)
            except Exception:
                pass

    # -- remembered UI state -------------------------------------------------

    def _ui_state_path(self):
        return os.path.join(config_dir(), "ui_state.json")

    def _load_ui_state(self):
        try:
            with open(self._ui_state_path(), "r", encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save_ui_state(self):
        try:
            state = {
                "geometry": self.geometry(),
                "tab": self._current_tab,
                "target": self.target_var.get() if hasattr(
                    self, "target_var") else None,
                "vocation": self.job_var.get() if hasattr(
                    self, "job_var") else None,
            }
            tmp = self._ui_state_path() + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(state, f)
            os.replace(tmp, self._ui_state_path())
        except (OSError, ValueError):
            pass

    def _restore_ui_state(self):
        state = self._ui_state
        geo = state.get("geometry") or ""
        if re.fullmatch(r"\d+x\d+\+\d+\+\d+", geo or ""):
            try:
                self.geometry(geo)
            except Exception:
                pass
        if state.get("target") in ("Main pawn", "Player (Arisen)"):
            self.target_var.set(state["target"])
        if state.get("vocation") in JOB_LABELS:
            self.job_var.set(state["vocation"])

    def _on_close(self):
        self._save_ui_state()
        self.destroy()

    # -- keyboard shortcuts ----------------------------------------------------

    def _shortcut_search(self):
        self.show_tab("Item Giver")
        frame = self._tab_frames.get("Item Giver")
        if frame is not None and hasattr(frame, "focus_search"):
            frame.focus_search()
        return "break"

    def _shortcut_refresh(self):
        frame = self._tab_frames.get(self._current_tab)
        if frame is not None:
            for name in ("refresh", "reload_async", "load_async",
                         "refresh_async"):
                fn = getattr(frame, name, None)
                if callable(fn):
                    fn()
                    break
        return "break"

    def _shortcut_escape(self):
        for child in self.winfo_children():
            if isinstance(child, ctk.CTkToplevel):
                child.destroy()
        return "break"
