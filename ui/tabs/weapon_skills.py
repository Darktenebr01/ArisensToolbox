"""Weapon Skills tab: 6 equipped slots per vocation + unlock/state/level/probes."""
import re
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    run_async, require_client, show_probe, JOB_LABELS,
    Card, card_content, H1, Muted,
    PrimaryButton, GhostButton, Combo, Check, StyledListbox,
)


def _custom_owner(enum_data):
    """skill id -> job (1-10), built from jobsCustom like the CE table."""
    owner = {}
    for j, t in enumerate(enum_data.get("jobsCustom", []), start=1):
        for sid in t.get("ids", [])[1:]:  # skip "(none)" entry
            owner[sid] = j
    return owner


class WeaponSkillsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self._busy = False
        self.cur_skills = [0] * 6
        self.src_vars = []
        self.skill_combos = []
        self.skill_ids = [[] for _ in range(6)]  # parallel id lists per slot
        self.w_rows = []      # skill ids in the state list
        self.w_info = {}      # id -> probe info string
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(3, weight=1)
        app.register_refreshable(self)

        H1(self, "Weapon Skills", row=0, column=0, sticky="w", pady=(0, 8))

        # options card: auto-unlock + unlock level
        opt_card = Card(self, row=1, column=0, sticky="ew", padx=4, pady=6)
        opt = card_content(opt_card)
        self.auto_var = ctk.BooleanVar(value=True)
        Check(opt, "Auto-unlock a skill when equipping it",
              variable=self.auto_var).grid(row=0, column=0, sticky="w")
        ctk.CTkLabel(opt, text="Unlock level:", text_color=T.TEXT).grid(
            row=0, column=1, sticky="w", padx=(24, 4))
        self.lvl_var = ctk.StringVar(value="")
        self.lvl_combo = Combo(opt, variable=self.lvl_var, values=[], width=170)
        self.lvl_combo.grid(row=0, column=2, sticky="w")
        self._fill_level_combo()

        # slots card: 6 slots
        slot_card = Card(self, row=2, column=0, sticky="ew", padx=4, pady=6)
        slots = card_content(slot_card)
        for slot in range(6):
            r = ctk.CTkFrame(slots, fg_color="transparent")
            r.pack(fill="x", pady=2)
            ctk.CTkLabel(r, text=f"Slot {slot + 1}", width=55,
                         text_color=T.TEXT).pack(side="left")
            src_var = ctk.StringVar(value=JOB_LABELS[0])
            src = Combo(r, variable=src_var, values=JOB_LABELS, width=170,
                        command=lambda _v, s=slot: self._on_src(s))
            src.pack(side="left", padx=4)
            self.src_vars.append(src_var)
            kc = Combo(r, values=["(none)"], width=420,
                       command=lambda _v, s=slot: self._on_skill(s))
            kc.set("(none)")
            kc.pack(side="left", padx=4)
            self.skill_combos.append(kc)
        brow = ctk.CTkFrame(slots, fg_color="transparent")
        brow.pack(fill="x", pady=(8, 0))
        PrimaryButton(brow, "Refresh", command=self.refresh_async,
                      width=90).pack(side="left")
        GhostButton(brow, "Clear all 6 slots", command=self.clear_async,
                    width=140).pack(side="left", padx=8)

        # unlock card: state list + buttons
        unl_card = Card(self, row=3, column=0, sticky="nsew", padx=4, pady=6)
        unl = card_content(unl_card)
        unl.grid_columnconfigure(0, weight=1)
        unl.grid_rowconfigure(1, weight=1)
        Muted(unl, "Unlock weapon skills / set level (uses the Unlock level box above).",
              row=0, column=0, columnspan=3, sticky="w", pady=(0, 6))
        self.wlist = StyledListbox(unl)
        self.wlist.grid(row=1, column=0, sticky="nsew")
        sb = tk.Scrollbar(unl, orient="vertical", command=self.wlist.yview)
        sb.grid(row=1, column=1, sticky="ns")
        self.wlist.config(yscrollcommand=sb.set)

        bcol = ctk.CTkFrame(unl, fg_color="transparent")
        bcol.grid(row=1, column=2, sticky="ns", padx=(8, 0))
        PrimaryButton(bcol, "Unlock selected", width=200,
                      command=self.unlock_selected_async).pack(pady=3)
        GhostButton(bcol, "Unlock ALL (this vocation)", width=200,
                    command=lambda: self.unlock_all_async(0)).pack(pady=3)
        GhostButton(bcol, "Unlock EVERY vocation", width=200,
                    command=lambda: self.unlock_all_async(-1)).pack(pady=3)
        GhostButton(bcol, "Probe levels / upgrades", width=200,
                    command=self.probe_async).pack(pady=3)
        GhostButton(bcol, "Add missing entry", width=200,
                    command=self.add_entry_async).pack(pady=3)
        GhostButton(bcol, "Set level of selected", width=200,
                    command=self.set_level_async).pack(pady=3)
        ctk.CTkLabel(bcol, **T.muted("Uses the 'Unlock level' box above.")).pack(pady=(6, 2))
        GhostButton(bcol, "Probe equipment abilities", width=200,
                    command=lambda: self.eq_probe_async("eqability_probe", "eqability.txt",
                                                        "Equipment ability probe")).pack(pady=3)
        GhostButton(bcol, "Probe abilities (part 2)", width=200,
                    command=lambda: self.eq_probe_async("eqability_probe2", "eqability2.txt",
                                                        "Equipment ability probe 2")).pack(pady=3)

    # -- enum helpers -------------------------------------------------

    def _fill_level_combo(self):
        E = self.app.enum_data or {}
        labels = E.get("levelLabels") or ["0", "1", "2"]
        self._level_values = E.get("levelValues") or [0, 1, 2]
        self.lvl_combo.configure(values=labels)
        if labels and not self.lvl_var.get():
            self.lvl_var.set(labels[0])

    def _unlock_level(self):
        try:
            return self._level_values[self.lvl_combo.cget("values").index(self.lvl_var.get())]
        except (ValueError, AttributeError, IndexError):
            return 1

    def _enums(self):
        E = self.app.enum_data or {}
        if not E.get("jobsCustom"):
            self.app.set_status("Click Connect first (Connection tab).")
            return None
        return E

    # -- slot combos --------------------------------------------------

    def _fill_skill_combo(self, slot, src_job, cur):
        E = self._enums()
        if not E:
            return
        SJ = E["jobsCustom"][src_job - 1]
        self._busy = True
        try:
            self.skill_ids[slot] = list(SJ["ids"])
            self.skill_combos[slot].configure(values=list(SJ["labels"]))
            idx = SJ["ids"].index(cur) if cur in SJ["ids"] else 0
            self.skill_combos[slot].set(SJ["labels"][idx])
        finally:
            self._busy = False

    def _on_src(self, slot):
        if self._busy:
            return
        E = self._enums()
        if not E:
            return
        try:
            src_job = JOB_LABELS.index(self.src_vars[slot].get()) + 1
        except ValueError:
            return
        self._fill_skill_combo(slot, src_job, self.cur_skills[slot])

    def _on_skill(self, slot):
        if self._busy:
            return
        E = self._enums()
        if not E:
            return
        client = require_client(self.app)
        if not client:
            return
        try:
            src_job = JOB_LABELS.index(self.src_vars[slot].get()) + 1
        except ValueError:
            return
        SJ = E["jobsCustom"][src_job - 1]
        try:
            idx = list(SJ["labels"]).index(self.skill_combos[slot].get())
        except ValueError:
            return
        sid = SJ["ids"][idx]
        label = SJ["labels"][idx]
        lvl = self._unlock_level() if self.auto_var.get() else -1
        tgt, job = self.app.target(), self.app.job()
        self.app.set_status(f"Setting slot {slot + 1}...")
        run_async(self, lambda: self._do_set(client, tgt, job, slot, sid, lvl, label))

    def _do_set(self, client, tgt, job, slot, sid, lvl, label):
        try:
            client.send("set_wskill", tgt, job, slot, sid, lvl, timeout=15)
            self.after(0, lambda: self.app.set_status(f"Slot {slot + 1} -> {label}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self.refresh_async(quiet=True)

    # -- refresh ------------------------------------------------------

    def refresh_async(self, quiet=False):
        E = self._enums()
        if not E:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_refresh(client, tgt, job, E, quiet))

    def _do_refresh(self, client, tgt, job, E, quiet):
        try:
            res = client.send("get_wskills", tgt, job, timeout=15)
            ids = [int(x) if x.strip().lstrip("-").isdigit() else 0
                   for x in res.split(",")]
            owner = _custom_owner(E)
            self.after(0, lambda: self._apply_wskills(ids, owner, job, quiet))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self._do_wstate(client, tgt, job, E)

    def _apply_wskills(self, ids, owner, job, quiet):
        self._busy = True
        try:
            for slot in range(6):
                cur = ids[slot] if slot < len(ids) else 0
                self.cur_skills[slot] = cur
                src_job = owner.get(cur, job)
                self.src_vars[slot].set(JOB_LABELS[src_job - 1])
                SJ = (self.app.enum_data or {}).get("jobsCustom", [])[src_job - 1]
                self.skill_ids[slot] = list(SJ["ids"])
                self.skill_combos[slot].configure(values=list(SJ["labels"]))
                idx = SJ["ids"].index(cur) if cur in SJ["ids"] else 0
                self.skill_combos[slot].set(SJ["labels"][idx])
        finally:
            self._busy = False
        if not quiet:
            self.app.set_status(f"Weapon skills read for {JOB_LABELS[job - 1]}")

    def _do_wstate(self, client, tgt, job, E):
        try:
            res = client.send("get_wstate", tgt, job, timeout=30)
            rows = []
            for row in res.split(";"):
                m = re.match(r"^(-?\d+),([^,]*),(.*)$", row)
                if m:
                    rows.append((int(m.group(1)), m.group(2), m.group(3)))
            custom_name = E.get("customName", {})
            self.after(0, lambda: self._apply_wstate(rows, custom_name))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _apply_wstate(self, rows, custom_name):
        self.wlist.delete(0, tk.END)
        self.w_rows = []
        for sid, en, lv in rows:
            self.w_rows.append(sid)
            name = custom_name.get(sid, str(sid))
            extra = f"   | {self.w_info[sid]}" if sid in self.w_info else ""
            self.wlist.insert(tk.END, f"{name}    enabled={en}  level={lv}{extra}")

    def refresh_skills(self):
        self._fill_level_combo()
        self.refresh_async(quiet=True)

    # -- buttons ------------------------------------------------------

    def clear_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        run_async(self, lambda: self._do_simple(
            client, "clear_wskills", (tgt, job), "Slots cleared.",
            lambda: self.refresh_async(quiet=True)))

    def _do_simple(self, client, cmd, args, ok_msg, after=None):
        """Send cmd; show ok_msg (or raw result); then run after() if given."""
        try:
            res = client.send(cmd, *args, timeout=20)
            msg = ok_msg if ok_msg else res
            self.after(0, lambda: self.app.set_status(msg))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        if after:
            after()

    def _selected_id(self):
        sel = self.wlist.curselection()
        if sel and sel[0] < len(self.w_rows):
            return self.w_rows[sel[0]]
        self.app.set_status("Select a skill in the list first.")
        return None

    def unlock_selected_async(self):
        sid = self._selected_id()
        if sid is None:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, lvl = self.app.target(), self._unlock_level()
        run_async(self, lambda: self._do_simple(
            client, "unlock_wskill", (tgt, sid, lvl), "Unlocked.",
            lambda: self._do_wstate(client, tgt, self.app.job(),
                                    self.app.enum_data or {})))

    def unlock_all_async(self, which):
        """which=0 -> this vocation (job), which=-1 -> EVERY vocation (job 0)."""
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job() if which == 0 else 0
        lvl = self._unlock_level()
        run_async(self, lambda: self._do_simple(
            client, "unlock_wskills", (tgt, job, lvl), None,
            lambda: self._do_wstate(client, tgt, self.app.job(),
                                    self.app.enum_data or {})))

    def set_level_async(self):
        sid = self._selected_id()
        if sid is None:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, lvl = self.app.target(), self._unlock_level()
        run_async(self, lambda: self._do_simple(
            client, "set_wlevel", (tgt, sid, lvl), None,
            lambda: (self._do_wstate(client, tgt, self.app.job(),
                                     self.app.enum_data or {}),
                     self.refresh_async(quiet=True))))

    def probe_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        self.app.set_status("Probing weapon skills (calls every read-only skill getter)...")
        run_async(self, lambda: self._do_probe(client, tgt, job))

    def _do_probe(self, client, tgt, job):
        try:
            res = client.send("wskill_probe", tgt, job, timeout=120)
            text = client.read_sidecar("wskill_info.txt") or ""
            info = {}
            for line in text.splitlines():
                parts = line.split("\t", 2)
                if len(parts) == 3 and parts[0].lstrip("-").isdigit() and parts[2]:
                    info[int(parts[0])] = parts[2]
            self.w_info = info
            self.after(0, lambda: (
                show_probe(self, "Weapon skill probe", text or "(wskill_info.txt missing)"),
                self.app.set_status(f"Probe: {res}"),
            ))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self._do_wstate(client, tgt, job, self.app.enum_data or {})

    def add_entry_async(self):
        sid = self._selected_id()
        if sid is None:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, lvl = self.app.target(), self._unlock_level()
        self.app.set_status(f"Adding missing EnabledCustomSkills entry for skill {sid} at level {lvl}...")
        run_async(self, lambda: self._do_add_entry(client, tgt, sid, lvl))

    def _do_add_entry(self, client, tgt, sid, lvl):
        try:
            res = client.send("wskill_add_entry", tgt, sid, lvl, timeout=60)
            self.after(0, lambda: self.app.set_status(res))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self._do_wstate(client, tgt, self.app.job(), self.app.enum_data or {})

    def eq_probe_async(self, cmd, filename, title):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        self.app.set_status("Probing (equip the weapon with the upgraded skills first)...")
        run_async(self, lambda: self._do_eq_probe(client, cmd, filename, title, tgt, job))

    def _do_eq_probe(self, client, cmd, filename, title, tgt, job):
        try:
            res = client.send(cmd, tgt, job, timeout=120)
            text = client.read_sidecar(filename) or f"({filename} missing)"
            n = len(text.splitlines())
            self.after(0, lambda: (
                show_probe(self, title, text),
                self.app.set_status(f"Probe done: {res} ({n} lines)."),
            ))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
