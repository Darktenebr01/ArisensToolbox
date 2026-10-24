"""Stat Search: filter every numeric field of the character's contexts."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ListPanel, Field, Combo, PrimaryButton,
    GhostButton, QuietButton, caption, run_async, require_client,
)

PRESETS = [
    ("Health", "hp,health,vital"),
    ("Stamina", "stamina"),
    ("Strength", "atk,attack,power,str"),
    ("Defense", "def"),
    ("Magick", "magic,mag"),
    ("Knockdown", "down,stagger,knock,blow"),
    ("Slash/Strike", "slash,strike,cut,blunt"),
    ("Encumbrance", "weight,encumb,burden,load"),
    ("Resistances", "regist,resist"),
    ("Elements", "fire,ice,thunder,elem,dark,light"),
    ("Debilitations", "poison,sleep,silence,curse,torpor,blind,stun,debuff,"
                      "abnormal"),
    ("Base values", "base"),
]

MAX_ROWS = 150


class StatSearchTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.f_rows = []  # [(si, kind, name)] for the results list
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)
        app.register_refreshable(self)

        PageHeader(
            self, "Stat Search",
            "Filter every numeric field the character exposes, then set or "
            "lock one by name.").grid(row=0, column=0, sticky="ew",
                                      pady=(0, T.PAD_L))

        search = Section(self, "Filter", **{"row": 1, "column": 0,
                                            "sticky": "ew",
                                            "pady": (0, T.PAD_M)})
        body = search.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(row, text="Preset", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.preset_var = ctk.StringVar(value=PRESETS[0][0])
        self.preset_combo = Combo(row, variable=self.preset_var,
                                  values=[p[0] for p in PRESETS], width=170,
                                  command=self._on_preset)
        self.preset_combo.pack(side="left")
        self.filter_var = ctk.StringVar(value=PRESETS[0][1])
        Field(row, textvariable=self.filter_var, width=320).pack(
            side="left", padx=(T.PAD_M, 0))
        PrimaryButton(row, "Search", width=110,
                      command=self.search_async).pack(side="left",
                                                       padx=(T.PAD_M, 0))
        caption(body, "Words are comma separated. Use =1252 to find fields "
                      "holding that exact value.",
                row=1, column=0, sticky="ew", pady=(T.PAD_S, 0))

        results = Section(self, "Results", **{"row": 2, "column": 0,
                                              "sticky": "nsew",
                                              "pady": (0, T.PAD_M)})
        body = results.body
        body.grid_rowconfigure(0, weight=1)
        self.panel = ListPanel(body, height=10,
                               empty="Search to list matching fields.")
        self.panel.grid(row=0, column=0, sticky="nsew")
        self.flist = self.panel.listbox

        edit = Section(self, "Edit", **{"row": 3, "column": 0, "sticky": "ew"})
        body = edit.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(row, text="New value", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.val_var = ctk.StringVar(value="0")
        Field(row, textvariable=self.val_var, width=90).pack(side="left")
        PrimaryButton(row, "Set selected", width=110,
                      command=lambda: self.set_found_async(False)).pack(
            side="left", padx=(T.PAD_M, 0))
        GhostButton(row, "Set + lock", width=110,
                    command=lambda: self.set_found_async(True)).pack(
            side="left", padx=(T.PAD_S, 0))
        QuietButton(row, "Clear all locks", width=120,
                    command=self.clear_locks_async).pack(
            side="left", padx=(T.PAD_S, 0))

    # -- actions ------------------------------------------------------

    def _on_preset(self, _value):
        for name, filt in PRESETS:
            if name == self.preset_var.get():
                self.filter_var.set(filt)
                break

    def search_async(self, quiet=False):
        client = require_client(self.app)
        if not client:
            return
        filt = self.filter_var.get().strip()
        if not filt:
            self.app.set_status("Enter a filter.")
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_search(client, tgt, filt, quiet))

    def _do_search(self, client, tgt, filt, quiet):
        try:
            res = client.send("stat_search", tgt, filt, MAX_ROWS, timeout=60)
            text = client.read_sidecar("stats.txt") or ""
            rows = []
            for line in text.splitlines():
                # si \t label \t kind \t name \t value
                parts = line.split("\t", 4)
                if len(parts) == 5 and parts[0].isdigit():
                    si, label, kind, name, value = parts
                    rows.append((int(si), label, kind, name, value))
            self.after(0, lambda: self._apply_search(rows, res, quiet))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _apply_search(self, rows, res, quiet):
        self.f_rows = []
        labels = []
        for si, label, kind, name, value in rows:
            self.f_rows.append((si, kind, name))
            labels.append(f"{label}.{name} [{kind}] = {value}")
        self.panel.set_rows(labels)
        self.panel.set_empty("No field matches this filter.")
        if not quiet:
            self.app.set_status(
                f"{res} row(s) (max {MAX_ROWS} - narrow the filter for more).")

    def set_found_async(self, lock):
        client = require_client(self.app)
        if not client:
            return
        sel = self.flist.curselection()
        if not sel or sel[0] >= len(self.f_rows):
            self.app.set_status("Select a row first.")
            return
        try:
            v = self.val_var.get()
            float(v)  # validate numeric
        except ValueError:
            self.app.set_status("Enter a number.")
            return
        si, kind, name = self.f_rows[sel[0]]
        tgt = self.app.target()
        lock_s = "1" if lock else "0"
        run_async(self, lambda: self._do_set(client, tgt, si, kind, name, v,
                                             lock_s))

    def _do_set(self, client, tgt, si, kind, name, v, lock_s):
        try:
            # wire order: target, source index, kind, name, value, lock
            client.send("stat_set", tgt, si, kind, name, v, lock_s, timeout=15)
            self.after(0, lambda: self.app.set_status(
                "Set and locked." if lock_s == "1" else "Set."))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self._do_search(client, tgt, self.filter_var.get().strip(),
                        quiet=True)

    def clear_locks_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_clear_locks(client))

    def _do_clear_locks(self, client):
        try:
            res = client.send("clear_locks", timeout=15)
            self.after(0, lambda: self.app.set_status(f"Cleared {res} lock(s)."))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def refresh_all(self):
        # re-run the last search quietly against the new target
        if self.f_rows:
            self.search_async(quiet=True)
