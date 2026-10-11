"""Level & Stats tab: level, vocation EXP, favorability, base stat values."""
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    run_async, require_client,
    Card, card_content, H1, H2, Muted,
    PrimaryButton, GhostButton, Field, StyledListbox,
)


class LevelStatsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.c_rows = []  # [(gi, field)] for the base-stat list
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(3, weight=1)
        app.register_refreshable(self)

        H1(self, "Level & Stats", row=0, column=0, sticky="w", pady=(0, 8))

        # level card
        lvl_card = Card(self, row=1, column=0, sticky="ew", padx=4, pady=6)
        lrow = card_content(lvl_card)
        ctk.CTkLabel(lrow, text="Level:", text_color=T.TEXT).grid(
            row=0, column=0, sticky="w")
        self.level_var = ctk.StringVar(value="1")
        Field(lrow, textvariable=self.level_var, width=70).grid(
            row=0, column=1, sticky="w", padx=4)
        GhostButton(lrow, "Read", command=self.read_level_async,
                    width=70).grid(row=0, column=2, padx=4)
        PrimaryButton(lrow, "Apply", command=self.apply_level_async,
                      width=70).grid(row=0, column=3, padx=4)
        ctk.CTkLabel(lrow, text="Vocation EXP:", text_color=T.TEXT).grid(
            row=0, column=4, sticky="w", padx=(24, 0))
        self.exp_var = ctk.StringVar(value="10000")
        Field(lrow, textvariable=self.exp_var, width=80).grid(
            row=0, column=5, sticky="w", padx=4)
        PrimaryButton(lrow, "Add to current vocation", command=self.add_exp_async,
                      width=180).grid(row=0, column=6, padx=4)

        # favorability card (pawn only - the lua hardcodes the pawn target)
        fav_card = Card(self, row=2, column=0, sticky="ew", padx=4, pady=6)
        frow = card_content(fav_card)
        ctk.CTkLabel(frow, text="Favorability (main pawn only):",
                     text_color=T.TEXT).grid(row=0, column=0, sticky="w")
        self.fav_var = ctk.StringVar(value="0")
        Field(frow, textvariable=self.fav_var, width=80).grid(
            row=0, column=1, sticky="w", padx=4)
        GhostButton(frow, "Read", command=self.read_fav_async,
                    width=70).grid(row=0, column=2, padx=4)
        PrimaryButton(frow, "Apply", command=self.apply_fav_async,
                      width=70).grid(row=0, column=3, padx=4)

        # base stats card
        stat_card = Card(self, row=3, column=0, sticky="nsew", padx=4, pady=6)
        brow = card_content(stat_card)
        brow.grid_columnconfigure(0, weight=1)
        brow.grid_rowconfigure(1, weight=1)
        H2(brow, "Base stats", row=0, column=0, columnspan=3, sticky="w")
        Muted(brow, "Game recalculates totals from these; Set + lock re-applies every frame.",
              row=1, column=0, columnspan=3, sticky="w", pady=(0, 6))
        self.clist = StyledListbox(brow)
        self.clist.grid(row=2, column=0, sticky="nsew")
        sb = tk.Scrollbar(brow, orient="vertical", command=self.clist.yview)
        sb.grid(row=2, column=1, sticky="ns")
        self.clist.config(yscrollcommand=sb.set)

        scol = ctk.CTkFrame(brow, fg_color="transparent")
        scol.grid(row=2, column=2, sticky="ns", padx=(8, 0))
        GhostButton(scol, "Read", command=self.read_stats_async,
                    width=170).pack(pady=3)
        ctk.CTkLabel(scol, text="New value:", text_color=T.TEXT).pack(pady=(8, 2), anchor="w")
        self.val_var = ctk.StringVar(value="0")
        Field(scol, textvariable=self.val_var, width=170).pack(pady=3)
        PrimaryButton(scol, "Set selected",
                      command=lambda: self.set_stat_async(False),
                      width=170).pack(pady=3)
        GhostButton(scol, "Set + lock",
                    command=lambda: self.set_stat_async(True),
                    width=170).pack(pady=3)
        GhostButton(scol, "Clear all locks", command=self.clear_locks_async,
                    width=170).pack(pady=3)

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
            # "job,level,..." - CE table parses ^([^,]*),(.*)$
            parts = res.split(",", 1)
            job_s = parts[0] if parts else "?"
            lvl_s = parts[1].split(",")[0] if len(parts) > 1 else "?"
            try:
                int(lvl_s)
                self.after(0, lambda: self.level_var.set(lvl_s))
            except ValueError:
                pass
            self.after(0, lambda: self.app.set_status(
                f"Vocation {job_s}, level {lvl_s}"))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            self.after(0, lambda: (
                self.fav_var.set(res.strip()),
                self.app.set_status("Favorability read."),
            ))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def apply_fav_async(self):
        client = require_client(self.app)
        if not client:
            return
        v = self._num(self.fav_var, "favorability")
        if v is None:
            return
        run_async(self, lambda: self._do_simple(
            client, "set_fav", (v,), "Favorability applied."))  # no target arg

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def _apply_stats(self, rows, quiet):
        keep = self.clist.curselection()
        self.clist.delete(0, tk.END)
        self.c_rows = []
        for gi, title, field, label, value in rows:
            self.c_rows.append((gi, field))
            self.clist.insert(tk.END, f"[{title}] {label} = {value}")
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
        run_async(self, lambda: self._do_set_stat(client, tgt, gi, field, v, lock_s))

    def _do_set_stat(self, client, tgt, gi, field, v, lock_s):
        try:
            # wire order: target, group, field, value, lock
            client.send("set_core", tgt, gi, field, v, lock_s, timeout=15)
            self.after(0, lambda: self.app.set_status(
                "Set and locked." if lock_s == "1" else "Set."))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def refresh_all(self):
        self.read_level_async()
        self.read_stats_async()
