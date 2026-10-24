"""Item Giver: search the game's item list and give items to the inventory."""
import tkinter as tk

import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ListPanel, Field, PrimaryButton, GhostButton,
    caption, run_async,
)


def parse_items(text):
    """Parse items.txt content -> (items, data_lines).

    items is [(id, name, lname)]; data_lines counts the non-empty lines in
    the file so the UI can report the whole chain (game count / file lines /
    parsed / shown) and silent loss becomes visible.
    """
    items = []
    lines = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        lines += 1
        if "\t" not in line:
            continue
        sid, name = line.split("\t", 1)
        if sid.strip().isdigit():
            items.append((int(sid), name.strip(), name.strip().lower()))
    return items, lines


class ItemGiverTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.items = []   # [(id, name, lname)]
        self.shown = []   # items currently in the listbox
        self._id_set = set()
        self._search_after = None
        self._recent = []  # [(id, name, qty)]
        self.grid_columnconfigure(0, weight=1)
        self.grid_columnconfigure(1, minsize=340)
        self.grid_rowconfigure(1, weight=1)

        header = PageHeader(
            self, "Item Giver",
            "Give any item in the game to your inventory or storage.")
        header.grid(row=0, column=0, columnspan=2, sticky="ew",
                    pady=(0, T.PAD_L))
        self.reload_btn = GhostButton(header.actions, "Reload list", width=112,
                                      command=self.load_items_async)
        header.action(self.reload_btn)

        library = Section(self, "Library", **{"row": 1, "column": 0,
                                             "sticky": "nsew",
                                             "padx": (0, T.PAD_M)})
        body = library.body
        body.grid_rowconfigure(1, weight=1)

        search = Row(body)
        search.grid(row=0, column=0, sticky="ew", pady=(0, T.PAD_S))
        ctk.CTkLabel(search, text="Search", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.search_var = ctk.StringVar()
        self._search_after = None
        self.search_var.trace_add("write", lambda *_: self._debounced_refresh())
        self.search_field = Field(search, textvariable=self.search_var,
                                  width=320)
        self.search_field.pack(side="left", fill="x", expand=True)
        self.count_var = ctk.StringVar(value="")
        ctk.CTkLabel(search, textvariable=self.count_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_M, 0))

        self._list_var = tk.StringVar()
        self.panel = ListPanel(
            body, height=16, empty="Load the item list to browse every item.")
        self.panel.grid(row=1, column=0, sticky="nsew")
        self.listbox = self.panel.listbox
        self.listbox.configure(listvariable=self._list_var)
        self.listbox.bind("<<ListboxSelect>>", self.on_select)

        caption(body,
                "The list comes from the game (reframework/data/ddbridge/"
                "items.txt) and is cached, so it also works offline after "
                "one successful load.",
                row=2, column=0, sticky="ew", pady=(T.PAD_S, 0))

        give = Section(self, "Give item", **{"row": 1, "column": 1,
                                            "sticky": "nsew"})
        body = give.body
        self.sel_var = ctk.StringVar(value="No item selected")
        self.sel_label = ctk.CTkLabel(
            body, textvariable=self.sel_var, font=T.font(T.SIZE_BODY, "bold"),
            text_color=T.TEXT, anchor="w", justify="left")
        self.sel_label.grid(row=0, column=0, columnspan=2, sticky="ew")
        self.sel_hint = ctk.StringVar(value="Pick a row from the list, or "
                                            "type an item ID below.")
        ctk.CTkLabel(body, textvariable=self.sel_hint,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                     anchor="w", justify="left", wraplength=280).grid(
            row=1, column=0, columnspan=2, sticky="ew", pady=(2, T.PAD_M))

        ctk.CTkLabel(body, text="Item ID", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).grid(row=2, column=0, sticky="w")
        ctk.CTkLabel(body, text="Quantity", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).grid(row=2, column=1, sticky="w",
                                              padx=(T.PAD_M, 0))
        self.id_var = ctk.StringVar(value="1")
        self.qty_var = ctk.StringVar(value="1")
        Field(body, textvariable=self.id_var, width=140).grid(
            row=3, column=0, sticky="ew", pady=(3, T.PAD_M))
        Field(body, textvariable=self.qty_var, width=120).grid(
            row=3, column=1, sticky="ew", padx=(T.PAD_M, 0),
            pady=(3, T.PAD_M))

        self.give_btn = PrimaryButton(body, "Give item",
                                      command=lambda: self.give_async(False))
        self.give_btn.grid(row=4, column=0, columnspan=2, sticky="ew")
        GhostButton(body, "Send to storage",
                    command=lambda: self.give_async(True)).grid(
            row=5, column=0, columnspan=2, sticky="ew", pady=(T.PAD_S, 0))

        ctk.CTkLabel(body, text="RECENT", font=T.font(T.SIZE_MICRO, "bold"),
                     text_color=T.FAINT, anchor="w").grid(
            row=6, column=0, columnspan=2, sticky="w", pady=(T.PAD_M, 0))
        self.recent_panel = ListPanel(
            body, height=2, empty="Items you give appear here.")
        self.recent_panel.grid(row=7, column=0, columnspan=2, sticky="ew",
                               pady=(T.PAD_XS, 0))
        self.recent_panel.listbox.bind("<<ListboxSelect>>", self._on_recent)

        self.search_field.bind("<Return>", lambda _e: self.give_async(False))

    # -- helpers ------------------------------------------------------

    def _require_client(self):
        if not self.app.client:
            self.app.set_status("Not connected - open Connection and press "
                                "Start.")
            return None
        return self.app.client

    def focus_search(self):
        try:
            self.search_field.focus_set()
        except Exception:
            pass

    def _debounced_refresh(self):
        """Rebuild the list 140 ms after the last keystroke, not per key."""
        if self._search_after is not None:
            try:
                self.after_cancel(self._search_after)
            except Exception:
                pass
        self._search_after = self.after(140, self.refresh_list)

    # -- loading ------------------------------------------------------

    def load_items_async(self):
        client = self.app.client
        if not client:
            text = self.app.read_cached_sidecar("items.txt")
            if text:
                self._fill_items(text, "cache (offline)")
            else:
                self.app.set_status("Not connected and no cached item list "
                                    "yet - connect once to download it.")
            return
        self.reload_btn.configure(text="Loading...", state="disabled")
        self.app.set_status("Loading the item list from the game...")
        run_async(self, lambda: self._load_items(client))

    def _fill_items(self, text, source):
        items, lines = parse_items(text)
        self.items = items
        self._id_set = {i for i, _n, _l in items}
        self.refresh_list()
        self.app.set_status(
            f"Loaded {len(items)} items from {source} "
            f"(items.txt: {lines} lines, {len(items)} parsed, "
            f"{len(self.shown)} shown).")

    def _load_items(self, client):
        try:
            count = client.send("list_items", timeout=60)
            text = client.read_sidecar("items.txt")
            if not text:
                raise BridgeError("items.txt missing")
            self.app.cache_sidecar("items.txt", text)
            items, lines = parse_items(text)
            self.after(0, lambda: self._apply_items(
                items, lines, count, "the game"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Item list failed: {e}"
            self.after(0, lambda: self.app.set_status(err))
        finally:
            self.after(0, lambda: self.reload_btn.configure(
                text="Reload list", state="normal"))

    def _apply_items(self, items, lines, count, source):
        self.items = items
        self._id_set = {i for i, _n, _l in items}
        self.refresh_list()
        self.app.set_status(
            f"Loaded {len(items)} items from {source} (game said {count}; "
            f"items.txt: {lines} lines, {len(items)} parsed, "
            f"{len(self.shown)} shown).")

    def refresh_list(self):
        tokens = self.search_var.get().lower().split()
        shown = []
        rows = []
        for iid, name, lname in self.items:
            sid = str(iid)
            if all(t in lname or t in sid for t in tokens):
                shown.append((iid, name))
                rows.append(f"{iid}   {name}")
        self.shown = shown
        # One bulk assignment keeps 2,500-row filtering instant.
        self._list_var.set(tuple(rows))
        self.panel.sync_empty()
        if self.items:
            self.count_var.set(f"{len(shown)} / {len(self.items)}")
            self.panel.set_empty("No item matches this search.")

    def on_select(self, _event):
        sel = self.listbox.curselection()
        if sel and sel[0] < len(self.shown):
            iid, name = self.shown[sel[0]]
            self.id_var.set(str(iid))
            self.sel_var.set(name)
            self.sel_hint.set(f"Item ID {iid} · {len(self.items)} items loaded")

    # -- giving -------------------------------------------------------

    def give_async(self, to_storage):
        client = self._require_client()
        if not client:
            return
        try:
            iid = int(self.id_var.get())
            qty = int(self.qty_var.get())
        except ValueError:
            self.app.set_status("Enter a numeric item ID and quantity.")
            return
        if qty < 1 or qty > 999:
            self.app.set_status("Quantity must be between 1 and 999.")
            return
        if iid < 1:
            self.app.set_status("Item ID must be a positive number.")
            return
        # With the table loaded, an unknown ID is a typo, not a discovery.
        if self.items and iid not in self._id_set:
            self.app.set_status(
                f"Item ID {iid} is not in the loaded list - check the ID.")
            return
        run_async(self, lambda: self._give(client, iid, qty, to_storage))

    def _give(self, client, iid, qty, to_storage):
        try:
            res = client.send("give_item", iid, qty, 1 if to_storage else 0,
                              timeout=15)
            self.after(0, lambda: self._after_give(iid, qty, res))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _after_give(self, iid, qty, res):
        name = next((n for i, n, _l in self.items if i == iid), f"item {iid}")
        self.app.set_status(f"{res}: {qty} x {name}")
        self._recent = [(iid, name, qty)] + [
            r for r in self._recent if r[0] != iid][:4]
        self.recent_panel.set_rows([f"{qty} x {n}" for _i, n, _q in self._recent])

    def _on_recent(self, _event):
        sel = self.recent_panel.listbox.curselection()
        if sel and sel[0] < len(self._recent):
            iid, name, qty = self._recent[sel[0]]
            self.id_var.set(str(iid))
            self.qty_var.set(str(qty))
            self.sel_var.set(name)
            self.sel_hint.set(f"Item ID {iid} · from your recent list")
