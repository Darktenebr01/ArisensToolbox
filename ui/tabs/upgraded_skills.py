"""Upgraded Skills: write JobNN_ExSkill1..5 into the equipped weapon."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, Switch, PrimaryButton, GhostButton, caption,
    run_async, require_client,
)


class UpgradedSkillsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.grid_columnconfigure(0, weight=1)
        app.register_refreshable(self)

        PageHeader(
            self, "Upgraded Skills",
            "Upgraded weapon skills (Shearing Wind, Fanged Rupture, Detonate) "
            "are item special skills: JobNN_ExSkill1-5.").grid(
                row=0, column=0, sticky="ew", pady=(0, T.PAD_L))

        picks = Section(
            self, "Pick up to four",
            hint="Slots are written into the special-skill slots of the "
                 "target's equipped weapon. Apply, then open the in-game "
                 "skill menu to see which upgrade each slot is.",
            **{"row": 1, "column": 0, "sticky": "ew", "pady": (0, T.PAD_M)})
        body = picks.body
        self.check_vars = []
        for k in range(1, 6):
            var = ctk.BooleanVar(value=k <= 3)
            self.check_vars.append(var)
            Switch(body, text=f"ExSkill {k}", variable=var).grid(
                row=k - 1, column=0, sticky="w", pady=T.PAD_XS)

        apply_card = Section(self, "Apply", **{"row": 2, "column": 0,
                                              "sticky": "ew"})
        body = apply_card.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="w")
        row.add(PrimaryButton(row, "Apply to equipped weapon", width=200,
                              command=self.apply_async))
        row.add(GhostButton(row, "Undo last apply", width=140,
                            command=self.undo_async))
        self.note_var = ctk.StringVar(value="")
        ctk.CTkLabel(body, textvariable=self.note_var,
                     font=T.font(T.SIZE_BODY), text_color=T.TEXT,
                     anchor="w", justify="left", wraplength=700).grid(
            row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        caption(body, "This overwrites the weapon's current special skills. "
                      "Undo restores them while the game stays open. Equip "
                      "the weapon first and match the vocation in the top "
                      "bar.",
                row=2, column=0, sticky="ew", pady=(T.PAD_S, 0))

    def _picked(self):
        return ",".join(str(k + 1) for k, v in enumerate(self.check_vars)
                        if v.get())

    def apply_async(self):
        client = require_client(self.app)
        if not client:
            return
        picks = self._picked()
        if not picks:
            self.app.set_status("Pick at least one ExSkill.")
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_apply(client, tgt, job, picks))

    def _do_apply(self, client, tgt, job, picks):
        try:
            res = client.send("exskill_equip", tgt, job, picks, timeout=30)

            def _ui():
                self.app.set_status(f"Applied: {res}")
                self.note_var.set(
                    "Applied. Re-open the skill menu in game (or unequip and "
                    "re-equip the weapon) to see the change.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def undo_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_undo(client, tgt))

    def _do_undo(self, client, tgt):
        try:
            res = client.send("exskill_undo", tgt, timeout=30)

            def _ui():
                self.app.set_status(f"Undone: {res}")
                self.note_var.set("")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def refresh_skills(self):
        pass  # nothing target-specific to reload here
