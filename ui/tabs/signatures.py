"""Signatures tab: look up native function addresses (fn_addr) for the cheats.

Developer tool: collects the code addresses of the functions the cheats use,
so a standalone table (no REFramework needed) can be built. Look results up
one by one (or Harvest all), then copy the text.
"""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, Muted, PrimaryButton, GhostButton,
    Field, Combo, run_async, require_client,
)

# (type, method, argc) — mirrors the CE table's harvest list
TARGETS = [
    ("app.ItemManager", "getItem", 3),
    ("app.ItemManager", "forceGetItemToWarehouse", 2),
    ("app.ItemManager", "getItemData", 1),
    ("app.PawnDataContext", "setGoodReviewNum", 1),
    ("app.PawnDataContext", "setLikeReviewNum", 1),
    ("app.PawnDataContext", "addBadge", 1),
    ("app.PawnManager", "get_MainPawn", 0),
    ("app.CharacterManager", "get_ManualPlayer", 0),
]


class SignaturesTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(4, weight=1)

        H1(self, "Signatures", row=0, column=0, sticky="w", pady=(0, 4))
        Muted(self, "Collects the code addresses of the functions the cheats use, so a standalone "
                    "table (no REFramework needed) can be built. Look up, then copy and send the text.",
              row=1, column=0, sticky="w", pady=(0, 10))

        # target picker + custom fields
        card = Card(self, row=2, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        prow = ctk.CTkFrame(cc, fg_color="transparent")
        prow.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        ctk.CTkLabel(prow, **T.body("Preset:")).pack(side="left")
        self.preset_var = ctk.StringVar(value=self._label(TARGETS[0]))
        self.preset_combo = Combo(
            prow, variable=self.preset_var,
            values=[self._label(t) for t in TARGETS],
            width=380, command=self._on_preset,
        )
        self.preset_combo.pack(side="left", padx=8)

        frow = ctk.CTkFrame(cc, fg_color="transparent")
        frow.grid(row=1, column=0, sticky="ew")
        ctk.CTkLabel(frow, **T.body("Type:")).pack(side="left")
        self.type_var = ctk.StringVar(value=TARGETS[0][0])
        Field(frow, textvariable=self.type_var, width=220).pack(side="left", padx=(4, 12))
        ctk.CTkLabel(frow, **T.body("Method:")).pack(side="left")
        self.method_var = ctk.StringVar(value=TARGETS[0][1])
        Field(frow, textvariable=self.method_var, width=220).pack(side="left", padx=(4, 12))
        ctk.CTkLabel(frow, **T.body("Args:")).pack(side="left")
        self.argc_var = ctk.StringVar(value=str(TARGETS[0][2]))
        Field(frow, textvariable=self.argc_var, width=50).pack(side="left", padx=(4, 12))
        PrimaryButton(frow, text="Look up", width=100,
                      command=self.lookup_async).pack(side="left", padx=8)
        GhostButton(frow, text="Harvest all", width=110,
                    command=self.harvest_async).pack(side="left", padx=4)

        # result log
        self.log = ctk.CTkTextbox(self, font=("Consolas", 11), wrap="none",
                                  fg_color=T.BG, text_color=T.TEXT,
                                  border_color=T.BORDER, border_width=1)
        self.log.grid(row=3, column=0, sticky="nsew", pady=(0, 6))
        self.log.configure(state="disabled")

        GhostButton(self, text="Copy to clipboard", width=160,
                    command=self._copy).grid(row=4, column=0, sticky="w")

    @staticmethod
    def _label(t):
        return f"{t[0]}.{t[1]}  ({t[2]} args)"

    def _on_preset(self, _value):
        try:
            t = TARGETS[[self._label(x) for x in TARGETS].index(self.preset_var.get())]
        except ValueError:
            return
        self.type_var.set(t[0])
        self.method_var.set(t[1])
        self.argc_var.set(str(t[2]))

    def _append(self, line):
        def _ui():
            self.log.configure(state="normal")
            self.log.insert("end", line + "\n")
            self.log.see("end")
            self.log.configure(state="disabled")
        self.after(0, _ui)

    def _copy(self):
        text = self.log.get("1.0", "end").strip()
        self.clipboard_clear()
        self.clipboard_append(text)
        self.app.set_status("Copied.")

    # -- actions ----------------------------------------------------------

    def lookup_async(self):
        client = require_client(self.app)
        if not client:
            return
        t, m = self.type_var.get().strip(), self.method_var.get().strip()
        try:
            argc = int(self.argc_var.get())
        except ValueError:
            self.app.set_status("Args must be a number.")
            return
        if not t or not m:
            self.app.set_status("Enter a type and method.")
            return
        run_async(self, lambda: self._lookup(client, [(t, m, argc)]))

    def harvest_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._lookup(client, list(TARGETS)))

    def _lookup(self, client, targets):
        for t, m, argc in targets:
            try:
                addr = client.send("fn_addr", t, m, argc, timeout=15)
                self._append(f"{t}.{m}  addr={addr}")
            except (BridgeError, BridgeTimeout) as e:
                self._append(f"{t}.{m}  ERROR {e}")
        self.after(0, lambda: self.app.set_status("Done."))
