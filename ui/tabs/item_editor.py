"""Item Editor tab: pick an inventory item, edit its weapon-skill slots and appraisal."""
import math
import re
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, H2, Muted, PrimaryButton, GhostButton,
    Field, Combo, Check, StyledListbox, run_async, require_client, show_probe,
)

MAX_SHOWN = 400


class ItemEditorTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)

        self.scroll = ctk.CTkScrollableFrame(self, fg_color="transparent")
        self.scroll.grid(row=0, column=0, sticky="nsew")
        self.scroll.grid_columnconfigure(0, weight=1)

        # state
        self.owner_idxs = []      # parallel to owner combo values
        self._owner_pos = 0
        self.item_rows = []       # dicts: i, name, lname, equipped, slots
        self.shown_rows = []
        self.sel_row = None       # 1-based row id shared via app.selected_item_row
        self.cur_slots = [0, 0, 0, 0]
        self.valid_set = None     # set of skill ids valid for this item type
        self.filt_ids = []        # skill ids behind slot-combo entries (after the 2 headers)
        self.slot_ids = [[], [], [], []]
        self._filling = False

        r = 0
        H1(self.scroll, "Item Editor", row=r, column=0, sticky="w", pady=(0, 10))
        r += 1

        # inventory card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Inventory", row=0, column=0, sticky="w", pady=(0, 6))
        orow = ctk.CTkFrame(cc, fg_color="transparent")
        orow.grid(row=1, column=0, sticky="ew")
        ctk.CTkLabel(orow, **T.body("Inventory:")).pack(side="left")
        self.owner_combo = Combo(
            orow, values=["(click Reload inventory)"],
            width=340, command=self.on_owner_change,
        )
        self.owner_combo.pack(side="left", padx=8)
        PrimaryButton(orow, text="Reload inventory", width=140,
                      command=self.reload_owners).pack(side="left")

        # items card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Items", row=0, column=0, sticky="w", pady=(0, 6))
        srow = ctk.CTkFrame(cc, fg_color="transparent")
        srow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(srow, **T.body("Search:")).pack(side="left")
        self.search_var = ctk.StringVar()
        self.search_var.trace_add("write", lambda *_: self.refresh_list())
        Field(srow, textvariable=self.search_var, width=200).pack(side="left", padx=8)
        self.equip_var = ctk.BooleanVar(value=True)
        Check(srow, text="Only weapons/armor/jewelry", variable=self.equip_var,
              command=self.on_filter_toggle).pack(side="left", padx=8)
        self.equipped_var = ctk.BooleanVar(value=False)
        Check(srow, text="Only equipped", variable=self.equipped_var,
              command=self.on_filter_toggle).pack(side="left", padx=8)

        lframe = ctk.CTkFrame(cc, fg_color="transparent")
        lframe.grid(row=2, column=0, sticky="nsew", pady=(0, 6))
        lframe.grid_columnconfigure(0, weight=1)
        self.listbox = StyledListbox(lframe, height=8)
        self.listbox.grid(row=0, column=0, sticky="nsew")
        self.listbox.bind("<<ListboxSelect>>", self.on_row_select)
        sb = tk.Scrollbar(lframe, orient="vertical", command=self.listbox.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.listbox.config(yscrollcommand=sb.set)

        self.sel_var = ctk.StringVar(value="Click an item above to edit it.")
        ctk.CTkLabel(cc, textvariable=self.sel_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=3, column=0, sticky="w")

        # skill slots card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Weapon skill slots", row=0, column=0, sticky="w", pady=(0, 6))
        frow = ctk.CTkFrame(cc, fg_color="transparent")
        frow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(frow, **T.body("Filter skill list:")).pack(side="left")
        self.skill_filter_var = ctk.StringVar()
        self.skill_filter_var.trace_add("write", lambda *_: self.on_skill_filter())
        Field(frow, textvariable=self.skill_filter_var, width=200).pack(side="left", padx=8)
        self.valid_var = ctk.BooleanVar(value=False)
        Check(frow, text="Only skills valid for this item type",
              variable=self.valid_var,
              command=self.on_valid_toggle).pack(side="left", padx=8)
        GhostButton(frow, text="Type/skill map report", width=170,
                    command=lambda: self.run_probe_cmd(
                        "eqmap_build", "eqmap.txt",
                        "Item types and the skills seen on them")).pack(side="right")

        self.slot_combos = []
        for s in range(4):
            srow = ctk.CTkFrame(cc, fg_color="transparent")
            srow.grid(row=2 + s, column=0, sticky="ew", pady=2)
            srow.grid_columnconfigure(1, weight=1)
            ctk.CTkLabel(srow, **T.body(f"Slot {s + 1}:")).grid(row=0, column=0, padx=(0, 8))
            cb = Combo(
                srow, values=["(select an item first)"],
                command=lambda v, s=s: self.on_slot_select(s, v),
            )
            cb.grid(row=0, column=1, sticky="ew")
            cb.set("(select an item first)")
            self.slot_combos.append(cb)

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=6, column=0, sticky="ew", pady=(8, 0))
        GhostButton(brow, text="Clear all slots", width=120,
                    command=self.clear_slots).pack(side="left", padx=(0, 8))
        PrimaryButton(brow, text="APPLY to game (sync + recalc)", width=220,
                      command=self.apply_to_game).pack(side="left")

        # appraisal card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Appraisal values", row=0, column=0, sticky="w", pady=(0, 6))
        arow = ctk.CTkFrame(cc, fg_color="transparent")
        arow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        self.ap_vars = []
        for i, n in enumerate(["Physical:", "Magic:", "Blow:", "Weight:"]):
            ctk.CTkLabel(arow, **T.body(n)).pack(side="left", padx=(0 if i == 0 else 12, 4))
            v = ctk.StringVar(value="0")
            Field(arow, textvariable=v, width=60).pack(side="left")
            self.ap_vars.append(v)
        arow2 = ctk.CTkFrame(cc, fg_color="transparent")
        arow2.grid(row=2, column=0, sticky="ew")
        self.appr_var = ctk.BooleanVar(value=False)
        Check(arow2, text="IsAppraised",
              variable=self.appr_var).pack(side="left", padx=(0, 12))
        PrimaryButton(arow2, text="Apply appraisal", width=140,
                      command=self.apply_appraisal).pack(side="left")
        Muted(cc, "Written to the item, then synced + recalculated.",
              row=3, column=0, sticky="w", pady=(8, 0))

        # element card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Element", row=0, column=0, sticky="w", pady=(0, 6))
        erow = ctk.CTkFrame(cc, fg_color="transparent")
        erow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(erow, **T.body("Element:")).pack(side="left")
        self.elem_combo = Combo(
            erow, values=["(select an item first)"], width=240)
        self.elem_combo.pack(side="left", padx=8)
        self.elem_combo.set("(select an item first)")
        PrimaryButton(erow, text="Apply element", width=130,
                      command=self.apply_element).pack(side="left")
        prow = ctk.CTkFrame(cc, fg_color="transparent")
        prow.grid(row=2, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(prow, **T.body("Element %:")).pack(side="left")
        self.elem_pct_var = ctk.StringVar(value="")
        Field(prow, textvariable=self.elem_pct_var, width=70).pack(side="left", padx=8)
        PrimaryButton(prow, text="Apply %", width=90,
                      command=self.apply_elem_pct).pack(side="left")
        GhostButton(prow, text="Clear %", width=90,
                    command=self.clear_elem_pct).pack(side="left", padx=8)
        self.elem_info_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.elem_info_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=3, column=0, sticky="w")
        Muted(cc, "Only one enhancement works per item (blue triangle) - setting "
              "an element replaces any enhanced ability/stat bonus. The item "
              "is marked appraised so the element shows in game. "
              "Element restrictions are lifted automatically when the bridge "
              "loads, so any weapon can take any element and forced elements "
              "stay after a restart.",
              row=4, column=0, sticky="w", pady=(8, 0))

        # rename card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Rename item", row=0, column=0, sticky="w", pady=(0, 6))
        nrow = ctk.CTkFrame(cc, fg_color="transparent")
        nrow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(nrow, **T.body("New name:")).pack(side="left")
        self.rename_var = ctk.StringVar(value="")
        Field(nrow, textvariable=self.rename_var, width=260).pack(side="left", padx=8)
        PrimaryButton(nrow, text="Apply name", width=110,
                      command=self.apply_item_name).pack(side="left")
        GhostButton(nrow, text="Clear name", width=110,
                    command=self.clear_item_name).pack(side="left", padx=8)
        GhostButton(nrow, text="DIAG name", width=100,
                    command=self.diag_item_name).pack(side="left")
        GhostButton(nrow, text="PROBE type", width=100,
                    command=self.probe_item_type).pack(side="left", padx=8)
        Muted(cc, "Renames all items of this type in game (names are shared "
              "per item type). The rename is re-applied when the inventory "
              "loads. Clear removes the saved rename; restart the game to "
              "restore the original name.",
              row=2, column=0, sticky="w", pady=(8, 0))

        # probes card
        card = Card(self.scroll, row=r, column=0, sticky="ew", padx=4, pady=6)
        r += 1
        cc = card_content(card)
        H2(cc, "Probes", row=0, column=0, sticky="w", pady=(0, 6))
        prow = ctk.CTkFrame(cc, fg_color="transparent")
        prow.grid(row=1, column=0, sticky="ew")
        GhostButton(prow, text="DUMP ability rules", width=170,
                    command=lambda: self.run_probe_cmd(
                        "abil_dump", "abildump.txt",
                        "Ability rule dump - copy all of it")).pack(side="left", padx=(0, 6))
        GhostButton(prow, text="DUMP appraisal rules (2)", width=190,
                    command=lambda: self.run_probe_cmd(
                        "abil_dump2", "abildump2.txt",
                        "Appraisal rule dump - copy all of it")).pack(side="left", padx=6)
        GhostButton(prow, text="DUMP ability data + probe (3)", width=230,
                    command=lambda: self.run_probe_cmd(
                        "abil_dump3", "abildump3.txt",
                        "Ability data dump 3 - copy all of it (can take a while)")).pack(side="left", padx=6)

    # -- owners -------------------------------------------------------

    def reload_owners(self):
        client = require_client(self.app)
        if not client:
            return
        self.app.set_status("Reading the inventory...")
        run_async(self, lambda: self._load_owners(client))

    def _load_owners(self, client):
        try:
            res = client.send("item_owners", timeout=30)
            idxs, labels = [], []
            for row in res.split(";"):
                m = re.match(r"^(\d+),([^,]*),(\d+),(\d+)$", row.strip())
                if m:
                    i, key, count, isp = m.groups()
                    idxs.append(int(i))
                    labels.append(f"owner {key} ({count} items)"
                                  + ("  <- YOU" if isp == "1" else ""))
            self.owner_idxs = idxs

            def _ui():
                self._filling = True
                try:
                    self.owner_combo.configure(values=labels or ["(none)"])
                    if labels:
                        self.owner_combo.set(labels[0])
                        self._owner_pos = 0
                    else:
                        self._owner_pos = 0
                finally:
                    self._filling = False
                if labels:
                    self.sel_row = None
                    self.app.selected_item_row = None
                    self.load_rows()
                else:
                    self.app.set_status("No inventory found - load a save.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _current_owner_idx(self):
        if self.owner_idxs and 0 <= self._owner_pos < len(self.owner_idxs):
            return self.owner_idxs[self._owner_pos]
        return None

    def on_owner_change(self, value):
        if self._filling:
            return
        try:
            self._owner_pos = list(self.owner_combo.cget("values")).index(value)
        except ValueError:
            return
        self.sel_row = None
        self.app.selected_item_row = None
        self.load_rows()

    def on_filter_toggle(self):
        if self.owner_idxs:
            self.sel_row = None
            self.app.selected_item_row = None
            self.load_rows()

    # -- item rows ----------------------------------------------------

    def load_rows(self, after=None):
        client = require_client(self.app)
        if not client:
            return
        oi = self._current_owner_idx()
        if oi is None:
            self.app.set_status("Load the inventory first.")
            return
        equip = 1 if self.equip_var.get() else 0
        equipped = 1 if self.equipped_var.get() else 0
        run_async(self, lambda: self._load_rows(client, oi, equip, equipped, after))

    def _load_rows(self, client, oi, equip, equipped, after):
        try:
            count = client.send("item_rows", oi, equip, equipped, timeout=60)
            text = client.read_sidecar("itemrows.txt") or ""
            rows = []
            for line in text.splitlines():
                m = re.match(r"^(\d+)\t([^\t]*)\t(\d)\t(.*)$", line)
                if m:
                    slots = [(int(v) if v.lstrip("-").isdigit() else 0)
                             for v in m.group(4).split(",")]
                    slots = (slots + [0, 0, 0, 0])[:4]
                    rows.append({"i": int(m.group(1)), "name": m.group(2),
                                 "lname": m.group(2).lower(),
                                 "equipped": m.group(3) == "1", "slots": slots})
            self.item_rows = rows

            def _ui():
                self.refresh_list()
                self.app.set_status(f"{len(rows)} item(s) (game said {count}).")
                if after:
                    after()
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def refresh_list(self):
        tokens = self.search_var.get().lower().split()
        enum = self.app.enum_data or {}
        equip_name = enum.get("equipName", {})
        self.listbox.delete(0, tk.END)
        self.shown_rows = []
        for r in self.item_rows:
            if all(t in r["lname"] for t in tokens) and len(self.shown_rows) < MAX_SHOWN:
                self.shown_rows.append(r)
                tags = [str(equip_name.get(i, i)) for i in r["slots"] if i != 0]
                self.listbox.insert(
                    tk.END,
                    ("[E] " if r["equipped"] else "    ") + r["name"]
                    + "   {" + ", ".join(tags) + "}",
                )
        if self.item_rows:
            self.app.set_status(f"{len(self.shown_rows)} shown.")

    def on_row_select(self, _event):
        sel = self.listbox.curselection()
        if sel and sel[0] < len(self.shown_rows):
            r = self.shown_rows[sel[0]]
            self.sel_row = r["i"]
            self.select_item()

    # -- select item --------------------------------------------------

    def select_item(self):
        if not self.sel_row:
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._select_item(client, row))

    def _select_item(self, client, row):
        try:
            res = client.send("item_get", row, timeout=15)
            p = res.split(",")
            slots = [(int(p[i]) if i < len(p) and p[i].lstrip("-").isdigit() else 0)
                      for i in range(4)]
            appr = len(p) > 4 and p[4] == "1"
            ap_vals = [(p[5 + i] if len(p) > 5 + i else "0") for i in range(4)]
            equipped = len(p) > 9 and p[9] == "1"
            name = next((r["name"] for r in self.item_rows if r["i"] == row), "?")
            self.cur_slots = slots
            self.app.selected_item_row = row
            self.app.selected_item_name = name
            need_valid = self.valid_var.get()

            def _ui():
                self.appr_var.set(appr)
                for i in range(4):
                    self.ap_vars[i].set(ap_vals[i])
                self.fill_slot_combos()
                if need_valid:
                    self.load_valid(rescan=False)
                self.sel_var.set(
                    f"Editing: {name}"
                    + ("  (equipped - press APPLY to game after changes)" if equipped else ""))
            self.after(0, _ui)
            self.load_element()
            self.load_item_name()
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- skill slots --------------------------------------------------

    def _skill_label(self, sid):
        enum = self.app.enum_data or {}
        equip_name = enum.get("equipName", {})
        return f"{equip_name.get(sid, 'id ' + str(sid))} ({sid})"

    def on_skill_filter(self):
        if (self.app.enum_data or {}).get("equipList"):
            self.fill_slot_combos()

    def fill_slot_combos(self):
        enum = self.app.enum_data or {}
        equip_list = enum.get("equipList", [])  # [(v, n)]
        q = self.skill_filter_var.get().lower()
        self.filt_ids = []
        items = []
        for v, n in equip_list:
            if v != 0 and (not q or q in n.lower()) \
                    and (self.valid_set is None or v in self.valid_set):
                self.filt_ids.append(v)
                items.append(f"{n} ({v})")
        self._filling = True
        try:
            for s in range(4):
                cur = self.cur_slots[s] if s < len(self.cur_slots) else 0
                values = [f"[current] {self._skill_label(cur)}",
                          "(none) - clear this slot"] + items
                self.slot_ids[s] = [None, 0] + self.filt_ids
                self.slot_combos[s].configure(values=values)
                self.slot_combos[s].set(values[0])
        finally:
            self._filling = False

    def on_slot_select(self, slot_idx, value):
        if self._filling or not self.sel_row:
            return
        try:
            idx = list(self.slot_combos[slot_idx].cget("values")).index(value)
        except ValueError:
            return
        if idx <= 0:
            return  # "[current]" header - nothing to do
        sid = self.slot_ids[slot_idx][idx]
        if sid is None:
            return
        client = require_client(self.app)
        if not client:
            return
        row, slot = self.sel_row, slot_idx + 1
        run_async(self, lambda: self._set_slot(client, row, slot, sid))

    def _set_slot(self, client, row, slot, sid):
        try:
            res = client.send("item_set_slot", row, slot, sid, timeout=15)
            msg = res + "  - now press APPLY to game"

            def _ui():
                self.load_rows(after=lambda: (self.select_item(),
                                              self.app.set_status(msg)))
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def clear_slots(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._clear_slots(client, row))

    def _clear_slots(self, client, row):
        try:
            res = client.send("item_clear", row, timeout=15)
            msg = res + "  - now press APPLY to game"

            def _ui():
                self.load_rows(after=lambda: (self.select_item(),
                                              self.app.set_status(msg)))
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_to_game(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._apply(client, row))

    def _apply(self, client, row):
        try:
            res = client.send("item_apply", row, timeout=15)
            self.after(0, lambda: self.app.set_status(f"Applied: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- appraisal ----------------------------------------------------

    def apply_appraisal(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        try:
            vals = [math.floor(float(v.get())) for v in self.ap_vars]
        except ValueError:
            self.app.set_status("Enter numbers.")
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        appr = 1 if self.appr_var.get() else 0
        run_async(self, lambda: self._apply_appraisal(client, row, vals, appr))

    def _apply_appraisal(self, client, row, vals, appr):
        try:
            res = client.send("item_set_appraisal", row, *vals, appr, timeout=15)
            self.after(0, lambda: self.app.set_status(f"Applied: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- element ------------------------------------------------------

    def _elem_label(self, cur, is_weapon):
        if cur == "ThunderElement":
            return "Lightning"
        if cur == "LightElement":
            return "Holy"
        if cur == "FireElement":
            return "Fire"
        if cur == "IceElement":
            return "Ice"
        if cur == "None":
            return "None"
        if cur == "several":
            return "Several bits set (invalid - pick one)"
        if cur.startswith("Slot"):
            return f"Ability slot {cur[4:]} enhanced"
        if cur == "PhysicalParam":
            return "Attack enhanced" if is_weapon else "Defense enhanced"
        if cur == "MagicParam":
            return ("Magick Attack enhanced" if is_weapon
                    else "Magick Defense enhanced")
        if cur == "BlowParam":
            return "Knockdown enhanced"
        if cur == "SlashDefence":
            return "Slash Defense enhanced"
        if cur == "StrikeDefence":
            return "Strike Defense enhanced"
        return cur

    def load_element(self):
        if not self.sel_row:
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._load_element(client, row))

    def _load_element(self, client, row):
        try:
            res = client.send("item_get_element", row, timeout=15)
            parts = res.split("|")
            cur = parts[0] if len(parts) > 0 else "?"
            allowed = parts[1] if len(parts) > 1 else "?"
            game_elem = parts[2] if len(parts) > 2 else "?"
            is_weapon = len(parts) > 3 and parts[3] == "1"
            cur_label = self._elem_label(cur, is_weapon)
            if allowed == "?":
                opts = ["Fire", "Ice", "Lightning", "Holy"]
                note = ("Allowed list unavailable - the game will ignore "
                        "disallowed elements.")
            elif allowed == "":
                opts = []
                note = "This item can't have an element (game rules)."
            else:
                opts = [o for o in allowed.split(",") if o]
                note = ""
            if not is_weapon:
                note = (("Elements are for weapons. " if note == "" else "")
                        + note).strip()
            values = [f"[current] {cur_label}",
                      "None - clear enhancement"] + opts
            res2 = client.send("item_get_elem_store", row, timeout=15)
            p2 = res2.split("|")
            computed = p2[0] if len(p2) > 0 else "?"
            over = p2[1] if len(p2) > 1 else ""
            pct_txt = f"Element %: {computed}"
            if over != "":
                pct_txt += f" (override: {over}%)"
            else:
                pct_txt += " (game default)"
            info = (f"Current: {cur_label}  |  Game computes: {game_elem}  |  "
                    f"{pct_txt}")
            if note:
                info += f"  |  {note}"

            def _ui():
                self.elem_combo.configure(values=values)
                self.elem_combo.set(values[0])
                self.elem_pct_var.set(computed)
                self.elem_info_var.set(info)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"

            def _ui2():
                self.elem_combo.configure(
                    values=["(this item has no ability data)"])
                self.elem_combo.set("(this item has no ability data)")
                self.elem_info_var.set("")
            self.after(0, lambda: (self.app.set_status(err), _ui2()))

    def apply_element(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        val = self.elem_combo.get()
        if val.startswith("[current]"):
            self.app.set_status("Element unchanged.")
            return
        if val in ("(select an item first)",
                   "(this item has no ability data)"):
            return
        want = "None" if val == "None - clear enhancement" else val
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._apply_element(client, row, want))

    def _apply_element(self, client, row, want):
        try:
            res = client.send("item_set_element", row, want, timeout=15)
            msg = f"Element set to {want} (marked appraised). {res}"

            def _ui():
                self.load_element()
                self.app.set_status(msg)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_elem_pct(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        val = self.elem_pct_var.get().strip()
        if val == "":
            self._send_elem_pct("clear")
            return
        try:
            pct = math.floor(float(val))
        except ValueError:
            self.app.set_status("Enter a number for Element %.")
            return
        if pct < 0:
            self.app.set_status("Element % cannot be negative.")
            return
        self._send_elem_pct(str(pct))

    def clear_elem_pct(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        self._send_elem_pct("clear")

    # -- rename -------------------------------------------------------

    def apply_item_name(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        name = self.rename_var.get().strip()
        if not name:
            self.app.set_status("Enter a name first.")
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._apply_item_name(client, row, name))

    def clear_item_name(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._apply_item_name(client, row, "clear"))

    def diag_item_name(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._diag_item_name(client))

    def probe_item_type(self):
        if not self.sel_row:
            self.app.set_status("Select an item first.")
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._probe_item_type(client, row))

    def _probe_item_type(self, client, row):
        try:
            res = client.send("item_type_probe", row, timeout=15)
            msg = res
            self.after(0, lambda: self.app.set_status(msg))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _diag_item_name(self, client):
        try:
            res = client.send("item_name_diag", timeout=15)
            msg = res
            self.after(0, lambda: self.app.set_status(msg))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _apply_item_name(self, client, row, name):
        try:
            res = client.send("item_set_name", row, name, timeout=15)
            msg = res

            def _ui():
                self.app.set_status(msg)
                self.reload_owners()
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def load_item_name(self):
        if not self.sel_row:
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._load_item_name(client, row))

    def _load_item_name(self, client, row):
        try:
            res = client.send("item_get_name", row, timeout=15)
            cur, _, custom = res.partition("|")

            def _ui():
                self.rename_var.set(custom or cur)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout):
            pass

    def _send_elem_pct(self, val):
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._apply_elem_pct(client, row, val))

    def _apply_elem_pct(self, client, row, val):
        try:
            res = client.send("item_set_elem_store", row, val, timeout=15)
            msg = f"Element % set ({val}). {res}"

            def _ui():
                self.load_element()
                self.app.set_status(msg)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- valid-skill filter -------------------------------------------

    def on_valid_toggle(self):
        if self.valid_var.get():
            self.load_valid(rescan=True)
        else:
            self.valid_set = None
            self.fill_slot_combos()

    def load_valid(self, rescan):
        if not self.sel_row:
            self.valid_set = None
            self.fill_slot_combos()
            return
        client = require_client(self.app)
        if not client:
            return
        row = self.sel_row
        run_async(self, lambda: self._load_valid(client, row, rescan))

    def _load_valid(self, client, row, rescan):
        try:
            res = client.send("eqmap_valid", row, 1 if rescan else 0, timeout=60)
            m = re.match(r"^([^|]*)\|([^|]*)\|([^|]*)\|(\d+)$", res)
            if not m:
                raise BridgeError("bad eqmap_valid response")
            _key, label, ids, n = m.groups()
            self.valid_set = {int(x) for x in re.findall(r"\d+", ids)}

            def _ui():
                self.fill_slot_combos()
                self.app.set_status(
                    f"Item type: {label} ({n} items scanned) - "
                    f"{len(self.valid_set)} skills seen on this type. "
                    "Skills never seen on it are hidden.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            self.valid_set = None
            self.after(0, lambda: (self.fill_slot_combos(),
                                   self.app.set_status(f"Item type map: {e}")))

    # -- probes -------------------------------------------------------

    def run_probe_cmd(self, cmd, filename, title, timeout=60):
        client = require_client(self.app)
        if not client:
            return
        tgt, jb = self.app.target(), self.app.job()
        self.app.set_status("Probing...")
        run_async(self, lambda: self._run_probe(client, cmd, filename, title,
                                                tgt, jb, timeout))

    def _run_probe(self, client, cmd, filename, title, tgt, jb, timeout):
        try:
            res = client.send(cmd, tgt, jb, timeout=timeout)
            text = client.read_sidecar(filename) or f"({filename} missing)"
            self.after(0, lambda: (show_probe(self, title, text),
                                   self.app.set_status(f"Probe done: {res}.")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
