"""Arisen's Toolbox - application shell.

Owns the window chrome (command bar, navigation rail, status bar), the
UI-thread dispatcher that worker threads marshal onto, and the session
state shared by the tabs.
"""
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
from bridge.protocol import BridgeError
from ui import theme as T
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
from ui.widgets import (
    JOB_LABELS, run_async, PrimaryButton, GhostButton, QuietButton, Combo,
    Pill, ScrollArea, Segmented, Tooltip,
)
from version import BRIDGE_VERSION, CLIENT_VERSION

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

log = logging.getLogger("arisens")


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
            return path
        handler.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)s [%(threadName)s] %(name)s: %(message)s"))
        root.addHandler(handler)
    return path


def _acquire_instance_lock():
    """Take the per-user single-instance lock; return the handle or None."""
    def _try_lock(path):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            handle = open(path, "a+")
        except OSError:
            return None
        try:
            if sys.platform == "win32":
                import msvcrt
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return None
        return handle

    handle = _try_lock(os.path.join(config_dir(), "instance.lock"))
    if handle is not None:
        return handle
    import tempfile
    fallback = _try_lock(os.path.join(
        tempfile.gettempdir(), "ArisensToolbox", "instance.lock"))
    if fallback is not None:
        log.warning("profile lock unavailable, using the temp-dir lock")
        return fallback
    return None


# Tabs hidden from the rail unless dev mode is on.
DEV_TABS = {"Level & Stats", "Stat Search"}

TABS = [
    ("Session", "Connection", ConnectionTab),
    ("Items", "Item Giver", ItemGiverTab),
    ("Items", "Item Editor", ItemEditorTab),
    ("Items", "Item Stats", ItemStatsTab),
    ("Items", "Duplicate Items", DuplicateItemsTab),
    ("Pawn", "Rating & Badges", PawnTab),
    ("Pawn", "Names", NamesTab),
    ("Character", "Weapon Skills", WeaponSkillsTab),
    ("Character", "Upgraded Skills", UpgradedSkillsTab),
    ("Character", "Core Skills & Augments", CoreAugmentsTab),
    ("Character", "Level & Stats", LevelStatsTab),
    ("Character", "Stat Search", StatSearchTab),
    ("Tools", "Mods", ModsTab),
]


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
        T.init(self)
        self._ui_queue = queue.Queue()
        self.client = client
        self.title("Arisen's Toolbox")
        self.geometry("1180x780")
        self.minsize(1024, 720)
        self.configure(fg_color=T.BG)
        self._set_window_icon()

        # Single instance: two windows would fight over cmd.txt/resp.txt.
        self._instance_lock = _acquire_instance_lock()
        if self._instance_lock is None:
            messagebox.showerror(
                "Arisen's Toolbox",
                "Arisen's Toolbox is already running. Two windows would "
                "fight over the same bridge files, so this one will close.")
            print("Arisen's Toolbox is already running "
                  "(instance lock held).", file=sys.stderr)
            self.destroy()
            raise SystemExit(1)

        # shared session state
        self.selected_item_row = None   # Item Editor <-> Item Stats
        self.selected_item_name = None
        self.enum_data = {}             # parsed enums, loaded on connect
        self._refreshables = []         # tabs with refresh()/refresh_skills()
        self.dev_mode = dev_mode()
        self._undo_stack = []
        self._current_tab = "Connection"
        self._hb_failures = 0
        self._hb_busy = False
        self._connected = False
        self._save_after = None
        self._ui_state = self._load_ui_state()

        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(1, weight=1)

        self._build_dispatch()

        self._build_command_bar()
        self._build_sidebar()
        self._build_content()
        self._build_statusbar()

        self._register_tabs()
        self._build_nav()
        self._install_excepthooks()
        if client is not None:
            # Embedders and tests can hand over a live client; wire it up the
            # same way the Connection tab does.
            self.set_client(client)
        self._restore_ui_state()
        self.show_tab(self._ui_state.get("tab") or "Connection")
        self._pump_after = self.after(30, self._pump_ui)
        self._hb_after = self.after(4000, self._heartbeat_tick)
        self.bind_all("<Control-f>", lambda e: self._shortcut_search())
        self.bind_all("<Control-F>", lambda e: self._shortcut_search())
        self.bind_all("<F5>", lambda e: self._shortcut_refresh())
        self.bind_all("<Escape>", lambda e: self._shortcut_escape())
        self.bind_all("<Control-z>", self._shortcut_undo)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # -- window chrome -------------------------------------------------

    def _set_window_icon(self):
        try:
            if getattr(sys, "frozen", False):
                icon = os.path.join(sys._MEIPASS, "assets", "icon.ico")
            else:
                icon = os.path.join(
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "assets", "icon.ico")
            if os.path.isfile(icon):
                self.iconbitmap(icon)
        except Exception:
            pass

    def _build_dispatch(self):
        pass

    def _build_command_bar(self):
        """One slim bar: who you are editing, plus the two global actions."""
        bar = ctk.CTkFrame(self, fg_color=T.SURFACE, corner_radius=0,
                           border_width=0)
        bar.grid(row=0, column=0, columnspan=2, sticky="ew")
        bar.grid_columnconfigure(6, weight=1)

        def label(text, col):
            ctk.CTkLabel(bar, text=text, font=T.font(T.SIZE_MICRO),
                         text_color=T.MUTED, anchor="w").grid(
                row=0, column=col, sticky="w", padx=(T.PAD_L if col == 0 else 12, 6),
                pady=T.PAD_M)

        label("EDITING", 0)
        self.target_var = ctk.StringVar(value="Main pawn")
        self.target_seg = Segmented(bar, ["Player", "Main pawn"],
                                    self.target_var, width=186,
                                    command=lambda _v: self._on_target_change())
        self.target_seg.grid(row=0, column=1, sticky="w", pady=T.PAD_S)

        label("VOCATION", 2)
        self.job_var = ctk.StringVar(value=JOB_LABELS[0])
        self.job_combo = Combo(
            bar, variable=self.job_var, values=JOB_LABELS, width=150,
            command=lambda _: self.refresh_skill_tabs())
        self.job_combo.grid(row=0, column=3, sticky="w", pady=T.PAD_S)

        label("PAWN", 4)
        self.pawn_var = ctk.StringVar(value="(not loaded)")
        self.pawn_combo = Combo(bar, variable=self.pawn_var,
                                values=["(not loaded)"], width=230,
                                command=self._on_pawn_pick)
        self.pawn_combo.grid(row=0, column=5, sticky="w", pady=T.PAD_S)
        self._pawn_idx = []
        quiet_reload = QuietButton(bar, "Reload", width=70,
                                   command=self.refresh_pawns)
        quiet_reload.grid(row=0, column=6, sticky="w", padx=(6, 0))
        Tooltip(quiet_reload, "Re-read the pawn list from the game.")

        actions = ctk.CTkFrame(bar, fg_color="transparent")
        actions.grid(row=0, column=7, sticky="e", padx=T.PAD_L)
        self.undo_btn = QuietButton(actions, "Undo", width=78,
                                    command=self.undo_last, state="disabled")
        self.undo_btn.pack(side="left", padx=(0, 4))
        Tooltip(self.undo_btn, "Re-applies the previous value of the last "
                              "edit that recorded one (rating, badges, "
                              "vocation, item edit, rename...).")
        GhostButton(actions, text="Use current", width=104,
                    command=self.use_current_vocation).pack(side="left", padx=4)
        PrimaryButton(actions, text="Set vocation", width=118,
                      command=self.set_vocation).pack(side="left", padx=(4, 0))

        edge = ctk.CTkFrame(self, height=1, fg_color=T.BORDER)
        edge.grid(row=0, column=0, columnspan=2, sticky="sew")

    def _build_sidebar(self):
        rail = ctk.CTkFrame(self, width=T.SIDEBAR_WIDTH, corner_radius=0,
                            fg_color=T.SIDEBAR)
        rail.grid(row=1, column=0, sticky="nsew")
        rail.grid_propagate(False)
        rail.grid_columnconfigure(0, weight=1)
        rail.grid_rowconfigure(1, weight=1)
        self.sidebar = rail

        brand = ctk.CTkFrame(rail, fg_color="transparent", width=1, height=1)
        brand.grid(row=0, column=0, sticky="ew", padx=T.PAD_L,
                   pady=(T.PAD_L + 4, T.PAD_S))
        ctk.CTkLabel(brand, text="Arisen's Toolbox",
                     font=T.font(T.SIZE_TITLE, "bold"),
                     text_color=T.TEXT, anchor="w").pack(anchor="w")
        ctk.CTkLabel(brand, text="Dragon's Dogma 2 companion",
                     font=T.font(T.SIZE_MICRO), text_color=T.FAINT,
                     anchor="w").pack(anchor="w", pady=(1, 0))

        # The rail scrolls when the window is short: thirteen entries plus
        # five category labels do not fit 660 px.
        self.nav = ScrollArea(rail, fg_color=T.SIDEBAR, trough=T.SIDEBAR)
        self.nav.grid(row=1, column=0, sticky="nsew")

        self._nav_start_row = 0
        self._nav_buttons = {}
        self._nav_bars = {}

    def _build_content(self):
        self.content = ctk.CTkFrame(self, corner_radius=0, fg_color=T.BG)
        self.content.grid(row=1, column=1, sticky="nsew",
                          padx=(T.PAD_XL, T.PAD_XL), pady=(T.PAD_L, T.PAD_S))
        self.content.grid_columnconfigure(0, weight=1)
        self.content.grid_rowconfigure(0, weight=1)

    def _build_statusbar(self):
        wrapper = ctk.CTkFrame(self, fg_color=T.SIDEBAR, corner_radius=0)
        wrapper.grid(row=2, column=0, columnspan=2, sticky="ew")
        wrapper.grid_columnconfigure(1, weight=1)

        bar = ctk.CTkFrame(wrapper, fg_color=T.SIDEBAR, corner_radius=0,
                           height=30)
        bar.grid(row=1, column=0, columnspan=2, sticky="ew", padx=T.PAD_L)
        bar.grid_columnconfigure(2, weight=1)

        self.conn_pill = Pill(bar, "Offline", "muted")
        self.conn_pill.grid(row=0, column=0, sticky="w", pady=4)

        self.save_hint = ctk.CTkLabel(
            bar, text="Save backup: on the first change",
            font=T.font(T.SIZE_MICRO), text_color=T.FAINT)
        self.save_hint.grid(row=0, column=1, sticky="w", padx=(10, 0))

        self.status_var = ctk.StringVar(value="Ready.")
        self.statusbar = ctk.CTkLabel(
            bar, textvariable=self.status_var, anchor="w",
            font=T.font(T.SIZE_MICRO), text_color=T.MUTED)
        self.statusbar.grid(row=0, column=2, sticky="ew", padx=T.PAD_M)

        ctk.CTkLabel(bar, text=f"v{CLIENT_VERSION}  ·  bridge {BRIDGE_VERSION}",
                     font=T.font(T.SIZE_MICRO), text_color=T.FAINT).grid(
            row=0, column=3, sticky="e")

        ctk.CTkFrame(wrapper, height=1, fg_color=T.BORDER).grid(
            row=0, column=0, columnspan=2, sticky="ew")

    # -- navigation -----------------------------------------------------

    def _register_tabs(self):
        self.tabs = TABS
        self._tab_frames = {label: None for _cat, label, _f in self.tabs}

    def _build_nav(self):
        row = self._nav_start_row
        last_cat = None
        visible = [(c, l, f) for c, l, f in self.tabs
                   if l not in DEV_TABS or self.dev_mode]
        for cat, label, _ in visible:
            if cat != last_cat:
                ctk.CTkLabel(self.nav, text=cat.upper(),
                             font=T.font(T.SIZE_MICRO, "bold"),
                             text_color=T.FAINT, anchor="w").grid(
                    row=row, column=0, sticky="w", padx=T.PAD_L + 2,
                    pady=(T.PAD_S if last_cat else T.PAD_XS, 2))
                row += 1
                last_cat = cat
            row += self._nav_item(row, label)

        footer = ctk.CTkFrame(self.sidebar, fg_color="transparent",
                              width=1, height=1)
        footer.grid(row=2, column=0, sticky="ew", padx=T.PAD_L,
                    pady=(0, T.PAD_M))
        if self.dev_mode:
            ctk.CTkLabel(footer, text="Developer mode",
                         font=T.font(T.SIZE_MICRO), text_color=T.ACCENT,
                         anchor="w").pack(anchor="w")

    def _nav_item(self, row, label):
        holder = ctk.CTkFrame(self.nav, fg_color="transparent", height=30,
                              width=1)
        holder.grid(row=row, column=0, sticky="ew", padx=T.PAD_S, pady=1)
        holder.grid_columnconfigure(1, weight=1)
        bar = ctk.CTkFrame(holder, width=3, height=16, fg_color="transparent",
                           corner_radius=2)
        bar.grid(row=0, column=0, sticky="w", padx=(0, 5))
        btn = ctk.CTkButton(
            holder, text=label, anchor="w", height=28,
            corner_radius=T.RADIUS_CONTROL, fg_color="transparent",
            hover_color=T.SURFACE2, text_color=T.MUTED,
            font=T.font(T.SIZE_BODY),
            command=lambda l=label: self.show_tab(l))
        btn.grid(row=0, column=1, sticky="ew")
        self._nav_buttons[label] = btn
        self._nav_bars[label] = bar
        return 1

    def show_tab(self, label):
        if label not in self._tab_frames:
            label = "Connection"
        self._current_tab = label
        self._schedule_save()
        for frame in self._tab_frames.values():
            if frame is not None:
                frame.grid_forget()
        frame = self._tab_frames[label]
        if frame is None:
            factory = next(f for _c, l, f in self.tabs if l == label)
            try:
                frame = factory(self.content, self)
            except Exception:
                log.exception("could not build the %s tab", label)
                self.set_status(f"The {label} tab failed to open - see the log.")
                return
            self._tab_frames[label] = frame
        frame.grid(row=0, column=0, sticky="nsew")
        for name, btn in self._nav_buttons.items():
            active = name == label
            btn.configure(
                fg_color=T.ACCENT_DIM if active else "transparent",
                text_color=T.TEXT if active else T.MUTED,
                font=T.font(T.SIZE_BODY, "bold") if active
                else T.font(T.SIZE_BODY))
            self._nav_bars[name].configure(
                fg_color=T.ACCENT if active else "transparent")

    # -- UI thread dispatcher ------------------------------------------

    def call_soon(self, fn, *args):
        """Queue a callback to run on the Tk main thread."""
        self._ui_queue.put((fn, args))

    def _pump_ui(self):
        for _ in range(200):
            try:
                fn, args = self._ui_queue.get_nowait()
            except queue.Empty:
                break
            try:
                fn(*args)
            except Exception:
                log.exception("UI callback failed")
        try:
            self._pump_after = self.after(30, self._pump_ui)
        except Exception:
            pass

    def _install_excepthooks(self):
        def _hook(exc_type, exc, tb):
            log.error("uncaught exception", exc_info=(exc_type, exc, tb))
            import traceback as _tb
            _tb.print_exception(exc_type, exc, tb)
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

    # -- target / vocation / pawn actions --------------------------------

    def target(self):
        return "player" if self.target_var.get() == "Player" else "pawn"

    def job(self):
        try:
            return JOB_LABELS.index(self.job_var.get()) + 1
        except ValueError:
            return 1

    def _on_target_change(self):
        self._schedule_save()
        self.refresh_all_target()

    def _client_or_msg(self):
        if not self.client:
            self.set_status("Not connected - open Connection and press Start.")
            return None
        return self.client

    def use_current_vocation(self):
        client = self._client_or_msg()
        if not client:
            return

        def _do():
            try:
                res = client.send("get_info", self.target(), timeout=10)
                m = re.match(r"^(\d+),", res or "")
                j = int(m.group(1)) if m else 0
                if 1 <= j <= 10:
                    def _apply():
                        self.job_var.set(JOB_LABELS[j - 1])
                        self._schedule_save()
                        self.refresh_skill_tabs()
                    self.call_soon(_apply)
                else:
                    self.call_soon(self.set_status,
                                   f"Vocation unknown: {res}")
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(self.set_status, err)
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
            prev = None
            try:
                info = client.send("get_info", tgt, timeout=10)
                m = re.match(r"^(\d+),", info or "")
                if m:
                    prev = int(m.group(1))
            except Exception:
                pass
            try:
                res = client.send("set_vocation", tgt, j, timeout=15)
                if prev and prev != j:
                    self.record_undo(
                        f"vocation {prev}",
                        lambda c, t=tgt, p=prev: c.send(
                            "set_vocation", t, p, timeout=15))
                self.call_soon(self._after_vocation, res)
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(self.set_status, err)
        run_async(self, _do)

    def _after_vocation(self, res):
        self.set_status(f"Vocation set: {res}")
        self.refresh_all_target()

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
                res = client.send("unlock_all_vocations", self.target(),
                                  timeout=15)
                self.call_soon(self.set_status, res)
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(self.set_status, err)
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
                            labels.append(f"{lab.strip()}")
                self.call_soon(self._set_pawns, idx, labels)
            except Exception as e:
                err = f"Pawn list: {e}"
                self.call_soon(self.set_status, err)
        run_async(self, _do)

    def _set_pawns(self, idx, labels):
        self._pawn_idx = idx
        if labels:
            # Two pawns can share a name; keep the labels unique so the
            # selected value still maps to exactly one entry.
            seen = {}
            unique = []
            for name in labels:
                seen[name] = seen.get(name, 0) + 1
                unique.append(name if seen[name] == 1
                              else f"{name} ({seen[name]})")
            self.pawn_combo.configure(values=unique)
            self.pawn_var.set(unique[0])
            self.set_status(f"{len(unique)} pawn(s) found.")
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
                self.call_soon(self._after_pawn_pick, res)
            except Exception as e:
                err = f"Error: {e}"
                self.call_soon(self.set_status, err)
        run_async(self, _do)

    def _after_pawn_pick(self, res):
        self.set_status(f"Now editing {res}")
        if self.target() == "pawn":
            self.refresh_all_target()
        frame = self._tab_frames.get("Rating & Badges")
        if frame and hasattr(frame, "refresh"):
            frame.refresh()

    # -- refreshable tabs ----------------------------------------------

    def register_refreshable(self, tab):
        self._refreshables.append(tab)

    def refresh_skill_tabs(self):
        for tab in self._refreshables:
            if hasattr(tab, "refresh_skills"):
                tab.refresh_skills()

    def refresh_all_target(self):
        self.refresh_skill_tabs()
        for tab in self._refreshables:
            if hasattr(tab, "refresh_all"):
                tab.refresh_all()

    # -- status / connection -------------------------------------------

    def set_status(self, text):
        if hasattr(self, "status_var"):
            self.status_var.set(text)

    def set_client(self, client):
        self.client = client
        if client is not None:
            # Back the save up before this session's first mutation.
            client.on_before_first_mutation = self._ensure_save_backup
            client.on_session_changed = self._on_session_changed
            self._hb_failures = 0
            # May be called from a worker thread (Connection tab), so touch
            # widgets through the dispatcher only.
            self.call_soon(lambda: self._set_connected(True))

    def _set_connected(self, connected):
        self._connected = connected
        try:
            if connected:
                self.conn_pill.set("Connected", "ok")
                self.save_hint.configure(
                    text="Save backup: before the first change")
            else:
                self.conn_pill.set("Offline", "muted")
                self.save_hint.configure(
                    text="Save backup: starts when connected")
        except Exception:
            pass

    # -- save protection / undo / bulk confirm --------------------------

    def _ensure_save_backup(self, command):
        """Protocol hook (worker thread): back up saves before mutating.

        Three outcomes: a backup was made; no save folder exists (warn, but
        proceed); a save folder exists but copying failed (abort the
        command - failing open made the whole net decorative).
        """
        log = logging.getLogger("arisens.safety")
        try:
            remotes = safety.find_save_remote_dirs()
        except Exception:
            log.exception("save discovery failed; proceeding with warning")
            remotes = None
        if remotes is not None and not remotes:
            log.warning("no DD2 save folder found; %s proceeds unbacked",
                        command)
            self.call_soon(
                self.set_status,
                "Warning: no DD2 save folder found, so this change has "
                "NO automatic backup.")
            return
        try:
            dest = safety.backup_saves()
        except Exception as e:
            log.exception("save backup copy failed")
            raise BridgeError(
                f"Save backup FAILED ({e}) - '{command}' was NOT sent. "
                "Free disk space or back up manually from Connection.")
        if dest:
            self.call_soon(self.set_status,
                           f"Save backed up before '{command}': {dest}")

    def _on_session_changed(self):
        """The game restarted: undo entries belong to the old session."""
        def _clear():
            self._undo_stack.clear()
            try:
                self.undo_btn.configure(state="disabled")
            except Exception:
                pass
            self.set_status(
                "Game restarted - undo history cleared; the next change "
                "takes a fresh save backup first.")
        self.call_soon(_clear)

    def record_undo(self, label, undo_fn):
        """Push an undo entry. undo_fn(client) re-applies previous values."""
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
        if not client:
            return
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
                self.call_soon(self._after_undo, label, res)
            except Exception as e:
                err = f"Undo failed: {e}"
                self.call_soon(self.set_status, err)
        run_async(self, _do)

    def _after_undo(self, label, res):
        self.set_status(f"Undid {label}: {res}")
        self.refresh_all_target()

    def confirm_bulk(self, title, what):
        """Yes/No confirm for bulk save-writing operations (main thread)."""
        return bool(messagebox.askyesno(title, what + "\n\nContinue?"))

    # -- sidecar cache (offline Item Giver / enums) ---------------------

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
        """Newest cached copy, whichever bridge version wrote it."""
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

    # -- heartbeat ------------------------------------------------------

    def _heartbeat_tick(self):
        client = self.client
        if client is not None and not self._hb_busy:
            self._hb_busy = True

            def _beat():
                try:
                    # A skipped beat (False) is not a connection failure.
                    pong = client.try_ping(timeout=2)
                finally:
                    self._hb_busy = False
                if pong is False:
                    return
                if pong:
                    self._hb_failures = 0
                    self.call_soon(lambda: self._set_connected(True))
                else:
                    self._hb_failures += 1
                    if self._hb_failures >= 2:
                        self.call_soon(lambda: (
                            self._set_connected(False),
                            self.set_status(
                                "Connection lost - waiting for the game "
                                "(auto-reconnect is on).")))
            run_async(self, _beat)
        delay = 4000 if self._connected else 10000
        try:
            self._hb_after = self.after(delay, self._heartbeat_tick)
        except Exception:
            pass

    # -- remembered UI state -------------------------------------------

    def _ui_state_path(self):
        return os.path.join(config_dir(), "ui_state.json")

    def _load_ui_state(self):
        try:
            with open(self._ui_state_path(), "r", encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _schedule_save(self):
        """Coalesce disk writes: switching tabs should not touch the disk."""
        if self._save_after is not None:
            try:
                self.after_cancel(self._save_after)
            except Exception:
                pass
        try:
            self._save_after = self.after(600, self._save_ui_state)
        except Exception:
            self._save_after = None

    def _save_ui_state(self):
        self._save_after = None
        state = {
            "geometry": self.geometry(),
            "tab": self._current_tab,
            "target": (self.target_var.get()
                       if hasattr(self, "target_var") else None),
            "vocation": (self.job_var.get()
                         if hasattr(self, "job_var") else None),
        }
        try:
            tmp = self._ui_state_path() + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(state, f)
            os.replace(tmp, self._ui_state_path())
        except (OSError, ValueError):
            pass

    def _restore_ui_state(self):
        state = self._ui_state
        geo = state.get("geometry") or ""
        m = re.fullmatch(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)", geo)
        if m:
            w, h, x, y = (int(v) for v in m.groups())
            # Never restore a window onto a monitor that no longer exists.
            sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
            w, h = max(1024, min(w, sw)), max(720, min(h, sh))
            x = max(0, min(x, sw - 200))
            y = max(0, min(y, sh - 120))
            try:
                self.geometry(f"{w}x{h}+{x}+{y}")
            except Exception:
                pass
        if state.get("target") in ("Player", "Main pawn"):
            self.target_var.set(state["target"])
        if state.get("vocation") in JOB_LABELS:
            self.job_var.set(state["vocation"])

    def _on_close(self):
        # Cancel pending timers first: destroying the window with an
        # "after" script still queued makes Tk print
        # 'invalid command name ...' on the way out.
        for attr in ("_pump_after", "_hb_after", "_save_after"):
            job = getattr(self, attr, None)
            if job is not None:
                try:
                    self.after_cancel(job)
                except Exception:
                    pass
                setattr(self, attr, None)
        self._save_ui_state()
        lock = getattr(self, "_instance_lock", None)
        if lock is not None and lock is not True:
            try:
                lock.close()
            except Exception:
                pass
        self.destroy()

    # -- keyboard shortcuts ---------------------------------------------

    def _shortcut_undo(self, _event=None):
        try:
            focused = self.focus_get()
        except Exception:
            focused = None
        if focused is not None and focused.winfo_class() in (
                "Entry", "Text", "TEntry", "TText", "Spinbox", "TSpinbox",
                "TCombobox"):
            return
        self.undo_last()
        return "break"

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
