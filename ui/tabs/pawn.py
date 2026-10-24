"""Rating & Badges: pawn rating (thumbs-up / hearts) and badge progress."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ListPanel, Field, PrimaryButton, GhostButton,
    QuietButton, caption, dev_only, run_async, require_client, show_probe,
)


class PawnTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.badges = []   # [(n, cur)] in listbox order
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        header = PageHeader(
            self, "Rating & Badges",
            "Edit the pawn picked in the pawn selector above.")
        header.grid(row=0, column=0, sticky="ew", pady=(0, T.PAD_L))
        header.action(GhostButton(header.actions, "Refresh", width=96,
                                  command=self.refresh))

        rating = Section(self, "Rating", **{"row": 1, "column": 0,
                                            "sticky": "ew",
                                            "pady": (0, T.PAD_M)})
        body = rating.body
        row = Row(body)
        row.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(row, text="Thumbs up", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.good_var = ctk.StringVar(value="0")
        Field(row, textvariable=self.good_var, width=80).pack(side="left")
        ctk.CTkLabel(row, text="Hearts", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left",
                                              padx=(T.PAD_L, T.PAD_S))
        self.like_var = ctk.StringVar(value="0")
        Field(row, textvariable=self.like_var, width=80).pack(side="left")
        QuietButton(row, "Read", width=70,
                    command=self.read_rating_async).pack(side="left",
                                                         padx=(T.PAD_L, 0))
        PrimaryButton(row, "Apply", width=90,
                      command=self.apply_rating_async).pack(side="left",
                                                            padx=(T.PAD_S, 0))

        badges = Section(self, "Badge progress",
                         hint="The x in x/30. Select a badge to change it.",
                         **{"row": 2, "column": 0, "sticky": "nsew"})
        body = badges.body
        body.grid_rowconfigure(0, weight=1)
        self.panel = ListPanel(body, height=10,
                               empty="Read the badges of this pawn.")
        self.panel.grid(row=0, column=0, sticky="nsew")
        self.badge_list = self.panel.listbox

        row = Row(body)
        row.grid(row=1, column=0, sticky="ew", pady=(T.PAD_M, 0))
        row.add(QuietButton(row, "Read badges", width=110,
                            command=self.read_badges_async))
        ctk.CTkLabel(row, text="New value",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_S, T.PAD_S))
        self.val_var = ctk.StringVar(value="30")
        Field(row, textvariable=self.val_var, width=64).pack(side="left")
        row.add(PrimaryButton(row, "Set selected", width=116,
                              command=self.set_badge_async), gap=T.PAD_S)
        row.add(GhostButton(row, "Grant selected", width=116,
                            command=self.grant_badge_async))
        row.add(GhostButton(row, "Fill all to quota", width=128,
                            command=self.fill_badges_async))
        dev_only(self, lambda: QuietButton(row, "Probe data", width=100,
                                          command=self.probe_badges_async).pack(
            side="left"))
        dev_only(self, lambda: QuietButton(row, "Probe names", width=104,
                                          command=self.probe_badge_names_async).pack(
            side="left"))
        caption(body, "Fills are bulk edits and write to your save; the "
                      "automatic backup runs before the first change.",
                row=2, column=0, sticky="ew", pady=(T.PAD_S, 0))

    # -- refresh (called by the app after the pawn picker changes) ------

    def refresh(self):
        self.read_rating_async()
        self.read_badges_async()

    # -- rating ---------------------------------------------------------

    def read_rating_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read_rating(client))

    def _read_rating(self, client):
        try:
            res = client.send("get_rating")
            parts = (res or "").split(",")
            if len(parts) != 2 or not all(p.strip().isdigit() for p in parts):
                raise BridgeError(f"unexpected response: {res}")
            g, l = (p.strip() for p in parts)

            def _ui():
                self.good_var.set(g)
                self.like_var.set(l)
                self.app.set_status("Rating read.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def apply_rating_async(self):
        client = require_client(self.app)
        if not client:
            return
        try:
            g, l = int(self.good_var.get()), int(self.like_var.get())
        except ValueError:
            self.app.set_status("Enter numbers.")
            return
        run_async(self, lambda: self._apply_rating(client, g, l))

    def _apply_rating(self, client, g, l):
        try:
            prev = None
            try:
                parts = (client.send("get_rating") or "").split(",")
                if len(parts) == 2 and all(p.strip().isdigit()
                                          for p in parts):
                    prev = tuple(int(p.strip()) for p in parts)
            except (BridgeError, BridgeTimeout):
                pass
            client.send("set_rating", g, l)
            if prev and prev != (g, l):
                pg, pl = prev
                self.app.record_undo(
                    f"rating {pg}/{pl}",
                    lambda c, a=pg, b=pl: c.send("set_rating", a, b))
            self.after(0, lambda: self.app.set_status("Rating applied."))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- badges ----------------------------------------------------------

    # Confirmed in-game badge names (PB number -> name). Only add mappings
    # proven by the darken test or certain by quota; never guess.
    BADGE_NAMES = {
        20: "Cyclops Clobberer",
        21: "Ogre Eliminator",
        22: "Grim Ogre Obliterator",
        23: "Golem Toppler",
        24: "Griffin Grounder",
        25: "Sphinx Smiter",
        26: "Chimera Killer",
        27: "Gorechimera",            # full in-game name TBC
        28: "Medusa Maimer",
        29: "Minotaur Mauler",
        30: "Goreminotaur Mangler",
        31: "Drake Destroyer",
        32: "Lesser Dragon Devastator",
        33: "Garm Gutter",
        34: "Warg Waster",
        36: "Vernworthian Gallivanter",
        37: "Battahli Trailblazer",
        38: "Norgan Navigator",
        40: "Evil Eye Eviscerator",
        41: "Norgan Giant Annihilator",
        42: "Blemmyae Butcherer",
        43: "Fimbl Flayer",
        50: "Death Reaper",
    }

    def read_badges_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read_badges(client))

    @staticmethod
    def _badge_kind(quota):
        """Describe a badge by its quota (the one thing the game tells us)."""
        return {
            "50": "Camp badge (camp 50x)",
            "30": "Slayer badge (30 kills)",
            "20": "Slayer badge (20 kills)",
            "10": "Slayer badge (10 kills)",
            "5": "Slayer badge (5 kills)",
            "1": "Badge (count 1)",
        }.get(quota.strip(), "Badge")

    def _read_badges(self, client):
        try:
            res = client.send("get_badges", timeout=60)
            badges, labels = [], []
            for row in (res or "").split(";"):
                # n,cur,quota,name  (name is cleaned: no commas)
                parts = row.split(",", 3)
                if len(parts) == 4 and parts[0].strip().isdigit():
                    n, cur, quota, _name = (p.strip() for p in parts)
                    badges.append((int(n), int(cur)))
                    shown = self.BADGE_NAMES.get(int(n),
                                                 self._badge_kind(quota))
                    labels.append(f"PB{int(n):03d}   {shown}   {cur} / {quota}")
            self.badges = badges

            def _ui():
                self.panel.set_rows(labels)
                self.panel.set_empty("No badges reported for this pawn.")
                self.app.set_status(f"Read {len(badges)} badges.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _selected_badge(self):
        sel = self.badge_list.curselection()
        if sel and sel[0] < len(self.badges):
            return self.badges[sel[0]]
        return None

    def set_badge_async(self):
        b = self._selected_badge()
        try:
            v = int(self.val_var.get())
        except ValueError:
            v = None
        if not b or v is None:
            self.app.set_status("Select a badge and enter a number.")
            return
        client = require_client(self.app)
        if not client:
            return
        n, prev = b[0], b[1]
        run_async(self, lambda: self._set_badge(client, n, v, prev))

    def _set_badge(self, client, n, v, prev=None):
        try:
            client.send("set_badge", n, v)
            if prev is not None and prev != v:
                self.app.record_undo(
                    f"PB{n:03d} = {prev}",
                    lambda c, nn=n, pp=prev: c.send("set_badge", nn, pp))
            self.after(0, lambda: (self.app.set_status(f"PB{n:03d} = {v}"),
                                   self.read_badges_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def fill_badges_async(self):
        client = require_client(self.app)
        if not client:
            return
        n = len(getattr(self, "badges", []) or [])
        what = (f"This writes to your save: all {n} loaded badges will "
                "be set to their quota." if n else
                "This writes to your save: all badges will be set to "
                "their quota.")
        if not self.app.confirm_bulk("Fill all badges", what):
            return
        run_async(self, lambda: self._fill_badges(client))

    def _fill_badges(self, client):
        try:
            prev = list(getattr(self, "badges", []) or [])
            res = client.send("fill_badges", timeout=60)
            if prev:
                def _undo(c, snap=prev):
                    for nn, cur in snap:
                        c.send("set_badge", nn, cur)
                    return f"restored {len(snap)} badges"
                self.app.record_undo("fill badges", _undo)
            self.after(0, lambda: (self.app.set_status(f"Filled {res} badges."),
                                   self.read_badges_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def grant_badge_async(self):
        b = self._selected_badge()
        if not b:
            self.app.set_status("Select a badge first.")
            return
        client = require_client(self.app)
        if not client:
            return
        n, prev = b[0], b[1]
        run_async(self, lambda: self._grant_badge(client, n, prev))

    def _grant_badge(self, client, n, prev=None):
        try:
            client.send("grant_badge", n)
            if prev is not None:
                self.app.record_undo(
                    f"PB{n:03d} = {prev}",
                    lambda c, nn=n, pp=prev: c.send("set_badge", nn, pp))
            self.after(0, lambda: self.app.set_status(f"Granted PB{n}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def probe_badges_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._probe_badges(client))

    def probe_badge_names_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._probe_badge_names(client))

    def _probe_badge_names(self, client):
        try:
            res = client.send("badge_probe3", timeout=30)
            self.after(0, lambda: (
                self.app.set_status("Badge name probe done."),
                show_probe(self, "Badge name probe", res)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _probe_badges(self, client):
        try:
            res = client.send("badge_probe", timeout=30)
            self.after(0, lambda: (
                self.app.set_status("Badge probe done."),
                show_probe(self, "Badge probe", res)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
