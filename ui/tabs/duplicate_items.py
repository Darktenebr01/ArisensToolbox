"""Duplicate Items tab: copy inventory entries (dup_owners/dup_rows/dup_do/dup_probe)."""
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, Muted, PrimaryButton, GhostButton,
    Field, Combo, Check, StyledListbox, run_async, require_client,
)

MAX_SHOWN = 500


class DuplicateItemsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.owner_idx = []   # lua owner indices in combo order
        self.rows = []        # parsed duprows rows
        self.shown = []
        self.sel = None       # selected lua row number
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        H1(self, "Duplicate Items", row=0, column=0, sticky="w", pady=(0, 10))

        # inventory card
        card = Card(self, row=1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        orow = ctk.CTkFrame(cc, fg_color="transparent")
        orow.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(orow, **T.body("Inventory:")).pack(side="left")
        self.owner_var = ctk.StringVar(value="(not loaded)")
        self.owner_combo = Combo(
            orow, variable=self.owner_var, values=["(not loaded)"],
            width=340,
            command=lambda _: self.load_rows_async(),
        )
        self.owner_combo.pack(side="left", padx=8)
        GhostButton(orow, text="Reload inventory", width=140,
                    command=self.load_owners_async).pack(side="left")

        srow = ctk.CTkFrame(cc, fg_color="transparent")
        srow.grid(row=1, column=0, sticky="ew")
        ctk.CTkLabel(srow, **T.body("Search:")).pack(side="left")
        self.search_var = ctk.StringVar()
        self.search_var.trace_add("write", lambda *_: self.refresh_list())
        Field(srow, textvariable=self.search_var, width=220).pack(side="left", padx=8)
        self.equip_var = ctk.BooleanVar(value=False)
        Check(srow, text="Only weapons/armor/jewelry",
              variable=self.equip_var,
              command=self.load_rows_async).pack(side="left", padx=8)

        # list card
        card = Card(self, row=2, column=0, sticky="nsew", padx=4, pady=6)
        cc = card_content(card)
        cc.grid_rowconfigure(0, weight=1)
        self.listbox = StyledListbox(cc)
        self.listbox.grid(row=0, column=0, sticky="nsew")
        self.listbox.bind("<<ListboxSelect>>", self.on_select)
        sb = tk.Scrollbar(cc, orient="vertical", command=self.listbox.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.listbox.config(yscrollcommand=sb.set)

        # duplicate card
        card = Card(self, row=3, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        self.sel_var = ctk.StringVar(value="Click an item to duplicate it.")
        ctk.CTkLabel(cc, textvariable=self.sel_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=0, column=0, sticky="w", pady=(0, 6))

        crow = ctk.CTkFrame(cc, fg_color="transparent")
        crow.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(crow, **T.body("Copies to add:")).pack(side="left")
        self.copies_var = ctk.StringVar(value="1")
        Field(crow, textvariable=self.copies_var, width=70).pack(side="left", padx=(4, 16))
        self.store_var = ctk.BooleanVar(value=False)
        Check(crow, text="Send copies to storage",
              variable=self.store_var).pack(side="left", padx=8)
        self.props_var = ctk.BooleanVar(value=True)
        Check(crow, text="Copy skills / enhancement / appraisal (equipment)",
              variable=self.props_var).pack(side="left", padx=8)

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=2, column=0, sticky="w")
        PrimaryButton(brow, text="Duplicate selected", width=160,
                      command=self.duplicate_async).pack(side="left", padx=(0, 8))
        GhostButton(brow, text="Double the stack", width=140,
                    command=lambda: self._do_dup_async(0)).pack(side="left", padx=8)
        GhostButton(brow, text="Probe selected (writes REFramework log)", width=290,
                    command=self.probe_async).pack(side="left", padx=8)

        Muted(cc, "New copies go to your inventory (or storage if ticked). "
                  "Equipment copies get the same skills/enhancement when the box is ticked.",
              row=3, column=0, sticky="w", pady=(8, 0))
        Muted(cc, "Back up your save first. Single-player only.",
              row=4, column=0, sticky="w", pady=(2, 0))

    # -- data loading -------------------------------------------------

    def load_owners_async(self):
        client = require_client(self.app)
        if not client:
            return
        self.app.set_status("Reading the inventory...")
        run_async(self, lambda: self._load_owners(client))

    def _load_owners(self, client):
        try:
            res = client.send("dup_owners", timeout=60)
            idx, labels = [], []
            for row in (res or "").split(";"):
                parts = row.split(",")
                if len(parts) == 4 and parts[0].strip().isdigit():
                    i, key, count, isp = parts
                    idx.append(int(i))
                    labels.append(
                        f"owner {key.strip()} ({count.strip()} items)"
                        + ("  <- YOU" if isp.strip() == "1" else ""))
            def _ui():
                self.owner_idx = idx
                if labels:
                    self.owner_combo.configure(values=labels)
                    self.owner_var.set(labels[0])
                    self.load_rows_async()
                else:
                    self.app.set_status("No inventory found - load a save.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def load_rows_async(self):
        if not self.owner_idx:
            return
        client = require_client(self.app)
        if not client:
            return
        try:
            sel = self.owner_combo.cget("values").index(self.owner_var.get())
        except ValueError:
            return
        owner = self.owner_idx[sel]
        only_equip = 1 if self.equip_var.get() else 0
        run_async(self, lambda: self._load_rows(client, owner, only_equip))

    def _load_rows(self, client, owner, only_equip):
        try:
            count = client.send("dup_rows", owner, only_equip, timeout=60)
            text = client.read_sidecar("duprows.txt") or ""
            rows = []
            for line in text.splitlines():
                parts = line.split("\t")
                if len(parts) == 6 and parts[0].strip().isdigit():
                    i, name, sid, scount, eq, equipped = parts
                    rows.append({
                        "i": int(i), "name": name, "lname": name.lower(),
                        "id": sid.strip(), "count": scount.strip(),
                        "isequip": eq.strip() == "1",
                        "equipped": equipped.strip() == "1",
                    })
            self.rows = rows
            self.sel = None
            def _ui():
                self.sel_var.set("Click an item to duplicate it.")
                self.refresh_list()
                self.app.set_status(f"{len(rows)} item(s).")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- list ----------------------------------------------------------

    def refresh_list(self):
        tokens = self.search_var.get().lower().split()
        self.listbox.delete(0, tk.END)
        self.shown = []
        for r in self.rows:
            if all(t in r["lname"] or t in r["id"] for t in tokens):
                if len(self.shown) < MAX_SHOWN:
                    self.shown.append(r)
                    self.listbox.insert(
                        tk.END,
                        ("[E] " if r["equipped"] else "    ")
                        + f"{r['name']}   x{r['count']}   (id {r['id']})")

    def on_select(self, _event):
        sel = self.listbox.curselection()
        if sel and sel[0] < len(self.shown):
            r = self.shown[sel[0]]
            self.sel = r["i"]
            note = ("  - ID UNKNOWN, cannot duplicate (use Probe)"
                    if r["id"] == "-1" else "")
            self.sel_var.set(
                f"Selected: {r['name']}  (you own {r['count']}){note}")

    # -- actions --------------------------------------------------------

    def duplicate_async(self):
        try:
            n = int(self.copies_var.get())
        except ValueError:
            self.app.set_status("Enter a number of copies (1 or more).")
            return
        if n < 1:
            self.app.set_status("Enter a number of copies (1 or more).")
            return
        self._do_dup_async(n)

    def _do_dup_async(self, copies):
        if not self.sel:
            self.app.set_status("Select an item first.")
            return
        client = require_client(self.app)
        if not client:
            return
        sel, to_storage = self.sel, 1 if self.store_var.get() else 0
        props = 1 if self.props_var.get() else 0
        run_async(self, lambda: self._do_dup(client, sel, copies, to_storage, props))

    def _do_dup(self, client, sel, copies, to_storage, props):
        try:
            res = client.send("dup_do", sel, copies, to_storage, props, timeout=60)
            self.after(0, lambda: (self.app.set_status(res), self.load_rows_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def probe_async(self):
        if not self.sel:
            self.app.set_status("Select an item first.")
            return
        client = require_client(self.app)
        if not client:
            return
        sel = self.sel
        run_async(self, lambda: self._probe(client, sel))

    def _probe(self, client, sel):
        try:
            res = client.send("dup_probe", sel, timeout=60)
            self.after(0, lambda: self.app.set_status(res))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
