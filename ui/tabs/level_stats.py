"""Level & Stats: level, vocation EXP, favorability, base stat values."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ListPanel, Field, PrimaryButton, GhostButton,
    QuietButton, run_async, require_client,
)


class LevelStatsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.c_rows = []  # [(gi, field)] for the base-stat list
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(3, weight=1)
        app.register_refreshable(self)

        PageHeader(
            self, "Level & Stats",
            "Level, vocation EXP and the base values the game calculates "
            "everything else from.").grid(row=0, column=0, sticky="ew",
                                          pady=(0, T.PAD_L))

        level = Section(self, "Level & EXP", **{"row": 1, "column": 0,
                                               "sticky": "ew",
                                               "pady": (0, T.PAD_M)})
        body = level.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(row, text="Level", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.level_var = ctk.StringVar(value="1")
        Field(row, textvariable=self.level_var, width=64).pack(side="left")
        QuietButton(row, "Read", width=64,
                    command=self.read_level_async).pack(side="left",
                                                        padx=(T.PAD_S, 0))
        PrimaryButton(row, "Apply", width=80,
                      command=self.apply_level_async).pack(side="left",
                                                           padx=(T.PAD_S, 0))
        ctk.CTkLabel(row, text="Vocation EXP",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_XL, T.PAD_S))
        self.exp_var = ctk.StringVar(value="10000")
        Field(row, textvariable=self.exp_var, width=88).pack(side="left")
        GhostButton(row, "Add to current vocation", width=170,
                    command=self.add_exp_async).pack(side="left",
                                                     padx=(T.PAD_S, 0))

        fav = Section(self, "Favorability",
                      hint="Main pawn only - the bridge targets the pawn.",
                      **{"row": 2, "column": 0, "sticky": "ew",
                         "pady": (0, T.PAD_M)})
        body = fav.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="ew")
        self.fav_var = ctk.StringVar(value="0")
        Field(row, textvariable=self.fav_var, width=80).pack(side="left")
        QuietButton(row, "Read", width=64,
                    command=self.read_fav_async).pack(side="left",
                                                      padx=(T.PAD_S, 0))
        PrimaryButton(row, "Apply", width=80,
                      command=self.apply_fav_async).pack(side="left",
                                                         padx=(T.PAD_S, 0))

        stats = Section(self, "Base stats",
                        hint="The game recalculates totals from these; Set + "
                             "lock re-applies the value every frame.",
                        **{"row": 3, "column": 0, "sticky": "nsew"})
        body = stats.body
        body.grid_rowconfigure(0, weight=1)
        self.panel = ListPanel(body, height=9,
                               empty="Read the character's base values.")
        self.panel.grid(row=0, column=0, sticky="nsew", padx=(0, T.PAD_M))
        self.clist = self.panel.listbox

        controls = ctk.CTkFrame(body, fg_color="transparent", width=1, height=1)
        controls.grid(row=0, column=1, sticky="ns")
        controls.grid_columnconfigure(0, weight=1)
        GhostButton(controls, "Read", width=160,
                    command=self.read_stats_async).grid(row=0, column=0,
                                                        sticky="ew")
        ctk.CTkLabel(controls, text="New value",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                     anchor="w").grid(row=1, column=0, sticky="w",
                                      pady=(T.PAD_M, 2))
        self.val_var = ctk.StringVar(value="0")
        Field(controls, textvariable=self.val_var, width=160).grid(
            row=2, column=0, sticky="ew")
        PrimaryButton(controls, "Set selected", width=160,
                      command=lambda: self.set_stat_async(False)).grid(
            row=3, column=0, sticky="ew", pady=(T.PAD_S, 0))
        QuietButton(controls, "Set + lock", width=160,
                    command=lambda: self.set_stat_async(True)).grid(
            row=4, column=0, sticky="ew", pady=(T.PAD_XS, 0))
        QuietButton(controls, "Clear all locks", width=160,
                    command=self.clear_locks_async).grid(
            row=5, column=0, sticky="ew", pady=(T.PAD_XS, 0))

    # -- level ----------------------------------------------------------

    def _num(self, var, what):
        try:
            return int(var.get())
        except ValueError:
            self.app.set_status(f"Enter a number for {what}.")
            return None

    def read_level_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_read_level(client, tgt))

    def _do_read_level(self, client, tgt):
        try:
            res = client.send("get_info", tgt, timeout=15)
            # "job,level,..."
            parts = res.split(",", 1)
            job_s = parts[0] if parts else "?"
            lvl_s = parts[1].split(",")[0] if len(parts) > 1 else "?"
            if lvl_s.isdigit():
                self.after(0, lambda: self.level_var.set(lvl_s))
            self.after(0, lambda: self.app.set_status(
                f"Vocation {job_s}, level {lvl_s}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_level_async(self):
        client = require_client(self.app)
        if not client:
            return
        v = self._num(self.level_var, "level")
        if v is None:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_simple(
            client, "set_level", (tgt, v), "Level applied."))

    def add_exp_async(self):
        client = require_client(self.app)
        if not client:
            return
        v = self._num(self.exp_var, "EXP")
        if v is None:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_simple(
            client, "add_job_exp", (tgt, v), "EXP added."))

    # -- favorability -----------------------------------------------------

    def read_fav_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_read_fav(client))

    def _do_read_fav(self, client):
        try:
            res = client.send("get_fav", timeout=15)  # no args; pawn only

            def _ui():
                self.fav_var.set(res.strip())
                self.app.set_status("Favorability read.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_fav_async(self):
        client = require_client(self.app)
        if not client:
            return
        v = self._num(self.fav_var, "favorability")
        if v is None:
            return
        run_async(self, lambda: self._do_simple(
            client, "set_fav", (v,), "Favorability applied."))

    # -- base stats -------------------------------------------------------

    def read_stats_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_read_stats(client, tgt))

    def _do_read_stats(self, client, tgt, quiet=False):
        try:
            client.send("get_core", tgt, timeout=30)
            text = client.read_sidecar("core.txt") or ""
            rows = []
            for line in text.splitlines():
                # gi \t title \t field \t label \t value
                parts = line.split("\t", 4)
                if len(parts) == 5 and parts[0].isdigit():
                    gi, title, field, label, value = parts
                    rows.append((int(gi), title, field, label, value))
            self.after(0, lambda: self._apply_stats(rows, quiet))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _apply_stats(self, rows, quiet):
        keep = self.clist.curselection()
        self.c_rows = []
        labels = []
        for gi, title, field, label, value in rows:
            self.c_rows.append((gi, field))
            labels.append(f"[{title}] {label} = {value}")
        self.panel.set_rows(labels)
        self.panel.set_empty("No base values reported.")
        if keep and keep[0] < len(self.c_rows):
            self.clist.selection_set(keep[0])
        if not quiet:
            self.app.set_status(f"Read {len(self.c_rows)} base values.")

    def set_stat_async(self, lock):
        client = require_client(self.app)
        if not client:
            return
        sel = self.clist.curselection()
        if not sel or sel[0] >= len(self.c_rows):
            self.app.set_status("Select a value first.")
            return
        v = self._num(self.val_var, "new value")
        if v is None:
            return
        gi, field = self.c_rows[sel[0]]
        tgt = self.app.target()
        lock_s = "1" if lock else "0"
        run_async(self, lambda: self._do_set_stat(client, tgt, gi, field, v,
                                                  lock_s))

    def _do_set_stat(self, client, tgt, gi, field, v, lock_s):
        try:
            # wire order: target, group, field, value, lock
            client.send("set_core", tgt, gi, field, v, lock_s, timeout=15)
            self.after(0, lambda: self.app.set_status(
                "Set and locked." if lock_s == "1" else "Set."))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self._do_read_stats(client, tgt, quiet=True)

    def clear_locks_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_simple(
            client, "clear_locks", (), None,
            after_msg=lambda n: f"Cleared {n} lock(s)."))

    # -- shared -----------------------------------------------------------

    def _do_simple(self, client, cmd, args, ok_msg, after_msg=None):
        try:
            res = client.send(cmd, *args, timeout=15)
            msg = after_msg(res) if after_msg else (ok_msg or res)
            self.after(0, lambda: self.app.set_status(msg))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def refresh_all(self):
        self.read_level_async()
        self.read_stats_async()
