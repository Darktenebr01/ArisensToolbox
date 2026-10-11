"""Core Skills & Augments tab: enable core (passive) skills, 6 augment slots."""
import re
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.widgets import (
    run_async, require_client, show_probe,
    Card, card_content, H1, Muted,
    PrimaryButton, GhostButton, Combo, StyledListbox,
)


class CoreAugmentsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self._busy = False
        self.n_rows = []  # normal skill ids in the list
        self.aug_combos = []
        self.grid_columnconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=0)
        self.grid_rowconfigure(1, weight=1)
        app.register_refreshable(self)

        H1(self, "Core Skills & Augments", row=0, column=0, columnspan=2,
           sticky="w", pady=(0, 8))

        # ---- left: core skills ----
        core_card = Card(self, row=1, column=0, sticky="nsew", padx=4, pady=6)
        core = card_content(core_card)
        core.grid_columnconfigure(0, weight=1)
        core.grid_rowconfigure(0, weight=1)
        self.nlist = StyledListbox(core)
        self.nlist.grid(row=0, column=0, sticky="nsew")
        sb = tk.Scrollbar(core, orient="vertical", command=self.nlist.yview)
        sb.grid(row=0, column=1, sticky="ns")
        self.nlist.config(yscrollcommand=sb.set)

        nbtn = ctk.CTkFrame(core, fg_color="transparent")
        nbtn.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(8, 0))
        GhostButton(nbtn, "Refresh", command=self.refresh_async,
                    width=90).pack(side="left")
        PrimaryButton(nbtn, "Enable selected", command=self.enable_selected_async,
                      width=130).pack(side="left", padx=6)
        GhostButton(nbtn, "Enable ALL (vocation)",
                    command=lambda: self.enable_all_async(False),
                    width=160).pack(side="left", padx=6)
        nbtn2 = ctk.CTkFrame(core, fg_color="transparent")
        nbtn2.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(4, 0))
        GhostButton(nbtn2, "Enable ALL incl. unprefixed",
                    command=lambda: self.enable_all_async(True),
                    width=200).pack(side="left")
        GhostButton(nbtn2, "DUMP core skill data", command=self.core_dump_async,
                    width=170).pack(side="left", padx=6)

        # ---- right: augments ----
        aug_card = Card(self, row=1, column=1, sticky="nsew", padx=4, pady=6)
        aug = card_content(aug_card)
        for slot in range(6):
            cb = Combo(aug, values=["(none)"], width=300,
                       command=lambda _v, s=slot: self._on_augment(s))
            cb.set("(none)")
            cb.grid(row=slot, column=0, sticky="w", pady=3)
            self.aug_combos.append(cb)
        PrimaryButton(aug, "Unlock ALL augments (vocation + other)",
                      command=self.unlock_augments_async,
                      width=300).grid(row=6, column=0, sticky="w", pady=(8, 3))
        GhostButton(aug, "DUMP augment data", command=self.augment_dump_async,
                    width=200).grid(row=7, column=0, sticky="w", pady=3)
        Muted(aug, "Augments with no JobNN_ prefix are listed\nas [other] in every dropdown.",
              row=8, column=0, sticky="w", pady=6)

    # -- core skills --------------------------------------------------

    def _enums(self):
        E = self.app.enum_data or {}
        if not E.get("jobsNormal") or not E.get("jobsAbility"):
            self.app.set_status("Click Connect first (Connection tab).")
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
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

    def _apply_core(self, rows, normal_name):
        self.nlist.delete(0, tk.END)
        self.n_rows = []
        for sid, en, tag in rows:
            self.n_rows.append(sid)
            name = normal_name.get(sid, str(sid))
            extra = "   [no vocation prefix]" if tag == "other" else ""
            self.nlist.insert(tk.END, f"{name}    enabled={en}{extra}")

    def enable_selected_async(self):
        sel = self.nlist.curselection()
        if not sel or sel[0] >= len(self.n_rows):
            self.app.set_status("Select a skill first.")
            return
        client = require_client(self.app)
        if not client:
            return
        sid, tgt = self.n_rows[sel[0]], self.app.target()
        run_async(self, lambda: self._do_enable_one(client, tgt, sid))

    def _do_enable_one(self, client, tgt, sid):
        try:
            client.send("enable_nskill", tgt, sid, timeout=15)
            self.after(0, lambda: self.app.set_status("Enabled."))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
        self.refresh_async()

    def enable_all_async(self, incl_other):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        args = (tgt, job, "all") if incl_other else (tgt, job)
        run_async(self, lambda: self._do_enable_all(client, args))

    def _do_enable_all(self, client, args):
        try:
            res = client.send("enable_nskills", *args, timeout=60)
            self.after(0, lambda: self.app.set_status(f"Enabled {res}"))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
        self.refresh_async()

    def core_dump_async(self):
        self._dump_async("core_dump", "coredump.txt", "Core skill dump - copy all of it")

    def augment_dump_async(self):
        self._dump_async("augment_dump", "augdump.txt", "Augment dump - copy all of it")

    def _dump_async(self, cmd, filename, title):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_dump(client, cmd, filename, title, tgt, job))

    def _do_dump(self, client, cmd, filename, title, tgt, job):
        try:
            client.send(cmd, tgt, job, timeout=60)
            text = client.read_sidecar(filename) or f"({filename} missing)"
            self.after(0, lambda: show_probe(self, title, text))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))

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
        run_async(self, lambda: self._do_set_augment(client, tgt, job, slot, sid, label))

    def _do_set_augment(self, client, tgt, job, slot, sid, label):
        try:
            # wire order: target, job, slot, id (lua reorders for the game call)
            client.send("set_augment", tgt, job, slot, sid, timeout=15)
            self.after(0, lambda: self.app.set_status(f"Augment {slot + 1} -> {label}"))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
        self.refresh_async()

    def _do_augments(self, client, tgt, job, E):
        try:
            res = client.send("get_augments", tgt, job, timeout=15)
            ids = [int(x) if x.strip().lstrip("-").isdigit() else 0
                   for x in res.split(",")]
            A = E["jobsAbility"][job - 1]
            self.after(0, lambda: self._apply_augments(ids, A))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Augments: {e}"))

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
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_unlock_augments(client, tgt, job))

    def _do_unlock_augments(self, client, tgt, job):
        try:
            res = client.send("unlock_augments", tgt, job, "all", timeout=60)
            self.after(0, lambda: self.app.set_status(f"Unlocked {res}"))
        except (BridgeError, BridgeTimeout) as e:
            self.after(0, lambda: self.app.set_status(f"Error: {e}"))
        self.refresh_async()
