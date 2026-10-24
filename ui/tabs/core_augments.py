"""Core Skills & Augments: learn/unlearn passive skills, six augment slots."""
import re

import customtkinter as ctk

from ui.base import BaseTab
from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ListPanel, Combo, Check, PrimaryButton,
    GhostButton, QuietButton, caption, dev_only, run_async, require_client,
    show_probe,
)


class CoreAugmentsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self._busy = False
        self.n_rows = []   # normal skill ids in the list
        self.n_state = {}  # id -> learned (True/False)
        self.aug_combos = []
        self.grid_columnconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=0)
        self.grid_rowconfigure(1, weight=1)
        app.register_refreshable(self)

        header = PageHeader(
            self, "Core Skills & Augments",
            "Learn or unlearn passive core skills and fill the six augment "
            "slots of the selected vocation.")
        header.grid(row=0, column=0, columnspan=2, sticky="ew",
                    pady=(0, T.PAD_L))
        header.action(GhostButton(header.actions, "Refresh", width=92,
                                  command=self.refresh_async))

        # -- left: core skills ---------------------------------------
        core = Section(self, "Core skills", **{"row": 1, "column": 0,
                                              "sticky": "nsew",
                                              "padx": (0, T.PAD_M)})
        body = core.body
        body.grid_rowconfigure(0, weight=1)
        self.panel = ListPanel(body, height=12,
                               empty="Refresh to read the core skills.")
        self.panel.grid(row=0, column=0, sticky="nsew")
        self.nlist = self.panel.listbox

        row = Row(body)
        row.grid(row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        row.add(PrimaryButton(row, "Learn selected", width=126,
                              command=self.enable_selected_async))
        row.add(GhostButton(row, "Learn all (vocation)", width=150,
                            command=self.enable_all_async))
        dev_only(self, lambda: QuietButton(row, "Dump", width=72,
                                          command=self.core_dump_async).pack(
            side="left"))

        row2 = Row(body)
        row2.grid(row=2, column=0, sticky="ew", pady=(T.PAD_S, 0))
        row2.add(GhostButton(row2, "Unlearn selected", width=134,
                             command=self.unlearn_selected_async))
        row2.add(GhostButton(row2, "Unlearn all (vocation)", width=164,
                             command=self.unlearn_all_async))

        row3 = Row(body)
        row3.grid(row=3, column=0, sticky="ew", pady=(T.PAD_S, 0))
        self.incl_other_var = ctk.BooleanVar(value=False)
        Check(row3, text="Include skills without a vocation prefix "
                         "([other]) in the bulk actions",
              variable=self.incl_other_var).pack(side="left")

        caption(body, "Unlearning writes to your save and can be undone with "
                      "Ctrl+Z.",
                row=4, column=0, sticky="ew", pady=(T.PAD_S, 0))

        # -- right: augments -----------------------------------------
        aug = Section(self, "Augments", **{"row": 1, "column": 1,
                                          "sticky": "nsew"})
        body = aug.body
        for slot in range(6):
            line = ctk.CTkFrame(body, fg_color="transparent", width=1, height=1)
            line.grid(row=slot, column=0, sticky="ew", pady=T.PAD_XS)
            line.grid_columnconfigure(1, weight=1)
            ctk.CTkLabel(line, text=f"Slot {slot + 1}",
                         font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                         width=50, anchor="w").grid(row=0, column=0,
                                                    sticky="w")
            cb = Combo(line, values=["(none)"], width=260,
                       command=lambda _v, s=slot: self._on_augment(s))
            cb.set("(none)")
            cb.grid(row=0, column=1, sticky="ew")
            self.aug_combos.append(cb)
        PrimaryButton(body, "Unlock all augments", width=300,
                      command=self.unlock_augments_async).grid(
            row=6, column=0, sticky="ew", pady=(T.PAD_M, T.PAD_XS))
        dev_only(self, lambda: QuietButton(body, "Dump augment data",
                                          width=180,
                                          command=self.augment_dump_async).grid(
            row=7, column=0, sticky="ew", pady=T.PAD_XS))
        caption(body, "Augments without a JobNN_ prefix appear as [other] "
                      "in every vocation.",
                row=8, column=0, sticky="ew", pady=(T.PAD_S, 0))

    # -- core skills --------------------------------------------------

    def _enums(self):
        E = self.app.enum_data or {}
        if not E.get("jobsNormal") or not E.get("jobsAbility"):
            self.app.set_status("Connect first - the skill tables load with "
                                "the session.")
            return None
        return E

    def refresh_async(self):
        E = self._enums()
        if not E:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_core(client, tgt, job, E))
        run_async(self, lambda: self._do_augments(client, tgt, job, E))

    def refresh_skills(self):
        self.refresh_async()

    def _do_core(self, client, tgt, job, E):
        try:
            res = client.send("get_nstate", tgt, job, timeout=30)
            rows = []
            for row in res.split(";"):
                m = re.match(r"^(-?\d+),([^,]*),?(.*)$", row)
                if m:
                    rows.append((int(m.group(1)), m.group(2), m.group(3)))
            normal_name = E.get("normalName", {})
            self.after(0, lambda: self._apply_core(rows, normal_name))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _apply_core(self, rows, normal_name):
        self.n_rows = []
        self.n_state = {}
        labels = []
        for sid, en, tag in rows:
            learned = (en == "true")
            self.n_rows.append(sid)
            self.n_state[sid] = learned
            name = normal_name.get(sid, str(sid))
            extra = "   · no vocation prefix" if tag == "other" else ""
            state = "learned" if learned else "not learned"
            labels.append(f"{name}    {state}{extra}")
        self.panel.set_rows(labels)
        self.panel.set_empty("No core skills reported for this vocation.")

    def _selected_id(self):
        sel = self.nlist.curselection()
        if sel and sel[0] < len(self.n_rows):
            return self.n_rows[sel[0]]
        self.app.set_status("Select a core skill first.")
        return None

    def enable_selected_async(self):
        sid = self._selected_id()
        if sid is None:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_enable_one(client, tgt, sid))

    def _do_enable_one(self, client, tgt, sid):
        try:
            res = client.send("enable_nskill", tgt, sid, timeout=15)
            self.after(0, lambda: (self.app.set_status(f"Learned: {res}"),
                                   self.refresh_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def enable_all_async(self):
        client = require_client(self.app)
        if not client:
            return
        incl_other = self.incl_other_var.get()
        if not self.app.confirm_bulk(
                "Learn all core skills",
                "This writes to your save: all core skills for the "
                "selected vocation will be learned."):
            return
        tgt, job = self.app.target(), self.app.job()
        args = (tgt, job, "all") if incl_other else (tgt, job)
        run_async(self, lambda: self._do_enable_all(client, args))

    def _do_enable_all(self, client, args):
        try:
            res = client.send("enable_nskills", *args, timeout=60)
            self.after(0, lambda: (self.app.set_status(f"Learned {res}"),
                                   self.refresh_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- unlearn -------------------------------------------------------

    @staticmethod
    def _unlearn_msg(res):
        if res.lower().startswith(("already", "nothing")):
            return res
        return f"Unlearned: {res}"

    def unlearn_selected_async(self):
        sid = self._selected_id()
        if sid is None:
            return
        if not self.n_state.get(sid):
            self.app.set_status("That core skill is already unlearned.")
            return
        client = require_client(self.app)
        if not client:
            return
        tgt = self.app.target()
        run_async(self, lambda: self._do_unlearn(client, tgt, sid))

    def _do_unlearn(self, client, tgt, sid):
        try:
            res = client.send("disable_nskill", tgt, sid, timeout=20)
            if not res.lower().startswith(("already", "nothing")):
                self.app.record_undo(
                    f"core skill {sid}",
                    lambda c, t=tgt, s=sid: c.send("enable_nskill", t, s,
                                                   timeout=20))
            self.after(0, lambda: (self.app.set_status(self._unlearn_msg(res)),
                                   self.refresh_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Unlearn failed: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def unlearn_all_async(self):
        client = require_client(self.app)
        if not client:
            return
        enabled = [sid for sid in self.n_rows if self.n_state.get(sid)]
        if not enabled:
            self.app.set_status("No learned core skills in this list.")
            return
        incl_other = self.incl_other_var.get()
        job = self.app.job()
        scope = "every core skill" if incl_other else \
            f"core skills for vocation {job:02d}"
        if not self.app.confirm_bulk(
                "Unlearn core skills",
                f"This writes to your save: {scope} in this list will be "
                f"unlearned ({len(enabled)} skill(s)). Ctrl+Z can relearn "
                "them."):
            return
        tgt = self.app.target()
        args = (tgt, job, "all") if incl_other else (tgt, job)
        run_async(self, lambda: self._do_unlearn_all(client, tgt, args,
                                                     enabled))

    def _do_unlearn_all(self, client, tgt, args, enabled):
        try:
            res = client.send("disable_nskills", *args, timeout=60)
            if enabled and not res.lower().startswith("nothing"):
                def _undo(c, ids=tuple(enabled), t=tgt):
                    for sid in ids:
                        c.send("enable_nskill", t, sid, timeout=20)
                    return f"relearned {len(ids)} core skill(s)"
                self.app.record_undo("unlearn core skills", _undo)
            self.after(0, lambda: (self.app.set_status(self._unlearn_msg(res)),
                                   self.refresh_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Unlearn failed: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def core_dump_async(self):
        self._dump_async("core_dump", "coredump.txt", "Core skill dump")

    def augment_dump_async(self):
        self._dump_async("augment_dump", "augdump.txt", "Augment dump")

    def _dump_async(self, cmd, filename, title):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_dump(client, cmd, filename, title,
                                              tgt, job))

    def _do_dump(self, client, cmd, filename, title, tgt, job):
        try:
            client.send(cmd, tgt, job, timeout=60)
            text = client.read_sidecar(filename) or f"({filename} missing)"
            self.after(0, lambda: show_probe(self, title, text))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- augments -----------------------------------------------------

    def _on_augment(self, slot):
        if self._busy:
            return
        E = self._enums()
        if not E:
            return
        client = require_client(self.app)
        if not client:
            return
        job = self.app.job()
        A = E["jobsAbility"][job - 1]
        try:
            idx = list(A["labels"]).index(self.aug_combos[slot].get())
        except ValueError:
            return
        sid, label = A["ids"][idx], A["labels"][idx]
        tgt = self.app.target()
        self.app.set_status(f"Setting augment {slot + 1}...")
        run_async(self, lambda: self._do_set_augment(client, tgt, job, slot,
                                                     sid, label))

    def _do_set_augment(self, client, tgt, job, slot, sid, label):
        try:
            # wire order: target, job, slot, id (lua reorders for the game call)
            client.send("set_augment", tgt, job, slot, sid, timeout=15)
            self.after(0, lambda: self.app.set_status(
                f"Augment {slot + 1} → {label}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self.after(0, self.refresh_async)

    def _do_augments(self, client, tgt, job, E):
        try:
            res = client.send("get_augments", tgt, job, timeout=15)
            ids = [int(x) if x.strip().lstrip("-").isdigit() else 0
                   for x in res.split(",")]
            A = E["jobsAbility"][job - 1]
            self.after(0, lambda: self._apply_augments(ids, A))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Augments: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _apply_augments(self, ids, A):
        self._busy = True
        try:
            for slot in range(6):
                cur = ids[slot] if slot < len(ids) else 0
                self.aug_combos[slot].configure(values=list(A["labels"]))
                idx = A["ids"].index(cur) if cur in A["ids"] else 0
                self.aug_combos[slot].set(A["labels"][idx])
        finally:
            self._busy = False

    def unlock_augments_async(self):
        client = require_client(self.app)
        if not client:
            return
        if not self.app.confirm_bulk(
                "Unlock all augments",
                "This writes to your save: all augments for the selected "
                "vocation will be unlocked."):
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_unlock_augments(client, tgt, job))

    def _do_unlock_augments(self, client, tgt, job):
        try:
            res = client.send("unlock_augments", tgt, job, "all", timeout=60)
            self.after(0, lambda: self.app.set_status(f"Unlocked {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self.after(0, self.refresh_async)
