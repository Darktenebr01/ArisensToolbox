"""Upgraded Skills tab: write JobNN_ExSkill1..5 into the equipped weapon's special-skill slots."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    run_async, require_client,
    Card, card_content, H1, Muted,
    PrimaryButton, GhostButton, Check,
)


class UpgradedSkillsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)
        app.register_refreshable(self)

        H1(self, "Upgraded Skills", row=0, column=0, sticky="w", pady=(0, 8))
        Muted(self, "Upgraded weapon skills (Shearing Wind, Fanged Rupture, Detonate and Dash...) "
                    "are item special skills: JobNN_ExSkill1..5.",
              row=1, column=0, sticky="w")
        Muted(self, "Pick up to 4. They are written into the special-skill slots of the target's "
                    "EQUIPPED weapon(s) (target + vocation = top bar).",
              row=2, column=0, sticky="w", pady=(0, 8))

        slots_card = Card(self, row=3, column=0, sticky="ew", padx=4, pady=6)
        slots = card_content(slots_card)
        self.check_vars = []
        for k in range(1, 6):
            v = ctk.BooleanVar(value=k <= 3)
            self.check_vars.append(v)
            Check(slots,
                  f"ExSkill {k}  (which upgrade it is: apply it and look at the in-game skill menu)",
                  variable=v).grid(row=k - 1, column=0, sticky="w", pady=3)

        apply_card = Card(self, row=4, column=0, sticky="ew", padx=4, pady=6)
        apl = card_content(apply_card)
        PrimaryButton(apl, "Apply to equipped weapon(s)", command=self.apply_async,
                      width=220).grid(row=0, column=0, sticky="w")
        GhostButton(apl, "Undo last apply", command=self.undo_async,
                    width=140).grid(row=0, column=1, sticky="w", padx=(8, 0))

        self.note_var = ctk.StringVar(value="")
        ctk.CTkLabel(apl, textvariable=self.note_var, text_color=T.MUTED,
                     wraplength=700, justify="left").grid(row=1, column=0, columnspan=2,
                                                          sticky="w", pady=(8, 0))
        Muted(apl, "This overwrites the weapon's current special skills "
                   "(Undo restores them while the game stays open).",
              row=2, column=0, columnspan=2, sticky="w", pady=(8, 0))
        Muted(apl, "Equip the weapon you want first. Vocation in the top bar must match "
                   "the equipped weapon's vocation.",
              row=3, column=0, columnspan=2, sticky="w")

    def _picked(self):
        return ",".join(str(k + 1) for k, v in enumerate(self.check_vars) if v.get())

    def apply_async(self):
        client = require_client(self.app)
        if not client:
            return
        picks = self._picked()
        if not picks:
            self.app.set_status("Tick at least one ExSkill.")
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_apply(client, tgt, job, picks))

    def _do_apply(self, client, tgt, job, picks):
        try:
            res = client.send("exskill_equip", tgt, job, picks, timeout=30)
            self.after(0, lambda: (
                self.app.set_status(f"Applied: {res}"),
                self.note_var.set("Applied. Re-open the skill menu in game "
                                   "(or unequip/re-equip the weapon) to see the change."),
            ))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def undo_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_undo(client, tgt))

    def _do_undo(self, client, tgt):
        try:
            res = client.send("exskill_undo", tgt, timeout=30)
            self.after(0, lambda: (
                self.app.set_status(f"Undone: {res}"),
                self.note_var.set(""),
            ))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def refresh_skills(self):
        pass  # nothing target-specific to reload here
