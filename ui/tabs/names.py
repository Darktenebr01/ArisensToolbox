"""Names: rename the Arisen, the main pawn and hired pawns."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ListPanel, Field, PrimaryButton, GhostButton,
    QuietButton, caption, dev_only, run_async, require_client, show_probe,
)


def _clean_name(s):
    # '|' is the protocol separator; the game caps names at 12 chars and
    # rejects < >.
    s = "".join(ch for ch in (s or "") if ch not in "|\r\n<>").strip()
    return s[:12]


class NamesTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.hired_indices = []  # listbox row -> PW.list index
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(3, weight=1)

        header = PageHeader(
            self, "Names",
            "Rename the Arisen, the main pawn and hired pawns. Names apply "
            "immediately; save and reload to keep them.")
        header.grid(row=0, column=0, sticky="ew", pady=(0, T.PAD_L))
        header.action(GhostButton(header.actions, "Refresh all", width=110,
                                  command=self.refresh_async))
        dev_only(self, lambda: header.action(QuietButton(
            header.actions, "Diagnose", width=100,
            command=self.diagnose_async)))

        duo = ctk.CTkFrame(self, fg_color="transparent", width=1, height=1)
        duo.grid(row=1, column=0, sticky="ew", pady=(0, T.PAD_M))
        duo.grid_columnconfigure(0, weight=1)
        duo.grid_columnconfigure(1, weight=1)

        arisen = Section(duo, "Arisen", **{"row": 0, "column": 0,
                                           "sticky": "nsew",
                                           "padx": (0, T.PAD_M)})
        body = arisen.body
        self.arisen_cur = ctk.CTkLabel(body, text="—",
                                       font=T.font(T.SIZE_TITLE, "bold"),
                                       text_color=T.TEXT, anchor="w")
        self.arisen_cur.grid(row=0, column=0, sticky="w")
        row = Row(body)
        row.grid(row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        self.arisen_var = ctk.StringVar()
        Field(row, textvariable=self.arisen_var, width=180).pack(side="left")
        PrimaryButton(row, "Rename", width=92,
                      command=self.rename_arisen_async).pack(side="left",
                                                             padx=(T.PAD_S, 0))

        main = Section(duo, "Main pawn", **{"row": 0, "column": 1,
                                            "sticky": "nsew"})
        body = main.body
        self.main_cur = ctk.CTkLabel(body, text="—",
                                     font=T.font(T.SIZE_TITLE, "bold"),
                                     text_color=T.TEXT, anchor="w")
        self.main_cur.grid(row=0, column=0, sticky="w")
        row = Row(body)
        row.grid(row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        self.main_var = ctk.StringVar()
        Field(row, textvariable=self.main_var, width=180).pack(side="left")
        PrimaryButton(row, "Rename", width=92,
                      command=self.rename_main_async).pack(side="left",
                                                           padx=(T.PAD_S, 0))

        hired = Section(self, "Hired pawns", **{"row": 3, "column": 0,
                                                "sticky": "nsew"})
        body = hired.body
        body.grid_rowconfigure(0, weight=1)
        self.panel = ListPanel(body, height=7,
                               empty="Refresh to list the pawns in your party.")
        self.panel.grid(row=0, column=0, sticky="nsew")
        self.pawn_list = self.panel.listbox
        row = Row(body)
        row.grid(row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        self.hired_var = ctk.StringVar()
        Field(row, textvariable=self.hired_var, width=200).pack(side="left")
        PrimaryButton(row, "Rename selected", width=140,
                      command=self.rename_hired_async).pack(side="left",
                                                            padx=(T.PAD_S, 0))
        caption(body, "Hired pawns come and go with your party; refresh "
                      "after recruiting.",
                row=2, column=0, sticky="ew", pady=(T.PAD_S, 0))

    # -- read ----------------------------------------------------------

    def refresh_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._refresh(client))

    def diagnose_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._diagnose(client))

    def _diagnose(self, client):
        try:
            arisen = client.send("probe_name", "arisen", timeout=30)
            main = client.send("probe_name", "main", timeout=30)
            deep = client.send("probe_arisen", timeout=30)
            text = ("ARISEN\n" + arisen.replace(" // ", "\n") +
                    "\n\nMAIN PAWN\n" + main.replace(" // ", "\n") +
                    "\n\nARISEN NAME HUNT\n" + deep.replace(" // ", "\n"))
            self.after(0, lambda: show_probe(self, "Name probe", text))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _refresh(self, client):
        try:
            arisen = client.send("get_arisen_name", timeout=20)
            main = client.send("get_main_pawn_name", timeout=20)
            res = client.send("list_pawns", timeout=30)
            hired, indices = [], []
            for row in (res or "").split(";"):
                parts = row.split(",", 1)
                if len(parts) == 2 and parts[0].strip().isdigit():
                    i = int(parts[0])
                    if i == 1:
                        continue  # main pawn has its own card
                    hired.append(parts[1].strip())
                    indices.append(i)
            self.hired_indices = indices

            def _ui():
                self.arisen_cur.configure(text=arisen)
                self.main_cur.configure(text=main)
                self.panel.set_rows(hired)
                self.panel.set_empty("No hired pawns in the party.")
                self.app.set_status(
                    f"Names refreshed (arisen, main pawn, {len(hired)} hired).")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- rename --------------------------------------------------------

    def _rename(self, client, cmd, *args, undo=None):
        try:
            res = client.send(cmd, *args, timeout=20)
            if undo:
                label, ucmd, uargs = undo
                self.app.record_undo(
                    label,
                    lambda c, cc=ucmd, aa=uargs: c.send(cc, *aa, timeout=20))

            def _ui():
                self.app.set_status(res)
                self.refresh_async()
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def rename_arisen_async(self):
        name = _clean_name(self.arisen_var.get())
        if not name:
            self.app.set_status("Type a new name first.")
            return
        client = require_client(self.app)
        if client:
            old = self.arisen_cur.cget("text")
            undo = ((f"name '{old}'", "set_arisen_name", (old,))
                    if old and old != "—" else None)
            run_async(self, lambda: self._rename(
                client, "set_arisen_name", name, undo=undo))

    def rename_main_async(self):
        name = _clean_name(self.main_var.get())
        if not name:
            self.app.set_status("Type a new name first.")
            return
        client = require_client(self.app)
        if client:
            old = self.main_cur.cget("text")
            undo = ((f"pawn name '{old}'", "set_pawn_name", ("0", old))
                    if old and old != "—" else None)
            run_async(self, lambda: self._rename(
                client, "set_pawn_name", "0", name, undo=undo))

    def rename_hired_async(self):
        sel = self.pawn_list.curselection()
        if not sel:
            self.app.set_status("Select a hired pawn first.")
            return
        name = _clean_name(self.hired_var.get())
        if not name:
            self.app.set_status("Type a new name first.")
            return
        idx = self.hired_indices[sel[0]]
        client = require_client(self.app)
        if client:
            run_async(self, lambda: self._rename(client, "set_pawn_name",
                                                 str(idx), name))
