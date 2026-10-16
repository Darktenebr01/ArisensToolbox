"""Arisen's Toolbox standalone client - main window."""
import os
import sys
import threading
import customtkinter as ctk

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
from ui.tabs.signatures import SignaturesTab
from ui.widgets import JOB_LABELS, run_async, PrimaryButton, GhostButton, Combo
from ui import theme as T

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

CLIENT_VERSION = "0.90"

# Tabs hidden from the sidebar in normal use (still importable/shown by code).
DEV_TABS = {"Level & Stats", "Stat Search", "Signatures"}


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

        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(1, weight=1)

        self._build_header()
        self._build_sidebar()
        self._build_content()
        self._build_statusbar()

        self._register_tabs()
        self._build_nav()
        self.show_tab("Connection")

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
        GhostButton(h, text="Unlock all", width=90,
                    command=self.unlock_all_vocations).grid(row=0, column=6, padx=2, pady=8)

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
                    self.after(0, lambda: (
                        self.job_var.set(JOB_LABELS[j - 1]),
                        self.refresh_skill_tabs(),
                    ))
                else:
                    self.after(0, lambda: self.set_status(f"Vocation unknown: {res}"))
            except Exception as e:
                err = f"Error: {e}"
                self.after(0, lambda: self.set_status(err))
        run_async(self, _do)

    def set_vocation(self):
        client = self._client_or_msg()
        if not client:
            return
        j = self.job()
        if self.target() == "pawn" and j > 6:
            self.set_status("Pawns can only use vocations 1-6.")
            return
        def _do():
            try:
                res = client.send("set_vocation", self.target(), j, timeout=15)
                self.after(0, lambda: (self.set_status(f"Vocation set: {res}"),
                                       self.refresh_all_target()))
            except Exception as e:
                err = f"Error: {e}"
                self.after(0, lambda: self.set_status(err))
        run_async(self, _do)

    def unlock_all_vocations(self):
        client = self._client_or_msg()
        if not client:
            return
        def _do():
            try:
                res = client.send("unlock_all_vocations", self.target(), timeout=15)
                self.after(0, lambda: self.set_status(res))
            except Exception as e:
                err = f"Error: {e}"
                self.after(0, lambda: self.set_status(err))
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
                self.after(0, lambda: self._set_pawns(idx, labels))
            except Exception as e:
                err = f"Pawn list: {e}"
                self.after(0, lambda: self.set_status(err))
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
                self.after(0, lambda: self._after_pawn_pick(res))
            except Exception as e:
                err = f"Error: {e}"
                self.after(0, lambda: self.set_status(err))
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
        self.status_var = ctk.StringVar(value="Not connected.")
        self.statusbar = ctk.CTkLabel(
            self, textvariable=self.status_var, anchor="w", height=24,
            font=(T.FONT_FAMILY, 11), text_color=T.MUTED,
        )
        self.statusbar.grid(row=2, column=0, columnspan=2, sticky="ew", padx=12, pady=(0, 4))

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
            ("TOOLS", "Signatures", SignaturesTab),
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
            self.sidebar, text=f"v{CLIENT_VERSION}",
            font=(T.FONT_FAMILY, 10), text_color=T.FAINT,
        ).grid(row=99, column=0, sticky="sw", padx=14, pady=10)

    def show_tab(self, label):
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
        self.status_var.set(text)

    def set_client(self, client):
        self.client = client
