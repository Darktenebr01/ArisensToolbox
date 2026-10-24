"""Duplicate Items: copy inventory entries (dup_owners/dup_rows/dup_do)."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ScrollArea, ListPanel, Field, Combo, Check,
    Switch, PrimaryButton, GhostButton, QuietButton, caption, dev_only,
    run_async, require_client,
)

MAX_SHOWN = 500


class DuplicateItemsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.owner_idx = []   # lua owner indices in combo order
        self.rows = []        # parsed duprows rows
        self.shown = []
        self.sel = None       # selected lua row number
        self._search_after = None
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        header = PageHeader(
            self, "Duplicate Items",
            "Copy an inventory entry, or double the stack, without "
            "touching the save by hand.")
        header.grid(row=0, column=0, sticky="ew", pady=(0, T.PAD_L))
        header.action(GhostButton(header.actions, "Reload inventory",
                                  width=140, command=self.load_owners_async))

        self.scroll = ScrollArea(self)
        self.scroll.grid(row=1, column=0, sticky="nsew")

        filters = Section(self.scroll, "Inventory", **{
            "row": 0, "column": 0, "sticky": "ew", "pady": (0, T.PAD_M)})
        body = filters.body
        top = Row(body)
        top.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(top, text="Owner", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.owner_var = ctk.StringVar(value="(not loaded)")
        self.owner_combo = Combo(top, variable=self.owner_var,
                                 values=["(not loaded)"], width=320,
                                 command=lambda _: self.load_rows_async())
        self.owner_combo.pack(side="left")

        search = Row(body)
        search.grid(row=1, column=0, sticky="ew", pady=(T.PAD_S, 0))
        ctk.CTkLabel(search, text="Search", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.search_var = ctk.StringVar()
        self.search_var.trace_add("write", lambda *_: self._debounced_refresh())
        Field(search, textvariable=self.search_var, width=260).pack(side="left")
        self.equip_var = ctk.BooleanVar(value=False)
        Check(search, text="Equipment only", variable=self.equip_var,
              command=self.load_rows_async).pack(side="left",
                                                 padx=(T.PAD_M, 0))

        listing = Section(self.scroll, "Items", **{"row": 1, "column": 0,
                                                   "sticky": "ew",
                                                   "pady": (0, T.PAD_M)})
        body = listing.body
        self.panel = ListPanel(
            body, height=10, empty="Reload the inventory to list items.")
        self.panel.grid(row=0, column=0, sticky="nsew")
        self.listbox = self.panel.listbox
        self.listbox.bind("<<ListboxSelect>>", self.on_select)

        duplicate = Section(self.scroll, "Duplicate", **{"row": 2,
                                                         "column": 0,
                                                         "sticky": "ew"})
        body = duplicate.body
        self.sel_var = ctk.StringVar(value="Click an item to duplicate it.")
        ctk.CTkLabel(body, textvariable=self.sel_var,
                     font=T.font(T.SIZE_BODY), text_color=T.TEXT,
                     anchor="w").grid(row=0, column=0, sticky="ew")
        controls = Row(body)
        controls.grid(row=1, column=0, sticky="w", pady=(T.PAD_M, 0))
        ctk.CTkLabel(controls, text="Copies", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.copies_var = ctk.StringVar(value="1")
        Field(controls, textvariable=self.copies_var, width=64).pack(
            side="left")
        self.store_var = ctk.BooleanVar(value=False)
        Switch(controls, text="To storage", variable=self.store_var).pack(
            side="left", padx=(T.PAD_L, 0))
        self.props_var = ctk.BooleanVar(value=True)
        Switch(controls, text="Copy skills, enhancement and appraisal",
               variable=self.props_var).pack(side="left",
                                             padx=(T.PAD_L, 0))
        row = Row(body)
        row.grid(row=2, column=0, sticky="w", pady=(T.PAD_M, 0))
        row.add(PrimaryButton(row, "Duplicate selected", width=160,
                              command=self.duplicate_async))
        row.add(GhostButton(row, "Double the stack", width=140,
                            command=lambda: self._do_dup_async(0)))
        dev_only(self, lambda: QuietButton(row, "Probe selected", width=120,
                                          command=self.probe_async).pack(
            side="left"))
        caption(body, "New copies go to your inventory, or to storage when "
                      "ticked. Back up your save first; single-player only.",
                row=3, column=0, sticky="ew", pady=(T.PAD_M, 0))

    # -- search -------------------------------------------------------

    def _debounced_refresh(self):
        if self._search_after is not None:
            try:
                self.after_cancel(self._search_after)
            except Exception:
                pass
        self._search_after = self.after(140, self.refresh_list)

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
                        + ("  ← you" if isp.strip() == "1" else ""))

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
            sel = list(self.owner_combo.cget("values")).index(
                self.owner_var.get())
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
                self.app.set_status(f"{len(rows)} item(s) (game said {count}).")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- list ----------------------------------------------------------

    def refresh_list(self):
        tokens = self.search_var.get().lower().split()
        shown, rows = [], []
        for r in self.rows:
            if not all(t in r["lname"] or t in r["id"] for t in tokens):
                continue
            if len(shown) >= MAX_SHOWN:
                break
            shown.append(r)
            rows.append(("● " if r["equipped"] else "  ")
                        + f"{r['name']}   ×{r['count']}   (id {r['id']})")
        self.shown = shown
        self.panel.set_rows(rows)
        self.panel.set_empty("No item matches this search." if self.rows
                             else "Reload the inventory to list items.")

    def on_select(self, _event):
        sel = self.listbox.curselection()
        if sel and sel[0] < len(self.shown):
            r = self.shown[sel[0]]
            self.sel = r["i"]
            note = ("  ·  ID unknown, use Probe"
                    if r["id"] == "-1" else "")
            self.sel_var.set(
                f"{r['name']}  ·  you own {r['count']}{note}")

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
        run_async(self, lambda: self._do_dup(client, sel, copies, to_storage,
                                             props))

    def _do_dup(self, client, sel, copies, to_storage, props):
        try:
            res = client.send("dup_do", sel, copies, to_storage, props,
                              timeout=60)
            self.after(0, lambda: (self.app.set_status(res),
                                   self.load_rows_async()))
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
