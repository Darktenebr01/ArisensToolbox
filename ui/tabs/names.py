"""Names tab: rename the Arisen, the main pawn and hired pawns."""
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, H2, Muted, PrimaryButton, GhostButton,
    Field, StyledListbox, run_async, require_client, show_probe,
)


def _clean_name(s):
    # '|' is the protocol separator; keep names protocol-safe.
    # The game caps names at 12 chars and rejects < >.
    s = "".join(ch for ch in (s or "") if ch not in "|\r\n<>").strip()
    return s[:12]


class NamesTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.hired_indices = []  # listbox row -> PW.list index
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(4, weight=1)

        H1(self, "Names", row=0, column=0, sticky="w", pady=(0, 4))
        Muted(self, "Rename the Arisen, your main pawn and hired pawns. "
                    "Renames apply immediately; save the game and reload to keep them.",
              row=1, column=0, sticky="w", pady=(0, 8))

        brow = ctk.CTkFrame(self, fg_color="transparent")
        brow.grid(row=2, column=0, sticky="w", pady=(0, 4))
        GhostButton(brow, text="Refresh all", width=110,
                    command=self.refresh_async).pack(side="left")
        GhostButton(brow, text="Diagnose", width=110,
                    command=self.diagnose_async).pack(side="left", padx=(8, 0))

        # Arisen card
        card = Card(self, row=3, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        H2(cc, "Arisen (you)", row=0, column=0, sticky="w", pady=(0, 6))
        arow = ctk.CTkFrame(cc, fg_color="transparent")
        arow.grid(row=1, column=0, sticky="ew")
        ctk.CTkLabel(arow, **T.body("Current:")).pack(side="left")
        self.arisen_cur = ctk.CTkLabel(arow, text="—",
                                       font=(T.FONT_FAMILY, 13, "bold"),
                                       text_color=T.ACCENT)
        self.arisen_cur.pack(side="left", padx=(6, 16))
        self.arisen_var = ctk.StringVar()
        Field(arow, textvariable=self.arisen_var, width=180).pack(side="left", padx=(0, 8))
        PrimaryButton(arow, text="Rename", width=80,
                      command=self.rename_arisen_async).pack(side="left", padx=4)

        # Main pawn card
        card = Card(self, row=4, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        H2(cc, "Main pawn", row=0, column=0, sticky="w", pady=(0, 6))
        mrow = ctk.CTkFrame(cc, fg_color="transparent")
        mrow.grid(row=1, column=0, sticky="ew")
        ctk.CTkLabel(mrow, **T.body("Current:")).pack(side="left")
        self.main_cur = ctk.CTkLabel(mrow, text="—",
                                     font=(T.FONT_FAMILY, 13, "bold"),
                                     text_color=T.ACCENT)
        self.main_cur.pack(side="left", padx=(6, 16))
        self.main_var = ctk.StringVar()
        Field(mrow, textvariable=self.main_var, width=180).pack(side="left", padx=(0, 8))
        PrimaryButton(mrow, text="Rename", width=80,
                      command=self.rename_main_async).pack(side="left", padx=4)

        # Hired pawns card
        card = Card(self, row=5, column=0, sticky="nsew", padx=4, pady=6)
        cc = card_content(card)
        cc.grid_rowconfigure(1, weight=1)
        H2(cc, "Hired pawns", row=0, column=0, sticky="w", pady=(0, 6))
        self.pawn_list = StyledListbox(cc, height=6)
        self.pawn_list.grid(row=1, column=0, sticky="nsew", pady=(0, 6))
        sb = tk.Scrollbar(cc, orient="vertical", command=self.pawn_list.yview)
        sb.grid(row=1, column=1, sticky="ns")
        self.pawn_list.config(yscrollcommand=sb.set)

        prow = ctk.CTkFrame(cc, fg_color="transparent")
        prow.grid(row=2, column=0, sticky="ew")
        self.hired_var = ctk.StringVar()
        Field(prow, textvariable=self.hired_var, width=180).pack(side="left", padx=(0, 8))
        PrimaryButton(prow, text="Rename selected", width=130,
                      command=self.rename_hired_async).pack(side="left", padx=4)

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
            self.after(0, lambda: show_probe(self, "Name probe - copy all of it", text))
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
                self.pawn_list.delete(0, tk.END)
                for h in hired:
                    self.pawn_list.insert(tk.END, h)
                self.app.set_status(
                    f"Names refreshed (arisen, main pawn, {len(hired)} hired).")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- rename --------------------------------------------------------

    def _rename(self, client, cmd, *args):
        try:
            res = client.send(cmd, *args, timeout=20)
            self.after(0, lambda: (
                self.app.set_status(res),
                self.refresh_async()))
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
            run_async(self, lambda: self._rename(client, "set_arisen_name", name))

    def rename_main_async(self):
        name = _clean_name(self.main_var.get())
        if not name:
            self.app.set_status("Type a new name first.")
            return
        client = require_client(self.app)
        if client:
            run_async(self, lambda: self._rename(client, "set_pawn_name", "0", name))

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
            run_async(self, lambda: self._rename(client, "set_pawn_name", str(idx), name))
