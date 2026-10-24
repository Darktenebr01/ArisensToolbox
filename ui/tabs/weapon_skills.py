"""Weapon Skills: six equipped slots per vocation, unlock state and levels."""
import re

import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ScrollArea, ListPanel, Frame, Combo, Switch,
    PrimaryButton, GhostButton, QuietButton, caption, dev_only, run_async,
    require_client, show_probe, JOB_LABELS,
)


def _custom_owner(enum_data):
    """skill id -> job (1-10), built from jobsCustom like the CE table."""
    owner = {}
    for j, t in enumerate(enum_data.get("jobsCustom", []), start=1):
        for sid in t.get("ids", [])[1:]:  # skip "(none)" entry
            owner[sid] = j
    return owner


class WeaponSkillsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self._busy = False
        self.cur_skills = [0] * 6
        self.src_vars = []
        self.skill_combos = []
        self.skill_ids = [[] for _ in range(6)]
        self.w_rows = []      # skill ids in the state list
        self.w_info = {}      # id -> probe info string
        self.w_state = {}
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)
        app.register_refreshable(self)

        header = PageHeader(
            self, "Weapon Skills",
            "Equip, learn or unlearn weapon skills, and set their level for "
            "the selected target and vocation.")
        header.grid(row=0, column=0, sticky="ew", pady=(0, T.PAD_L))
        header.action(GhostButton(header.actions, "Refresh", width=92,
                                  command=self.refresh_async))

        self.scroll = ScrollArea(self)
        self.scroll.grid(row=1, column=0, sticky="nsew")

        options = Section(self.scroll, "Learn options", **{
            "row": 0, "column": 0, "sticky": "ew", "pady": (0, T.PAD_M)})
        body = options.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="ew")
        self.auto_var = ctk.BooleanVar(value=True)
        Switch(row, text="Learn a skill when equipping it",
               variable=self.auto_var).pack(side="left")
        ctk.CTkLabel(row, text="Learn level",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_XL, T.PAD_S))
        self.lvl_var = ctk.StringVar(value="")
        self.lvl_combo = Combo(row, variable=self.lvl_var, values=[], width=170)
        self.lvl_combo.pack(side="left")
        self._fill_level_combo()

        slots = Section(self.scroll, "Equipped slots",
                        hint="The source column lists every vocation's "
                             "skills, so cross-vocation sets stay possible.",
                        **{"row": 1, "column": 0, "sticky": "ew",
                           "pady": (0, T.PAD_M)})
        body = slots.body
        body.grid_columnconfigure(0, weight=1)
        body.grid_columnconfigure(1, weight=1)
        for slot in range(6):
            cell = Frame(body)
            cell.grid(row=slot % 3, column=slot // 3, sticky="ew",
                      padx=(0, T.PAD_M) if slot // 3 == 0 else (0, 0),
                      pady=2)
            cell.grid_columnconfigure(2, weight=1)
            ctk.CTkLabel(cell, text=f"Slot {slot + 1}",
                         font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                         width=44, anchor="w").grid(row=0, column=0,
                                                    sticky="w")
            src_var = ctk.StringVar(value=JOB_LABELS[0])
            src = Combo(cell, variable=src_var, values=JOB_LABELS, width=126,
                        command=lambda _v, s=slot: self._on_src(s))
            src.grid(row=0, column=1, sticky="w", padx=(T.PAD_XS, T.PAD_XS))
            self.src_vars.append(src_var)
            kc = Combo(cell, values=["(none)"],
                       command=lambda _v, s=slot: self._on_skill(s))
            kc.set("(none)")
            kc.grid(row=0, column=2, sticky="ew")
            self.skill_combos.append(kc)
        row = Row(body)
        row.grid(row=3, column=0, columnspan=2, sticky="w",
                 pady=(T.PAD_S, 0))
        row.add(QuietButton(row, "Clear all 6 slots", width=140,
                            command=self.clear_async))

        unlock = Section(self.scroll, "Skill states",
                         hint="Equipped skills are never unlearned; clear "
                              "their slot first.",
                         **{"row": 2, "column": 0, "sticky": "ew"})
        body = unlock.body
        body.grid_rowconfigure(2, weight=1)

        bar1 = Row(body)
        bar1.grid(row=0, column=0, sticky="ew")
        bar1.add(PrimaryButton(bar1, "Learn selected", width=160,
                               command=self.unlock_selected_async))
        bar1.add(GhostButton(bar1, "Learn all (vocation)", width=160,
                             command=lambda: self.unlock_all_async(0)))
        bar1.add(GhostButton(bar1, "Learn every vocation", width=160,
                             command=lambda: self.unlock_all_async(-1)))
        bar1.add(GhostButton(bar1, "Unlearn selected", width=160,
                             command=self.unlearn_selected_async))

        bar2 = Row(body)
        bar2.grid(row=1, column=0, sticky="ew", pady=(T.PAD_XS, T.PAD_S))
        bar2.add(GhostButton(bar2, "Unlearn all (vocation)", width=160,
                             command=self.unlearn_all_async))
        bar2.add(QuietButton(bar2, "Set level of selected", width=160,
                             command=self.set_level_async))
        bar2.add(QuietButton(bar2, "Add missing entry", width=160,
                             command=self.add_entry_async))
        dev_only(self, lambda: QuietButton(
            bar2, "Probe levels", width=120,
            command=self.probe_async).pack(side="left"))

        self.panel = ListPanel(body, height=7,
                               empty="Refresh to read the skill states.")
        self.panel.grid(row=2, column=0, sticky="nsew")
        self.wlist = self.panel.listbox
        caption(body, "Level uses the Learn level box above. Unlearning is "
                      "undone with Ctrl+Z.",
                row=3, column=0, sticky="ew", pady=(T.PAD_S, 0))

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
            return self._level_values[
                list(self.lvl_combo.cget("values")).index(self.lvl_var.get())]
        except (ValueError, AttributeError, IndexError):
            return 1

    def _enums(self):
        E = self.app.enum_data or {}
        if not E.get("jobsCustom"):
            self.app.set_status("Connect first - the skill tables load with "
                                "the session.")
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
        run_async(self, lambda: self._do_set(client, tgt, job, slot, sid, lvl,
                                             label))

    def _do_set(self, client, tgt, job, slot, sid, lvl, label):
        try:
            client.send("set_wskill", tgt, job, slot, sid, lvl, timeout=15)
            self.after(0, lambda: self.app.set_status(
                f"Slot {slot + 1} → {label}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self.after(0, lambda: self.refresh_async(quiet=True))

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
        labels = []
        self.w_rows = []
        self.w_state = {}
        for sid, en, lv in rows:
            self.w_state[sid] = (en, lv)
            self.w_rows.append(sid)
            name = custom_name.get(sid, str(sid))
            state = "learned" if str(en).lower() in ("true", "1") \
                else "not learned"
            extra = f"   · {self.w_info[sid]}" if sid in self.w_info else ""
            labels.append(f"{name}    {state}  ·  level {lv}{extra}")
        self.panel.set_rows(labels)
        self.panel.set_empty("No skill states reported for this vocation.")

    def _is_learned(self, sid):
        state = self.w_state.get(sid)
        return bool(state) and str(state[0]).lower() in ("true", "1")

    def _state_level(self, sid):
        state = self.w_state.get(sid)
        try:
            return int(str(state[1]))
        except (TypeError, ValueError):
            return 1

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
            self.after(0, after)

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
            client, "unlock_wskill", (tgt, sid, lvl), "Learned.",
            lambda: self._do_wstate(client, tgt, self.app.job(),
                                    self.app.enum_data or {})))

    def unlock_all_async(self, which):
        """which=0 -> this vocation, which=-1 -> every vocation (job 0)."""
        client = require_client(self.app)
        if not client:
            return
        scope = ("every vocation" if which == -1 else
                 f"vocation {self.app.job():02d}")
        n = len(getattr(self, "w_rows", []) or [])
        what = (f"This writes to your save: weapon skills for {scope} "
                f"will be learned at the chosen level"
                + (f" ({n} skills in the current list)." if n else "."))
        if not self.app.confirm_bulk("Learn all weapon skills", what):
            return
        tgt, job = self.app.target(), self.app.job() if which == 0 else 0
        lvl = self._unlock_level()
        run_async(self, lambda: self._do_simple(
            client, "unlock_wskills", (tgt, job, lvl), None,
            lambda: self._do_wstate(client, tgt, self.app.job(),
                                    self.app.enum_data or {})))

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
        if not self._is_learned(sid):
            self.app.set_status("That weapon skill is already unlearned.")
            return
        if sid in self.cur_skills:
            slots = [str(i + 1) for i, s in enumerate(self.cur_skills)
                     if s == sid]
            self.app.set_status(
                "That skill is equipped in slot " + ", ".join(slots)
                + ". Clear the slot first, then unlearn it.")
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, lvl = self.app.target(), self._state_level(sid)
        run_async(self, lambda: self._do_unlearn(client, tgt, sid, lvl))

    def _do_unlearn(self, client, tgt, sid, lvl):
        try:
            res = client.send("disable_wskill", tgt, sid, timeout=20)
            if not res.lower().startswith(("already", "nothing")):
                self.app.record_undo(
                    f"weapon skill {sid}",
                    lambda c, t=tgt, s=sid, l=lvl: c.send(
                        "unlock_wskill", t, s, l, timeout=20))
            self.after(0, lambda: (
                self.app.set_status(self._unlearn_msg(res)),
                self.refresh_async(quiet=True)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Unlearn failed: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def unlearn_all_async(self):
        client = require_client(self.app)
        if not client:
            return
        learned = [sid for sid in self.w_rows if self._is_learned(sid)]
        if not learned:
            self.app.set_status("No learned weapon skills in this list.")
            return
        equipped = set(self.cur_skills)
        candidates = [sid for sid in learned if sid not in equipped]
        if not candidates:
            self.app.set_status(
                "Every learned skill here is equipped; clear the slots first.")
            return
        job = self.app.job()
        if not self.app.confirm_bulk(
                "Unlearn weapon skills",
                f"This writes to your save: {len(candidates)} learned weapon "
                f"skill(s) for vocation {job:02d} will be unlearned. "
                "Equipped skills are skipped. Ctrl+Z relearns them."):
            return
        snapshot = [(sid, self._state_level(sid)) for sid in learned]
        tgt = self.app.target()
        run_async(self, lambda: self._do_unlearn_all(client, tgt, job,
                                                     snapshot))

    def _do_unlearn_all(self, client, tgt, job, snapshot):
        try:
            res = client.send("disable_wskills", tgt, job, timeout=60)
            if not res.lower().startswith("nothing"):
                def _undo(c, snap=tuple(snapshot), t=tgt):
                    for sid, lvl in snap:
                        c.send("unlock_wskill", t, sid, lvl, timeout=20)
                    return f"relearned {len(snap)} weapon skill(s)"
                self.app.record_undo("unlearn weapon skills", _undo)
            self.after(0, lambda: (
                self.app.set_status(self._unlearn_msg(res)),
                self.refresh_async(quiet=True)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Unlearn failed: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def set_level_async(self):
        sid = self._selected_id()
        if sid is None:
            return
        client = require_client(self.app)
        if not client:
            return
        tgt, lvl = self.app.target(), self._unlock_level()
        prev = None
        state = getattr(self, "w_state", {}).get(sid)
        if state and str(state[1]).lstrip("-").isdigit():
            prev = int(state[1])
        run_async(self, lambda: self._do_set_level(client, tgt, sid, lvl, prev))

    def _do_set_level(self, client, tgt, sid, lvl, prev):
        try:
            res = client.send("set_wlevel", tgt, sid, lvl, timeout=20)
            if prev is not None and prev != lvl:
                self.app.record_undo(
                    f"skill {sid} level {prev}",
                    lambda c, t=tgt, s=sid, p=prev: c.send(
                        "set_wlevel", t, s, p, timeout=20))
            self.after(0, lambda: self.app.set_status(res))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
        self._do_wstate(client, tgt, self.app.job(), self.app.enum_data or {})
        self.after(0, lambda: self.refresh_async(quiet=True))

    def probe_async(self):
        client = require_client(self.app)
        if not client:
            return
        tgt, job = self.app.target(), self.app.job()
        self.app.set_status("Probing weapon skills (read-only)...")
        run_async(self, lambda: self._do_probe(client, tgt, job))

    def _do_probe(self, client, tgt, job):
        try:
            res = client.send("wskill_probe", tgt, job, timeout=120)
            text = client.read_sidecar("wskill_info.txt") or ""
            info = {}
            for line in text.splitlines():
                parts = line.split("\t", 2)
                if len(parts) == 3 and parts[0].lstrip("-").isdigit() \
                        and parts[2]:
                    info[int(parts[0])] = parts[2]
            self.w_info = info
            self.after(0, lambda: (
                show_probe(self, "Weapon skill probe",
                           text or "(wskill_info.txt missing)"),
                self.app.set_status(f"Probe: {res}")))
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
        self.app.set_status(f"Adding missing EnabledCustomSkills entry for "
                            f"skill {sid} at level {lvl}...")
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
        self.app.set_status("Probing (equip the weapon with the upgraded "
                            "skills first)...")
        run_async(self, lambda: self._do_eq_probe(client, cmd, filename,
                                                  title, tgt, job))

    def _do_eq_probe(self, client, cmd, filename, title, tgt, job):
        try:
            res = client.send(cmd, tgt, job, timeout=120)
            text = client.read_sidecar(filename) or f"({filename} missing)"
            n = len(text.splitlines())
            self.after(0, lambda: (
                show_probe(self, title, text),
                self.app.set_status(f"Probe done: {res} ({n} lines).")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
