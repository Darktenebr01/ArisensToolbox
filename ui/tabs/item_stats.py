"""Item Stats tab: enhancement, base stats, and special effects of the selected item."""
import math
import re
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, H2, Muted, PrimaryButton, GhostButton,
    Field, Combo, StyledListbox, run_async, require_client, show_probe,
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


class ItemStatsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)

        self.scroll = ctk.CTkScrollableFrame(self, fg_color="transparent")
        self.scroll.grid(row=0, column=0, sticky="nsew")
        self.scroll.grid_columnconfigure(0, weight=1)

        r = 0
        H1(self.scroll, "Item Stats", row=r, column=0, sticky="w", pady=(0, 10))
        r += 1

        # selection card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        self.sel_var = ctk.StringVar(value="Selected item: (pick one in the Item Editor tab)")
        ctk.CTkLabel(cc, textvariable=self.sel_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=0, column=0, sticky="w", pady=(0, 4))

        self.totals_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.totals_var,
                     font=("Consolas", 11), text_color=T.TEXT).grid(
            row=1, column=0, sticky="w", pady=(0, 6))

        trow = ctk.CTkFrame(cc, fg_color="transparent")
        trow.grid(row=2, column=0, sticky="w")
        GhostButton(trow, text="Read character totals", width=170,
                    command=self.read_totals).pack(side="left", padx=(0, 8))
        GhostButton(trow, text="DUMP all item fields", width=170,
                    command=self.dump_fields).pack(side="left")
        GhostButton(trow, text="Sweep all specials", width=150,
                    command=self.sweep_specials).pack(side="left", padx=8)

        # enhancement card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Enhancement (this item only)", row=0, column=0, sticky="w", pady=(0, 6))
        erow = ctk.CTkFrame(cc, fg_color="transparent")
        erow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(erow, **T.body("Level:")).pack(side="left")
        self.enh_level_var = ctk.StringVar(value="0")
        Field(erow, textvariable=self.enh_level_var, width=60).pack(side="left", padx=8)
        self.enh_cap_var = ctk.StringVar(value="(max ?)")
        ctk.CTkLabel(erow, textvariable=self.enh_cap_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).pack(side="left", padx=8)
        GhostButton(erow, text="Read", width=90,
                    command=self.read_enh).pack(side="left", padx=8)

        self.enh_combos = []
        for t in range(3):
            trow = ctk.CTkFrame(cc, fg_color="transparent")
            trow.grid(row=2 + t, column=0, sticky="ew", pady=2)
            trow.grid_columnconfigure(1, weight=1)
            ctk.CTkLabel(trow, **T.body(f"Type {t}:")).grid(row=0, column=0, padx=(0, 8))
            cb = Combo(trow, values=["(read first)"])
            cb.grid(row=0, column=1, sticky="ew")
            cb.set("(read first)")
            self.enh_combos.append(cb)

        PrimaryButton(cc, text="Apply enhancement", width=170,
                      command=self.apply_enh).grid(row=5, column=0, sticky="w", pady=(8, 0))

        # base stats card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Base stats", row=0, column=0, sticky="w", pady=(0, 6))
        Muted(cc, "Shared by every copy of this item type; reset when the game restarts.",
              row=1, column=0, sticky="w", pady=(0, 6))
        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=2, column=0, sticky="nsew", pady=(0, 6))
        brow.grid_columnconfigure(0, weight=1)
        self.stat_listbox = StyledListbox(brow, height=10)
        self.stat_listbox.grid(row=0, column=0, sticky="nsew")
        bsb = tk.Scrollbar(brow, orient="vertical", command=self.stat_listbox.yview)
        bsb.grid(row=0, column=1, sticky="ns")
        self.stat_listbox.config(yscrollcommand=bsb.set)
        self.stat_rows = []  # field names parallel to listbox

        bctl = ctk.CTkFrame(cc, fg_color="transparent")
        bctl.grid(row=3, column=0, sticky="ew")
        GhostButton(bctl, text="Read stats", width=120,
                    command=lambda: self.read_stats(quiet=False)).pack(side="left", padx=(0, 8))
        ctk.CTkLabel(bctl, **T.body("New value:")).pack(side="left")
        self.stat_val_var = ctk.StringVar(value="0")
        Field(bctl, textvariable=self.stat_val_var, width=90).pack(side="left", padx=8)
        PrimaryButton(bctl, text="Set selected", width=120,
                      command=self.set_stat).pack(side="left", padx=8)
        GhostButton(bctl, text="Recalculate now", width=140,
                    command=self.recalc).pack(side="left")

        # special effect card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Special effect (rings etc.: effect ID + values)",
           row=0, column=0, sticky="w", pady=(0, 6))
        srow = ctk.CTkFrame(cc, fg_color="transparent")
        srow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        self.spec_vars = []
        for i, n in enumerate(["Special ID:", "Value 1:", "Value 2:", "Value 3:"]):
            ctk.CTkLabel(srow, **T.body(n)).pack(side="left", padx=(0 if i == 0 else 12, 4))
            v = ctk.StringVar(value="0")
            Field(srow, textvariable=v, width=80).pack(side="left")
            self.spec_vars.append(v)
        self.spec_name_var = ctk.StringVar(value="Effect: -")
        ctk.CTkLabel(cc, textvariable=self.spec_name_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=2, column=0, sticky="w", pady=(0, 4))
        Muted(cc, "Shared item data (all copies of this item); resets on restart. "
                  "Unequip/re-equip to apply.",
              row=3, column=0, sticky="w", pady=(0, 6))

        sctl = ctk.CTkFrame(cc, fg_color="transparent")
        sctl.grid(row=4, column=0, sticky="w")
        GhostButton(sctl, text="Read", width=120,
                    command=self.read_special).pack(side="left", padx=(0, 8))
        PrimaryButton(sctl, text="Apply", width=120,
                      command=self.apply_special).pack(side="left", padx=8)
        GhostButton(sctl, text="Probe effect names", width=160,
                    command=self.probe_special).pack(side="left", padx=8)

        # refresh the label whenever this tab becomes visible
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
            self.sel_var.set(f"Selected item: {name or '?'} (row {row})")
        else:
            self.sel_var.set("Selected item: (pick one in the Item Editor tab)")

    def _row(self):
        row = self.app.selected_item_row
        if not row:
            self.app.set_status("Select an item in the Item Editor tab first.")
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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            text = client.read_sidecar("itemstatdump.txt") or "(itemstatdump.txt missing)"
            self.after(0, lambda: (show_probe(self, "Item stat dump - copy all of it", text),
                                   self.app.set_status(f"Dump done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            types = [(int(p[2 + t]) if len(p) > 2 + t and p[2 + t].lstrip("-").isdigit() else 0)
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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
                self.app.set_status("Read the enhancement first (type list not loaded).")
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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
                self.stat_listbox.delete(0, tk.END)
                for f, label, value in rows:
                    self.stat_listbox.insert(tk.END, f"{label} = {value}")
                if not quiet:
                    self.app.set_status(f"Read {len(rows)} stat(s) ({res}).")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
            text = client.read_sidecar("specialprobe.txt") or "(specialprobe.txt missing)"
            self.after(0, lambda: (show_probe(self, "Special-effect probe - copy all of it", text),
                                   self.app.set_status(f"Probe done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def sweep_specials(self):
        client = require_client(self.app)
        if not client:
            return
        self.app.set_status("Sweeping loaded inventory for special effects...")
        run_async(self, lambda: self._sweep_specials(client))

    def _sweep_specials(self, client):
        try:
            res = client.send("item_special_sweep", timeout=60)
            text = client.read_sidecar("specialsweep.txt") or "(specialsweep.txt missing)"
            self.after(0, lambda: (show_probe(self, "Special sweep - copy all of it", text),
                                   self.app.set_status(f"Sweep done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
