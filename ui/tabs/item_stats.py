"""Item Stats: enhancement, base stats and special effects of one item."""
import math

import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ScrollArea, ListPanel, Frame, Field, Combo,
    PrimaryButton, GhostButton, QuietButton, caption, dev_only, run_async,
    require_client, show_probe,
)

SPECIAL_NAMES = {
    11: "Cast speed (v1%) at the cost of max HP (v2%)",
    21: "Stamina recovery speed (v1%)",
    22: "Knockdown power (+v1)",
    39: "Pawn revival on camp rest (Rearrival)",
    40: "Weapon skills cost no stamina; chip damage while idle (Audacity)",
    41: "Stamina return on weapon-skill hit (v1%) (Enervation)",
    50: "Strength boost when fighting bare-handed (Brawling)",
    55: "Survive a fatal hit once (Contingency)",
}


class ItemStatsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        PageHeader(
            self, "Item Stats",
            "Inspect and change the enhancement, base stats and hidden "
            "special effect of the selected item.").grid(
                row=0, column=0, sticky="ew", pady=(0, T.PAD_L))

        self.scroll = ScrollArea(self)
        self.scroll.grid(row=1, column=0, sticky="nsew")

        selection = Section(self.scroll, "Selection",
                            **{"row": 0, "column": 0, "sticky": "ew",
                               "pady": (0, T.PAD_M)})
        body = selection.body
        self.sel_var = ctk.StringVar(
            value="No item selected - pick one in Item Editor.")
        ctk.CTkLabel(body, textvariable=self.sel_var,
                     font=T.font(T.SIZE_BODY, "bold"), text_color=T.TEXT,
                     anchor="w").grid(row=0, column=0, columnspan=2,
                                      sticky="ew")
        self.totals_var = ctk.StringVar(value="")
        ctk.CTkLabel(body, textvariable=self.totals_var,
                     font=T.mono(T.SIZE_SMALL), text_color=T.TEXT_SOFT,
                     anchor="w", justify="left").grid(
            row=1, column=0, columnspan=2, sticky="ew",
            pady=(T.PAD_XS, T.PAD_S))
        row = Row(body)
        row.grid(row=2, column=0, columnspan=2, sticky="w")
        row.add(GhostButton(row, "Character totals", width=140,
                            command=self.read_totals))
        row.add(QuietButton(row, "Sweep all specials", width=136,
                            command=self.sweep_specials))
        dev_only(self, lambda: QuietButton(row, "Dump fields", width=110,
                                          command=self.dump_fields).pack(
            side="left"))

        # -- enhancement + special, side by side ----------------------
        duo = Frame(self.scroll)
        duo.grid(row=1, column=0, sticky="ew", pady=(0, T.PAD_M))
        duo.grid_columnconfigure(0, weight=1)
        duo.grid_columnconfigure(1, weight=1)

        enh = Section(duo, "Enhancement", hint="This item only.",
                      **{"row": 0, "column": 0, "sticky": "nsew",
                         "padx": (0, T.PAD_M)})
        body = enh.body
        top = Row(body)
        top.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(top, text="Level", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.enh_level_var = ctk.StringVar(value="0")
        Field(top, textvariable=self.enh_level_var, width=64).pack(side="left")
        self.enh_cap_var = ctk.StringVar(value="(max ?)")
        ctk.CTkLabel(top, textvariable=self.enh_cap_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_S, 0))
        QuietButton(top, "Read", width=70,
                    command=self.read_enh).pack(side="right")

        self.enh_combos = []
        for t in range(3):
            line = Frame(body)
            line.grid(row=1 + t, column=0, sticky="ew", pady=(T.PAD_S, 0))
            line.grid_columnconfigure(1, weight=1)
            ctk.CTkLabel(line, text=f"Type {t}", font=T.font(T.SIZE_SMALL),
                         text_color=T.MUTED, width=52, anchor="w").grid(
                row=0, column=0, sticky="w")
            cb = Combo(line, values=["(read first)"])
            cb.grid(row=0, column=1, sticky="ew")
            cb.set("(read first)")
            self.enh_combos.append(cb)
        PrimaryButton(body, "Apply enhancement", width=160,
                      command=self.apply_enh).grid(row=4, column=0,
                                                   sticky="w",
                                                   pady=(T.PAD_M, 0))

        special = Section(duo, "Special effect",
                          hint="Rings and similar items: effect ID + values.",
                          **{"row": 0, "column": 1, "sticky": "nsew"})
        body = special.body
        grid = Frame(body)
        grid.grid(row=0, column=0, sticky="ew")
        self.spec_vars = []
        for i, label in enumerate(["ID", "Value 1", "Value 2", "Value 3"]):
            ctk.CTkLabel(grid, text=label, font=T.font(T.SIZE_SMALL),
                         text_color=T.MUTED).grid(
                row=0, column=i, sticky="w",
                padx=(0 if i == 0 else T.PAD_S, 0))
            var = ctk.StringVar(value="0")
            Field(grid, textvariable=var, width=70).grid(
                row=1, column=i, padx=(0 if i == 0 else T.PAD_S, 0),
                pady=(2, 0))
            self.spec_vars.append(var)
        self.spec_name_var = ctk.StringVar(value="Effect: -")
        ctk.CTkLabel(body, textvariable=self.spec_name_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.TEXT_SOFT,
                     anchor="w", justify="left").grid(
            row=1, column=0, sticky="ew", pady=(T.PAD_S, 0))
        row = Row(body)
        row.grid(row=2, column=0, sticky="w", pady=(T.PAD_S, 0))
        row.add(QuietButton(row, "Read", width=70, command=self.read_special))
        row.add(PrimaryButton(row, "Apply", width=90,
                              command=self.apply_special))
        dev_only(self, lambda: QuietButton(row, "Effect names", width=110,
                                          command=self.probe_special).pack(
            side="left"))
        caption(body, "Shared by every copy of this item; unequip and "
                      "re-equip to apply. Resets when the game restarts.",
                row=3, column=0, sticky="ew", pady=(T.PAD_S, 0))

        # -- base stats ----------------------------------------------
        stats = Section(self.scroll, "Base stats",
                        hint="Shared by every copy of this item type and "
                             "reset when the game restarts.",
                        **{"row": 2, "column": 0, "sticky": "ew"})
        body = stats.body
        body.grid_rowconfigure(0, weight=1)
        split = Frame(body)
        split.grid(row=0, column=0, sticky="nsew")
        split.grid_columnconfigure(0, weight=1)
        split.grid_rowconfigure(0, weight=1)
        self.panel = ListPanel(split, height=8,
                               empty="Read the stats of the selected item.")
        self.panel.grid(row=0, column=0, sticky="nsew", padx=(0, T.PAD_M))
        self.stat_listbox = self.panel.listbox
        self.stat_rows = []  # field names parallel to listbox

        controls = Frame(split)
        controls.grid(row=0, column=1, sticky="ns")
        controls.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(controls, text="New value", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED, anchor="w").grid(
            row=0, column=0, sticky="w")
        self.stat_val_var = ctk.StringVar(value="0")
        Field(controls, textvariable=self.stat_val_var, width=120).grid(
            row=1, column=0, sticky="ew", pady=(2, T.PAD_S))
        PrimaryButton(controls, "Set selected", width=120,
                      command=self.set_stat).grid(row=2, column=0,
                                                  sticky="ew")
        QuietButton(controls, "Read stats", width=120,
                    command=lambda: self.read_stats(quiet=False)).grid(
            row=3, column=0, sticky="ew", pady=(T.PAD_S, 0))
        QuietButton(controls, "Recalculate", width=120,
                    command=self.recalc).grid(row=4, column=0, sticky="ew",
                                              pady=(T.PAD_XS, 0))

        self.bind("<Map>", self._on_map)
        self.refresh()

    # -- shared state -------------------------------------------------

    def _on_map(self, event):
        if event.widget is self:
            self.refresh()

    def refresh(self):
        row = self.app.selected_item_row
        name = getattr(self.app, "selected_item_name", None)
        if row:
            self.sel_var.set(f"{name or 'Item'}   ·   row {row}")
        else:
            self.sel_var.set("No item selected - pick one in Item Editor.")

    def _row(self):
        row = self.app.selected_item_row
        if not row:
            self.app.set_status("Select an item in Item Editor first.")
            return None
        return row

    # -- totals / dump ------------------------------------------------

    def read_totals(self):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read_totals(client, row))

    def _read_totals(self, client, row):
        try:
            res = client.send("item_totals", row, timeout=15)
            self.after(0, lambda: self.totals_var.set(res))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def dump_fields(self):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        self.app.set_status("Dumping every field of the selected item...")
        run_async(self, lambda: self._dump_fields(client, row))

    def _dump_fields(self, client, row):
        try:
            res = client.send("item_stat_dump", row, timeout=60)
            text = client.read_sidecar("itemstatdump.txt") or \
                "(itemstatdump.txt missing)"
            self.after(0, lambda: (show_probe(self, "Item stat dump", text),
                                   self.app.set_status(f"Dump done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- enhancement --------------------------------------------------

    def _enh_index(self, v):
        vals = (self.app.enum_data or {}).get("enhVals", [])
        for i, x in enumerate(vals):
            if x == v:
                return i
        return 0

    def read_enh(self):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read_enh(client, row))

    def _read_enh(self, client, row):
        try:
            res = client.send("item_get_enh", row, timeout=15)
            p = res.split(",")
            level = p[0] if len(p) > 0 else "0"
            cap = p[1] if len(p) > 1 else "?"
            types = [(int(p[2 + t]) if len(p) > 2 + t
                      and p[2 + t].lstrip("-").isdigit() else 0)
                     for t in range(3)]
            labels = (self.app.enum_data or {}).get("enhLabels", [])

            def _ui():
                self.enh_level_var.set(level)
                self.enh_cap_var.set(f"(max {cap})")
                for t in range(3):
                    if labels:
                        self.enh_combos[t].configure(values=labels)
                        self.enh_combos[t].set(labels[self._enh_index(types[t])])
                    else:
                        self.enh_combos[t].configure(values=[str(types[t])])
                        self.enh_combos[t].set(str(types[t]))
                self.app.set_status("Enhancement read.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_enh(self):
        row = self._row()
        if not row:
            return
        try:
            level = math.floor(float(self.enh_level_var.get()))
        except ValueError:
            self.app.set_status("Enter a level.")
            return
        enum = self.app.enum_data or {}
        labels = enum.get("enhLabels", [])
        vals = enum.get("enhVals", [])
        types = []
        for cb in self.enh_combos:
            try:
                idx = list(labels).index(cb.get())
                types.append(vals[idx])
            except (ValueError, IndexError):
                self.app.set_status("Read the enhancement first (type list "
                                    "not loaded).")
                return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._apply_enh(client, row, level, types))

    def _apply_enh(self, client, row, level, types):
        try:
            res = client.send("item_set_enh", row, level, *types, timeout=15)
            self.after(0, lambda: self.app.set_status(f"Applied: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- base stats ---------------------------------------------------

    def read_stats(self, quiet=False):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read_stats(client, row, quiet))

    def _read_stats(self, client, row, quiet):
        try:
            res = client.send("item_get_stats", row, timeout=30)
            text = client.read_sidecar("itemstats.txt") or ""
            rows = []
            for line in text.splitlines():
                parts = line.split("\t", 2)
                if len(parts) == 3:
                    rows.append(parts)  # field, label, value
            self.stat_rows = [f for f, _l, _v in rows]

            def _ui():
                self.panel.set_rows([f"{label} = {value}"
                                     for _f, label, value in rows])
                self.panel.set_empty("No stats reported for this item.")
                if not quiet:
                    self.app.set_status(f"Read {len(rows)} stat(s) ({res}).")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def set_stat(self):
        row = self._row()
        if not row:
            return
        sel = self.stat_listbox.curselection()
        if not sel or sel[0] >= len(self.stat_rows):
            self.app.set_status("Select a stat first.")
            return
        try:
            v = math.floor(float(self.stat_val_var.get()))
        except ValueError:
            self.app.set_status("Enter a number.")
            return
        client = require_client(self.app)
        if not client:
            return
        field = self.stat_rows[sel[0]]
        run_async(self, lambda: self._set_stat(client, row, field, v))

    def _set_stat(self, client, row, field, v):
        try:
            res = client.send("item_set_stat", row, field, v, timeout=15)
            self.after(0, lambda: (self.app.set_status(f"Applied: {res}"),
                                   self.read_stats(quiet=True)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def recalc(self):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._recalc(client, row))

    def _recalc(self, client, row):
        try:
            res = client.send("item_recalc", row, timeout=15)
            self.after(0, lambda: self.app.set_status(res))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- special effect -----------------------------------------------

    def read_special(self):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read_special(client, row))

    def _read_special(self, client, row):
        try:
            res = client.send("item_get_special", row, timeout=15)
            p = res.split(",")
            vals = [(p[i] if len(p) > i else "0") for i in range(4)]
            sid = int(vals[0]) if vals[0].lstrip("-").isdigit() else 0

            def _ui():
                for i in range(4):
                    self.spec_vars[i].set(vals[i])
                self.spec_name_var.set(
                    "Effect: " + (SPECIAL_NAMES.get(sid) or f"Unknown ID {sid}"))
                self.app.set_status("Special effect read.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_special(self):
        row = self._row()
        if not row:
            return
        try:
            vals = [math.floor(float(v.get())) for v in self.spec_vars]
        except ValueError:
            self.app.set_status("Enter numbers in all four boxes.")
            return
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._apply_special(client, row, vals))

    def _apply_special(self, client, row, vals):
        try:
            res = client.send("item_set_special", row, *vals, timeout=15)
            self.after(0, lambda: self.app.set_status(f"Applied: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def probe_special(self):
        row = self._row()
        if not row:
            return
        client = require_client(self.app)
        if not client:
            return
        self.app.set_status("Probing the game for the effect-name lookup...")
        run_async(self, lambda: self._probe_special(client, row))

    def _probe_special(self, client, row):
        try:
            res = client.send("item_special_probe", row, timeout=60)
            text = client.read_sidecar("specialprobe.txt") or \
                "(specialprobe.txt missing)"
            self.after(0, lambda: (
                show_probe(self, "Special-effect probe", text),
                self.app.set_status(f"Probe done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def sweep_specials(self):
        client = require_client(self.app)
        if not client:
            return
        self.app.set_status("Sweeping loaded inventory for special effects...")
        run_async(self, lambda: self._sweep_specials(client))

    def _sweep_specials(self, client):
        try:
            res = client.send("item_special_sweep", timeout=60)
            text = client.read_sidecar("specialsweep.txt") or \
                "(specialsweep.txt missing)"
            self.after(0, lambda: (
                show_probe(self, "Special sweep", text),
                self.app.set_status(f"Sweep done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
