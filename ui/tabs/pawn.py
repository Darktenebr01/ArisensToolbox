"""Pawn tab: rating (thumbs-up / hearts) and badge progress for the selected pawn."""
import tkinter as tk
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, H2, Muted, PrimaryButton, GhostButton,
    Field, StyledListbox, run_async, require_client, show_probe,
)


class PawnTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self.badges = []   # [(n, cur)] in listbox order
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        H1(self, "Rating & Badges", row=0, column=0, sticky="w", pady=(0, 10))

        # rating card
        card = Card(self, row=1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)
        H2(cc, "Rating", row=0, column=0, sticky="w", pady=(0, 6))
        Muted(cc, "Edits the pawn chosen in the Pawn box at the top.",
              row=1, column=0, sticky="w", pady=(0, 6))
        inner = ctk.CTkFrame(cc, fg_color="transparent")
        inner.grid(row=2, column=0, sticky="w")
        ctk.CTkLabel(inner, **T.body("Thumbs up:")).pack(side="left")
        self.good_var = ctk.StringVar(value="0")
        Field(inner, textvariable=self.good_var, width=80).pack(side="left", padx=(4, 16))
        ctk.CTkLabel(inner, **T.body("Hearts:")).pack(side="left")
        self.like_var = ctk.StringVar(value="0")
        Field(inner, textvariable=self.like_var, width=80).pack(side="left", padx=(4, 16))
        GhostButton(inner, text="Read", width=80,
                    command=self.read_rating_async).pack(side="left", padx=4)
        PrimaryButton(inner, text="Apply", width=80,
                      command=self.apply_rating_async).pack(side="left", padx=4)

        # badges card
        card = Card(self, row=2, column=0, sticky="nsew", padx=4, pady=6)
        cc = card_content(card)
        cc.grid_rowconfigure(1, weight=1)
        H2(cc, "Badge progress (the x in x/30)",
           row=0, column=0, sticky="w", pady=(0, 6))
        self.badge_list = StyledListbox(cc)
        self.badge_list.grid(row=1, column=0, sticky="nsew", pady=(0, 6))
        sb = tk.Scrollbar(cc, orient="vertical", command=self.badge_list.yview)
        sb.grid(row=1, column=1, sticky="ns")
        self.badge_list.config(yscrollcommand=sb.set)

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=2, column=0, sticky="ew", pady=(0, 4))
        GhostButton(brow, text="Read badges", width=110,
                    command=self.read_badges_async).pack(side="left", padx=(0, 12))
        ctk.CTkLabel(brow, **T.body("New value:")).pack(side="left")
        self.val_var = ctk.StringVar(value="30")
        Field(brow, textvariable=self.val_var, width=60).pack(side="left", padx=(4, 12))
        PrimaryButton(brow, text="Set selected", width=110,
                      command=self.set_badge_async).pack(side="left", padx=4)
        GhostButton(brow, text="Fill ALL to quota", width=140,
                    command=self.fill_badges_async).pack(side="left", padx=4)

        brow2 = ctk.CTkFrame(cc, fg_color="transparent")
        brow2.grid(row=3, column=0, sticky="w")
        GhostButton(brow2, text="Grant selected badge", width=170,
                    command=self.grant_badge_async).pack(side="left")
        GhostButton(brow2, text="Probe badge data", width=150,
                    command=self.probe_badges_async).pack(side="left", padx=8)
        GhostButton(brow2, text="Probe badge names", width=160,
                    command=self.probe_badge_names_async).pack(side="left")

    # -- refresh (called by the app after pawn picker changes) ----------

    def refresh(self):
        """Re-read rating + badges for the newly selected pawn."""
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
            self.after(0, lambda: (
                self.good_var.set(g), self.like_var.set(l),
                self.app.set_status("Rating read.")))
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
            client.send("set_rating", g, l)
            self.after(0, lambda: self.app.set_status("Rating applied."))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- badges ----------------------------------------------------------

    # Confirmed in-game badge names (PB number -> name). Only add mappings
    # proven by the darken test or certain by quota; never guess.
    # 2026-10-11: user darken-tested PB020/021/025/026/027/040/041; the rest
    # deduced from screenshot grid order (grid slot n = PB(n+16)) + quota match.
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
                    shown = self.BADGE_NAMES.get(int(n), self._badge_kind(quota))
                    labels.append(
                        f"PB{int(n):03d}  {shown}   {cur} / {quota}")
            self.badges = badges
            def _ui():
                self.badge_list.delete(0, tk.END)
                for lbl in labels:
                    self.badge_list.insert(tk.END, lbl)
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
        n = b[0]
        run_async(self, lambda: self._set_badge(client, n, v))

    def _set_badge(self, client, n, v):
        try:
            client.send("set_badge", n, v)
            self.after(0, lambda: (
                self.app.set_status(f"PB{n:03d} = {v}"),
                self.read_badges_async()))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def fill_badges_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._fill_badges(client))

    def _fill_badges(self, client):
        try:
            res = client.send("fill_badges", timeout=60)
            self.after(0, lambda: (
                self.app.set_status(f"Filled {res} badges."),
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
        n = b[0]
        run_async(self, lambda: self._grant_badge(client, n))

    def _grant_badge(self, client, n):
        try:
            client.send("grant_badge", n)
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
                self.app.set_status("Badge name probe done - full output in the popup."),
                show_probe(self, "Badge name probe - copy all of it", res)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _probe_badges(self, client):
        try:
            res = client.send("badge_probe", timeout=30)
            self.after(0, lambda: (
                self.app.set_status("Badge probe done - full output in the popup."),
                show_probe(self, "Badge probe - copy all of it", res)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
