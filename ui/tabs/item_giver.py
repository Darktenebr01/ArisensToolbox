"""Item Giver tab: load the game's item list, search, give to inventory/storage."""
import threading
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, PrimaryButton, GhostButton, Field, StyledListbox,
)

MAX_SHOWN = 300


class ItemGiverTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.items = []   # [(id, name, lname)]
        self.shown = []   # items currently in the listbox
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        H1(self, "Item Giver", row=0, column=0, sticky="w", pady=(0, 10))

        # search + list card
        card = Card(self, row=1, column=0, sticky="nsew", padx=4, pady=6)
        cc = card_content(card)
        cc.grid_rowconfigure(1, weight=1)
        srow = ctk.CTkFrame(cc, fg_color="transparent")
        srow.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        ctk.CTkLabel(srow, **T.body("Search (name or ID):")).pack(side="left")
        self.search_var = ctk.StringVar()
        self.search_var.trace_add("write", lambda *_: self.refresh_list())
        Field(srow, textvariable=self.search_var, width=320).pack(side="left", padx=8)
        PrimaryButton(
            srow, text="Load / reload item list", width=180,
            command=self.load_items_async,
        ).pack(side="right")

        lframe = ctk.CTkFrame(cc, fg_color="transparent")
        lframe.grid(row=1, column=0, sticky="nsew")
        lframe.grid_columnconfigure(0, weight=1)
        lframe.grid_rowconfigure(0, weight=1)
        self.listbox = StyledListbox(lframe)
        self.listbox.grid(row=0, column=0, sticky="nsew")
        self.listbox.bind("<<ListboxSelect>>", self.on_select)
        sb = tk.Scrollbar(lframe, orient="vertical", command=self.listbox.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.listbox.config(yscrollcommand=sb.set)

        # give controls card
        card2 = Card(self, row=2, column=0, sticky="ew", padx=4, pady=6)
        cc2 = card_content(card2)
        self.sel_var = ctk.StringVar(value="No item loaded - click Load first.")
        ctk.CTkLabel(cc2, textvariable=self.sel_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=0, column=0, sticky="w", pady=(0, 8))
        grow = ctk.CTkFrame(cc2, fg_color="transparent")
        grow.grid(row=1, column=0, sticky="w")
        ctk.CTkLabel(grow, **T.body("Item ID:")).pack(side="left")
        self.id_var = ctk.StringVar(value="1")
        Field(grow, textvariable=self.id_var, width=100).pack(side="left", padx=(4, 16))
        ctk.CTkLabel(grow, **T.body("Quantity:")).pack(side="left")
        self.qty_var = ctk.StringVar(value="1")
        Field(grow, textvariable=self.qty_var, width=70).pack(side="left", padx=(4, 16))
        PrimaryButton(grow, text="Give item", width=110,
                      command=lambda: self.give_async(False)).pack(side="left", padx=4)
        GhostButton(grow, text="Send to storage", width=140,
                    command=lambda: self.give_async(True)).pack(side="left", padx=4)

    # -- helpers ------------------------------------------------------

    def _require_client(self):
        if not self.app.client:
            self.app.set_status("Not connected - go to the Connection tab first.")
            return None
        return self.app.client

    def _run(self, fn):
        threading.Thread(target=fn, daemon=True).start()

    # -- actions ------------------------------------------------------

    def load_items_async(self):
        client = self._require_client()
        if not client:
            return
        self.app.set_status("Loading the item list from the game...")
        self._run(lambda: self._load_items(client))

    def _load_items(self, client):
        try:
            count = client.send("list_items", timeout=60)
            text = client.read_sidecar("items.txt")
            if not text:
                raise BridgeError("items.txt missing")
            items = []
            for line in text.splitlines():
                if "\t" not in line:
                    continue
                sid, name = line.split("\t", 1)
                if sid.strip().isdigit():
                    items.append((int(sid), name.strip(), name.strip().lower()))
            self.items = items
            self.after(0, lambda: (
                self.refresh_list(),
                self.app.set_status(f"Loaded {len(items)} items (game said {count})."),
            ))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Item list failed: {e}"))

    def refresh_list(self):
        tokens = self.search_var.get().lower().split()
        self.listbox.delete(0, tk.END)
        self.shown = []
        n = 0
        for iid, name, lname in self.items:
            sid = str(iid)
            if all(t in lname or t in sid for t in tokens):
                n += 1
                if n <= MAX_SHOWN:
                    self.listbox.insert(tk.END, f"{iid}   {name}")
                    self.shown.append((iid, name))
        if n > MAX_SHOWN:
            self.app.set_status(f"{n} match(es) - showing first {MAX_SHOWN}, refine the search.")
        elif self.items:
            self.app.set_status(f"{n} match(es).")

    def on_select(self, _event):
        sel = self.listbox.curselection()
        if sel and sel[0] < len(self.shown):
            iid, name = self.shown[sel[0]]
            self.id_var.set(str(iid))
            self.sel_var.set(f"Selected: {name} (ID {iid})")

    def give_async(self, to_storage):
        client = self._require_client()
        if not client:
            return
        try:
            iid = int(self.id_var.get())
            qty = int(self.qty_var.get())
        except ValueError:
            self.app.set_status("Enter a numeric Item ID and Quantity.")
            return
        if qty < 1:
            self.app.set_status("Quantity must be at least 1.")
            return
        self._run(lambda: self._give(client, iid, qty, to_storage))

    def _give(self, client, iid, qty, to_storage):
        try:
            res = client.send("give_item", iid, qty, 1 if to_storage else 0, timeout=15)
            self.after(0, lambda: self.app.set_status(f"{res}: {qty} x item {iid}"))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
