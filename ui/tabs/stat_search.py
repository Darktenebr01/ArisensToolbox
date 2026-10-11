"""Stat Search tab: filter every numeric field of the character's contexts."""
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    run_async, require_client,
    Card, card_content, H1, Muted,
    PrimaryButton, GhostButton, Field, Combo, StyledListbox,
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
    ("Debilitations", "poison,sleep,silence,curse,torpor,blind,stun,debuff,abnormal"),
    ("Base values", "base"),
]

MAX_ROWS = 150


class StatSearchTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.f_rows = []  # [(si, kind, name)] for the results list
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)
        app.register_refreshable(self)

        H1(self, "Stat Search", row=0, column=0, sticky="w", pady=(0, 8))

        # search card: preset + filter
        srch_card = Card(self, row=1, column=0, sticky="ew", padx=4, pady=6)
        prow = card_content(srch_card)
        prow.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(prow, text="Preset:", text_color=T.TEXT).grid(
            row=0, column=0, sticky="w")
        self.preset_var = ctk.StringVar(value=PRESETS[0][0])
        self.preset_combo = Combo(
            prow, variable=self.preset_var,
            values=[p[0] for p in PRESETS], width=170,
            command=self._on_preset)
        self.preset_combo.grid(row=0, column=1, padx=(4, 0), sticky="w")
        Muted(prow, "Filter (words, comma separated; or =1252 to find fields holding that value):",
              row=1, column=0, columnspan=3, sticky="w", pady=(8, 2))
        self.filter_var = ctk.StringVar(value=PRESETS[0][1])
        Field(prow, textvariable=self.filter_var, width=420).grid(
            row=2, column=0, columnspan=2, sticky="ew", pady=4)
        PrimaryButton(prow, "Search", command=self.search_async,
                      width=135).grid(row=2, column=2, sticky="w", padx=(12, 0), pady=4)

        # results card
        res_card = Card(self, row=2, column=0, sticky="nsew", padx=4, pady=6)
        res = card_content(res_card)
        res.grid_columnconfigure(0, weight=1)
        res.grid_rowconfigure(0, weight=1)
        self.flist = StyledListbox(res)
        self.flist.grid(row=0, column=0, sticky="nsew")
        sb = tk.Scrollbar(res, orient="vertical", command=self.flist.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.flist.config(yscrollcommand=sb.set)

        # edit card
        edit_card = Card(self, row=3, column=0, sticky="ew", padx=4, pady=6)
        vrow = card_content(edit_card)
        ctk.CTkLabel(vrow, text="New value:", text_color=T.TEXT).grid(
            row=0, column=0, sticky="w")
        self.val_var = ctk.StringVar(value="0")
        Field(vrow, textvariable=self.val_var, width=90).grid(
            row=0, column=1, sticky="w", padx=4)
        PrimaryButton(vrow, "Set selected",
                      command=lambda: self.set_found_async(False),
                      width=110).grid(row=0, column=2, padx=4)
        GhostButton(vrow, "Set + lock",
                    command=lambda: self.set_found_async(True),
                    width=110).grid(row=0, column=3, padx=4)
        GhostButton(vrow, "Clear all locks", command=self.clear_locks_async,
                    width=130).grid(row=0, column=4, padx=4)

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def _apply_search(self, rows, res, quiet):
        self.flist.delete(0, tk.END)
        self.f_rows = []
        for si, label, kind, name, value in rows:
            self.f_rows.append((si, kind, name))
            self.flist.insert(tk.END, f"{label}.{name} [{kind}] = {value}")
        if not quiet:
            self.app.set_status(f"{res} row(s) (max {MAX_ROWS} - narrow the filter for more).")

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
        run_async(self, lambda: self._do_set(client, tgt, si, kind, name, v, lock_s))

    def _do_set(self, client, tgt, si, kind, name, v, lock_s):
        try:
            # wire order: target, source index, kind, name, value, lock
            client.send("stat_set", tgt, si, kind, name, v, lock_s, timeout=15)
            self.after(0, lambda: self.app.set_status(
                "Set and locked." if lock_s == "1" else "Set."))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
        self._do_search(client, tgt, self.filter_var.get().strip(), quiet=True)

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def refresh_all(self):
        # re-run the last search quietly against the new target
        if self.f_rows:
            self.search_async(quiet=True)
