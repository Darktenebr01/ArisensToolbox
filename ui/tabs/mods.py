"""Mods: jump and movement tweaks, fast travel, respawn timers, boss tools."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui.base import BaseTab
from ui import theme as T
from ui.widgets import (
    Section, PageHeader, Row, ScrollArea, Frame, Field, Combo, Switch,
    Slider, PrimaryButton, GhostButton, QuietButton, caption, dev_only,
    run_async, require_client, show_probe,
)


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


class ModsTab(BaseTab):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self._loading = False
        self.orig_height = None
        self.summon_tries = 0
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        PageHeader(
            self, "Mods",
            "Player-side tweaks. Sliders apply when you release them; the "
            "game only needs to be running.").grid(
                row=0, column=0, sticky="ew", pady=(0, T.PAD_L))

        self.scroll = ScrollArea(self)
        self.scroll.grid(row=1, column=0, sticky="nsew")
        body = self.scroll
        self._build_jump(body, row=0)
        self._build_movement(body, row=1)
        self._build_fast_travel(body, row=2)
        self._build_respawn(body, row=3)
        self._build_boss(body, row=4)

    # -- jump ------------------------------------------------------------

    def _build_jump(self, body, row):
        card = Section(body, "Jump & fall",
                       **{"row": row, "column": 0, "sticky": "ew",
                          "pady": (0, T.PAD_M)})
        cc = card.body

        line = Frame(cc)
        line.grid(row=0, column=0, sticky="ew")
        line.grid_columnconfigure(0, weight=1)
        self.h_label_var = ctk.StringVar(value="Jump height")
        ctk.CTkLabel(line, textvariable=self.h_label_var,
                     font=T.font(T.SIZE_BODY, "bold"),
                     text_color=T.TEXT, anchor="w").grid(row=0, column=0,
                                                         sticky="w")
        self.h_slider = Slider(cc, from_=1, to=500, number_of_steps=499,
                               command=self._on_height_change)
        self.h_slider.grid(row=1, column=0, sticky="ew", pady=(T.PAD_XS, 0))
        self.h_slider.set(10)
        self.h_slider.bind("<ButtonRelease-1>", lambda _e: self._send())

        self.a_label_var = ctk.StringVar(value="Air time")
        ctk.CTkLabel(cc, textvariable=self.a_label_var,
                     font=T.font(T.SIZE_BODY, "bold"), text_color=T.TEXT,
                     anchor="w").grid(row=2, column=0, sticky="w",
                                      pady=(T.PAD_M, 0))
        self.a_slider = Slider(cc, from_=30, to=120, number_of_steps=90,
                               command=self._on_air_change)
        self.a_slider.grid(row=3, column=0, sticky="ew", pady=(T.PAD_XS, 0))
        self.a_slider.set(100)
        self.a_slider.bind("<ButtonRelease-1>", lambda _e: self._send())

        self.nofall_var = ctk.BooleanVar(value=False)
        Switch(cc, text="No fall damage", variable=self.nofall_var,
               command=self._on_nofall_toggle).grid(row=4, column=0,
                                                    sticky="w",
                                                    pady=(T.PAD_M, 0))

        row_ = Row(cc)
        row_.grid(row=5, column=0, sticky="w", pady=(T.PAD_M, 0))
        row_.add(GhostButton(row_, "Read current", width=124,
                             command=self.read_async))
        row_.add(QuietButton(row_, "Reset to game values", width=150,
                             command=self.reset_async))
        self.info_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.info_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                     anchor="w").grid(row=6, column=0, sticky="ew",
                                      pady=(T.PAD_S, 0))
        self._update_labels()

    def height(self):
        return self.h_slider.get() / 10.0

    def air(self):
        return self.a_slider.get() / 100.0

    def _update_labels(self):
        orig = (f"{self.orig_height:.1f}" if self.orig_height is not None
                else "?")
        self.h_label_var.set(f"Jump height   {self.height():.1f}"
                             f"   ·   default {orig}")
        self.a_label_var.set(f"Air time   {self.air():.2f}"
                             "   ·   default 1.00")

    def _on_height_change(self, _value):
        self._update_labels()

    def _on_air_change(self, _value):
        self._update_labels()

    def _on_nofall_toggle(self):
        if not self._loading:
            self._send()

    def _send(self):
        client = require_client(self.app)
        if not client:
            return
        h, a = f"{self.height():.2f}", f"{self.air():.3f}"
        nf = "1" if self.nofall_var.get() else "0"
        run_async(self, lambda: self._do_send(client, h, a, nf))

    def _do_send(self, client, h, a, nf):
        try:
            res = client.send("jump_set", h, a, nf)

            def _ui():
                self.app.set_status(f"Jump: {res}")
                self.info_var.set(res)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def read_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._read(client))

    def _read(self, client):
        try:
            res = client.send("jump_get")
            parts = (res or "").split(",")
            if len(parts) != 4:
                raise BridgeError(f"unexpected response: {res}")
            o, cur, air, nf = (p.strip() for p in parts)
            try:
                self.orig_height = float(o)
            except ValueError:
                self.orig_height = None
            h_pos = _clamp(round(float(cur) * 10), 1, 500)
            a_pos = _clamp(round(float(air) * 100), 30, 120)
            nofall = nf == "1"

            def _ui():
                self._loading = True
                self.h_slider.set(h_pos)
                self.a_slider.set(a_pos)
                self.nofall_var.set(nofall)
                self._loading = False
                self._update_labels()
                self.app.set_status(f"Read: height {cur} (game default {o})")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout, ValueError) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def reset_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._reset(client))

    def _reset(self, client):
        try:
            res = client.send("jump_reset")
            h_pos = (_clamp(round(self.orig_height * 10), 1, 500)
                     if self.orig_height is not None else 10)

            def _ui():
                self._loading = True
                self.h_slider.set(h_pos)
                self.a_slider.set(100)
                self.nofall_var.set(False)
                self._loading = False
                self._update_labels()
                self.app.set_status(res)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- movement ---------------------------------------------------------

    def _build_movement(self, body, row):
        card = Section(body, "Movement speed",
                       **{"row": row, "column": 0, "sticky": "ew",
                          "pady": (0, T.PAD_M)})
        cc = card.body

        self.mv_label_var = ctk.StringVar(value="Movement 100%")
        ctk.CTkLabel(cc, textvariable=self.mv_label_var,
                     font=T.font(T.SIZE_BODY, "bold"), text_color=T.TEXT,
                     anchor="w").grid(row=0, column=0, sticky="w")
        self.mv_slider = Slider(cc, from_=100, to=300, number_of_steps=200,
                                command=self._on_mv_change)
        self.mv_slider.grid(row=1, column=0, sticky="ew", pady=(T.PAD_XS, 0))
        self.mv_slider.set(100)

        self.ld_label_var = ctk.StringVar(value="Ladder 100%")
        ctk.CTkLabel(cc, textvariable=self.ld_label_var,
                     font=T.font(T.SIZE_BODY, "bold"), text_color=T.TEXT,
                     anchor="w").grid(row=2, column=0, sticky="w",
                                      pady=(T.PAD_M, 0))
        self.ld_slider = Slider(cc, from_=100, to=300, number_of_steps=200,
                                command=self._on_ld_change)
        self.ld_slider.grid(row=3, column=0, sticky="ew", pady=(T.PAD_XS, 0))
        self.ld_slider.set(100)

        self.mv_pawns_var = ctk.BooleanVar(value=True)
        Switch(cc, text="Apply to pawns too", variable=self.mv_pawns_var,
               command=self._on_mv_toggle).grid(row=4, column=0, sticky="w",
                                                pady=(T.PAD_M, 0))

        row_ = Row(cc)
        row_.grid(row=5, column=0, sticky="w", pady=(T.PAD_M, 0))
        row_.add(PrimaryButton(row_, "Apply", width=110,
                               command=self.movespeed_apply_async))
        row_.add(GhostButton(row_, "Read current", width=124,
                             command=self.movespeed_read_async))
        self.mv_info_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.mv_info_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                     anchor="w").grid(row=6, column=0, sticky="ew",
                                      pady=(T.PAD_S, 0))
        self._update_mv_labels()

    def _update_mv_labels(self):
        self.mv_label_var.set(f"Movement   {int(self.mv_slider.get())}%")
        self.ld_label_var.set(f"Ladder climb   {int(self.ld_slider.get())}%")

    def _on_mv_change(self, _value):
        self._update_mv_labels()

    def _on_ld_change(self, _value):
        self._update_mv_labels()

    def _on_mv_toggle(self):
        pass  # applied together with the sliders via Apply

    def movespeed_apply_async(self):
        client = require_client(self.app)
        if not client:
            return
        rate = str(int(self.mv_slider.get()))
        pawns = "1" if self.mv_pawns_var.get() else "0"
        ladder = str(int(self.ld_slider.get()))
        run_async(self, lambda: self._do_movespeed_apply(client, rate, pawns,
                                                         ladder))

    def _do_movespeed_apply(self, client, rate, pawns, ladder):
        try:
            res = client.send("movespeed_set", rate, pawns, ladder, timeout=15)

            def _ui():
                self.app.set_status(f"Movement: {res}")
                self.mv_info_var.set(res)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def movespeed_read_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_movespeed_read(client))

    def _do_movespeed_read(self, client):
        try:
            res = client.send("movespeed_get", timeout=10)
            parts = (res or "").split("|")
            if len(parts) != 4:
                self.after(0, lambda: self.app.set_status(
                    f"Error: unexpected response: {res}"))
                return
            rate, pawns, ladder, hook = (p.strip() for p in parts)

            def _ui():
                self.mv_slider.set(_clamp(int(float(rate)), 100, 300))
                self.ld_slider.set(_clamp(int(float(ladder)), 100, 300))
                self.mv_pawns_var.set(pawns == "1")
                self._update_mv_labels()
                self.mv_info_var.set(
                    f"Movement {rate}%, pawns {'on' if pawns == '1' else 'off'}"
                    f", ladder {ladder}% ({hook})")
                self.app.set_status("Movement speed read.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- fast travel ------------------------------------------------------

    def _build_fast_travel(self, body, row):
        card = Section(
            body, "Fast travel",
            hint="Warp through the engine's own pipeline - party included, "
                 "no Ferrystones. Six seconds of fall protection follow "
                 "every warp.",
            **{"row": row, "column": 0, "sticky": "ew",
               "pady": (0, T.PAD_M)})
        cc = card.body
        line = Row(cc)
        line.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(line, text="Mode", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(0, T.PAD_S))
        self.warp_mode_var = ctk.StringVar(value="Fixed altitude drop")
        Combo(line, variable=self.warp_mode_var, width=240,
              values=["Fixed altitude drop",
                      "Above destination (+offset)"]).pack(side="left")
        ctk.CTkLabel(line, text="Altitude / offset",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_L, T.PAD_S))
        self.alt_var = ctk.StringVar(value="350")
        Field(line, textvariable=self.alt_var, width=90).pack(side="left")
        ctk.CTkLabel(line, text="m", font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED).pack(side="left", padx=(T.PAD_XS, 0))

        row_ = Row(cc)
        row_.grid(row=1, column=0, sticky="w", pady=(T.PAD_M, 0))
        row_.add(PrimaryButton(row_, "Warp to map pin", width=160,
                               command=lambda: self.warp_async("warp_to_pin")))
        row_.add(PrimaryButton(row_, "Warp to quest marker", width=180,
                               command=lambda: self.warp_async(
                                   "warp_to_quest")))
        dev_only(self, lambda: QuietButton(row_, "Diagnose warp", width=120,
                                          command=self.warp_probe_async).pack(
            side="left"))
        self.warp_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.warp_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED,
                     anchor="w").grid(row=2, column=0, sticky="ew",
                                      pady=(T.PAD_S, 0))
        caption(cc, "100-2000 m for a fixed drop, 1-50 m for an offset above "
                    "the destination.",
                row=3, column=0, sticky="ew", pady=(T.PAD_XS, 0))

    def warp_async(self, cmd):
        client = require_client(self.app)
        if not client:
            return
        mode = "offset" if "offset" in self.warp_mode_var.get().lower() \
            else "fixed"
        try:
            alt = float(self.alt_var.get())
        except ValueError:
            self.app.set_status("Altitude / offset must be a number.")
            return
        alt = _clamp(alt, 1, 2000) if mode == "offset" \
            else _clamp(alt, 100, 2000)
        run_async(self, lambda: self._do_warp(client, cmd, mode, f"{alt:.1f}"))

    def _do_warp(self, client, cmd, mode, alt):
        try:
            res = client.send(cmd, mode, alt, timeout=30)

            def _ui():
                self.app.set_status(res)
                self.warp_var.set(res)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def warp_probe_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_warp_probe(client))

    def _do_warp_probe(self, client):
        try:
            res = client.send("warp_probe", timeout=30)
            self.after(0, lambda: show_probe(
                self, "Warp diagnostics", res.replace(" // ", "\n")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- respawn ----------------------------------------------------------

    def _build_respawn(self, body, row):
        card = Section(
            body, "Enemy respawn",
            hint="Overrides how many in-game hours until enemies respawn. "
                 "The override is off until you press Apply; Reset turns it "
                 "back off. Rest once to trigger the reload.",
            **{"row": row, "column": 0, "sticky": "ew",
               "pady": (0, T.PAD_M)})
        cc = card.body
        line = Row(cc)
        line.grid(row=0, column=0, sticky="ew")
        ctk.CTkLabel(line, text="Boss hours",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(0, T.PAD_S))
        self.boss_var = ctk.StringVar(value="1")
        Field(line, textvariable=self.boss_var, width=70).pack(side="left")
        ctk.CTkLabel(line, text="Normal hours",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(T.PAD_L, T.PAD_S))
        self.normal_var = ctk.StringVar(value="1")
        Field(line, textvariable=self.normal_var, width=70).pack(side="left")

        row_ = Row(cc)
        row_.grid(row=1, column=0, sticky="w", pady=(T.PAD_M, 0))
        row_.add(PrimaryButton(row_, "Apply", width=100,
                               command=self.respawn_apply_async))
        row_.add(GhostButton(row_, "Read current", width=120,
                             command=self.respawn_read_async))
        row_.add(QuietButton(row_, "Read defaults", width=120,
                             command=self.respawn_defaults_async))
        row_.add(QuietButton(row_, "Reset to defaults", width=136,
                             command=self.respawn_reset_async))

        row2 = Row(cc)
        row2.grid(row=2, column=0, sticky="w", pady=(T.PAD_S, 0))
        row2.add(GhostButton(row2, "Fast-forward 3 days (clear corpses)",
                             width=280, command=self.respawn_clear_async))
        dev_only(self, lambda: QuietButton(row2, "Diagnose time-skip",
                                          width=140,
                                          command=self.timeskip_probe_async).pack(
            side="left"))
        dev_only(self, lambda: QuietButton(row2, "Dump signature", width=124,
                                          command=self.timeskip_sig_async).pack(
            side="left"))
        dev_only(self, lambda: QuietButton(row2, "Dump time fields", width=130,
                                          command=self.timemgr_dump_async).pack(
            side="left"))

        self.respawn_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.respawn_var,
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED, anchor="w",
                     justify="left").grid(row=3, column=0, sticky="ew",
                                         pady=(T.PAD_S, 0))

    def respawn_apply_async(self):
        client = require_client(self.app)
        if not client:
            return
        try:
            b = int(self.boss_var.get())
            n = int(self.normal_var.get())
        except ValueError:
            self.app.set_status("Respawn hours must be whole numbers.")
            return
        if b < 0 or n < 0:
            self.app.set_status("Respawn hours can't be negative.")
            return
        run_async(self, lambda: self._do_respawn_apply(client, b, n))

    def _do_respawn_apply(self, client, b, n):
        try:
            res = client.send("respawn_set", b, n, timeout=15)

            def _ui():
                self.app.set_status(res)
                self.respawn_var.set(res)
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def respawn_read_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_respawn_read(client))

    def respawn_clear_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_respawn_clear(client))

    def _do_respawn_clear(self, client):
        try:
            res = client.send("respawn_clear", timeout=30)
            self.after(0, lambda: (
                self.app.set_status("Fast-forward done - full output in the "
                                    "popup."),
                self.respawn_var.set("Full output in the popup."),
                show_probe(self, "Fast-forward 3 days", res)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def timeskip_probe_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_timeskip_probe(client))

    def timeskip_sig_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_timeskip_sig(client))

    def timemgr_dump_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_timemgr_dump(client))

    def _do_timemgr_dump(self, client):
        try:
            res = client.send("timemgr_dump", timeout=20)
            self.after(0, lambda: show_probe(
                self, "Time fields", res.replace(" // ", "\n")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.respawn_var.set(err))

    def _do_timeskip_sig(self, client):
        try:
            res = client.send("timeskip_sig", timeout=15)
            self.after(0, lambda: show_probe(
                self, "Time-skip signature", res.replace(" // ", "\n")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.respawn_var.set(err))

    def _do_timeskip_probe(self, client):
        try:
            res = client.send("timeskip_probe", timeout=15)
            self.after(0, lambda: show_probe(
                self, "Time-skip probe", res.replace(" // ", "\n")))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def respawn_reset_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_respawn_reset(client))

    def _do_respawn_reset(self, client):
        try:
            res = client.send("respawn_reset", timeout=10)
            parts = (res or "").split(",")
            if len(parts) != 2:
                self.after(0, lambda: self.app.set_status(
                    f"Error: unexpected response: {res}"))
                return

            def _ui():
                self.boss_var.set(parts[0].strip())
                self.normal_var.set(parts[1].strip())
                self.respawn_var.set(
                    f"Reset to game defaults: boss {parts[0].strip()}h, "
                    f"normal {parts[1].strip()}h")
                self.app.set_status("Respawn times reset to game defaults.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def respawn_defaults_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._do_respawn_defaults(client))

    def _do_respawn_defaults(self, client):
        try:
            res = client.send("respawn_defaults", timeout=10)
            parts = (res or "").split(",")
            if len(parts) != 3:
                self.after(0, lambda: self.app.set_status(
                    f"Error: unexpected response: {res}"))
                return
            b, n, d = (p.strip() for p in parts)
            unknown = "?" in (b, n, d)
            msg = (f"Game defaults: boss {b}h, normal {n}h, repop day {d}"
                   + (" - '?' means the game hasn't reported that value yet; "
                      "kill an enemy or rest, then read again."
                      if unknown else ""))
            self.after(0, lambda: (self.app.set_status(msg),
                                   self.respawn_var.set(msg)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _do_respawn_read(self, client):
        try:
            res = client.send("respawn_get", timeout=10)
            parts = (res or "").split(",")
            if len(parts) not in (2, 3):
                self.after(0, lambda: self.app.set_status(
                    f"Error: unexpected response: {res}"))
                return
            on = len(parts) == 3 and parts[2].strip() == "1"

            def _ui():
                self.boss_var.set(parts[0].strip())
                self.normal_var.set(parts[1].strip())
                state = ("override ON" if on
                         else "override OFF (game defaults in effect)")
                self.respawn_var.set(
                    f"Current: boss {parts[0].strip()}h, normal "
                    f"{parts[1].strip()}h - {state}")
                self.app.set_status("Respawn times read.")
            self.after(0, _ui)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- boss tools -------------------------------------------------------

    # Boss-tier CharacterID codes, with display names from the reference
    # spawner data (Cyclops and Medusa confirmed in-game). Codes with no
    # sourced name stay bare; the Dragon entry sends its working _10 variant.
    SUMMON_BOSSES = [
        ("ch229000", "Dullahan"),
        ("ch230004", "ch230004"),
        ("ch231000", "ch231000"),
        ("ch240000", "Purgener (Battahl)"),
        ("ch250000", "Cyclops"),
        ("ch251000", "Ogre"),
        ("ch251001", "Grim Ogre"),
        ("ch252000", "Golem"),
        ("ch253000", "Griffin"),
        ("ch253001", "Sphinx"),
        ("ch254000", "Chimera"),
        ("ch254001", "Gore Chimera"),
        ("ch255000", "Medusa"),
        ("ch256000", "Minotaur"),
        ("ch256001", "Gore Minotaur"),
        ("ch257000", "Drake"),
        ("ch257001", "Lesser Dragon"),
        ("ch257003", "ch257003"),
        ("ch258000_10", "Dragon"),
        ("ch258001", "Nex"),
        ("ch258002", "ch258002"),
        ("ch259000", "Talos"),
        ("ch260000", "Garm"),
        ("ch260001", "Warg"),
        ("ch261000", "ch261000"),
        ("ch261001", "Satanachia"),
        ("ch227000", "Lich"),
        ("ch226003", "Skeleton Lord"),
        ("ch253010", "Purgener (Vermund)"),
        ("ch253011", "Purgener (Island Encampment)"),
        ("ch255010", "Purgener (Sacred Arbor)"),
        ("ch255011", "Purgener (Volcanic Island)"),
        ("ch227001", "Wight"),
        ("ch270000", "Evil Eye"),
    ]

    def _build_boss(self, body, row):
        card = Section(
            body, "Boss tools",
            hint="Pick a boss and press Summon, then walk toward an enemy "
                 "group: the next spawn becomes that boss at your feet. "
                 "Medusa is scripted by the game and may only stand there.",
            **{"row": row, "column": 0, "sticky": "ew"})
        cc = card.body
        line = Row(cc)
        line.grid(row=0, column=0, sticky="ew")
        labels = [f"{name}  ·  {code}" for code, name in self.SUMMON_BOSSES]
        self.summon_var = ctk.StringVar(value=labels[4])  # Cyclops
        self.summon_combo = Combo(line, variable=self.summon_var,
                                  values=labels, width=280)
        self.summon_combo.pack(side="left")
        self.summon_btn = PrimaryButton(line, "Summon", width=100,
                                        command=self.summon_async)
        self.summon_btn.pack(side="left", padx=(T.PAD_S, 0))
        QuietButton(line, "Summon log", width=110,
                    command=self.summon_log_async).pack(side="left",
                                                        padx=(T.PAD_S, 0))
        dev_only(self, lambda: QuietButton(line, "Diagnose boss", width=124,
                                          command=self.summon_diag_async).pack(
            side="left"))

        custom = Row(cc)
        custom.grid(row=1, column=0, sticky="ew", pady=(T.PAD_S, 0))
        ctk.CTkLabel(custom, text="Custom code",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).pack(
            side="left", padx=(0, T.PAD_S))
        self.summon_custom_var = ctk.StringVar(value="")
        Field(custom, textvariable=self.summon_custom_var, width=160).pack(
            side="left")
        ctk.CTkLabel(custom, text="overrides the dropdown, e.g. ch251001",
                     font=T.font(T.SIZE_SMALL), text_color=T.FAINT).pack(
            side="left", padx=(T.PAD_S, 0))

        tools = Row(cc)
        tools.grid(row=2, column=0, sticky="w", pady=(T.PAD_M, 0))
        tools.add(GhostButton(tools, "Identify nearby", width=130,
                              command=self.summon_identify_async))
        tools.add(GhostButton(tools, "Kill nearby enemies", width=160,
                              command=self.summon_kill_async))
        dev_only(self, lambda: QuietButton(tools, "Diagnose kill", width=120,
                                          command=self.summon_killdiag_async).pack(
            side="left"))
        dev_only(self, lambda: QuietButton(tools, "Dump catalog", width=120,
                                          command=self.summon_catalog_async).pack(
            side="left"))
        dev_only(self, lambda: QuietButton(tools, "Probe death", width=110,
                                          command=self.summon_probedeath_async).pack(
            side="left"))
        dev_only(self, lambda: QuietButton(tools, "EXP credit", width=100,
                                          command=self.summon_probexp_async).pack(
            side="left"))
        caption(cc, "Identify lists every enemy nearby with its code - stand "
                    "next to one to source an unknown code.",
                row=3, column=0, sticky="ew", pady=(T.PAD_S, 0))

    def summon_async(self):
        client = require_client(self.app)
        if not client:
            return
        custom = self.summon_custom_var.get().strip()
        if custom:
            import re as _re
            if not _re.match(r"^ch\d[\w_]*$", custom):
                self.app.set_status("Custom code must look like ch251001.")
                return
            run_async(self, lambda: self._summon(client, custom))
            return
        label = self.summon_var.get().strip()
        name = dict((f"{n}  ·  {c}", c)
                    for c, n in self.SUMMON_BOSSES).get(label, label)
        run_async(self, lambda: self._summon(client, name))

    def _summon(self, client, name):
        try:
            res = client.send("summon_boss", name, timeout=30)
        except (BridgeError, BridgeTimeout) as e:
            err = (f"Summon failed: {e} - every step is in the summon log "
                   "(Summon log button).")
            self.after(0, lambda: self.app.set_status(err))
            return
        self.after(0, lambda: self.app.set_status(res))
        self.summon_tries = 0
        self.after(3000, lambda: run_async(
            self, lambda: self._summon_verify(client)))

    def _summon_verify(self, client):
        # The prefab warms up asynchronously: poll quietly and only pop the
        # log when the boss is found or the last poll lands.
        if not self.winfo_exists():
            return
        self.summon_tries += 1
        try:
            res = client.send("summon_verify", timeout=15)
        except (BridgeError, BridgeTimeout) as e:
            err = f"Verify failed: {e}"
            self.after(0, lambda: self.app.set_status(err))
            return
        if "instance=FOUND" in res or self.summon_tries >= 3:
            text = client.read_sidecar("summon_log.txt") or \
                "(summon_log.txt missing)"
            status = res
            if "instance=FOUND" not in res:
                status += (" - the conversion was logged but no boss "
                           "appeared: press Summon again (the game discarded "
                           "that spawn)")
            self.after(0, lambda: (
                self.app.set_status(status),
                show_probe(self, "Summon log", text)))
        else:
            self.after(0, lambda: self.app.set_status(
                res + "  (checking again)"))
            delay = 9000 if self.summon_tries == 1 else 18000
            self.after(delay, lambda: run_async(
                self, lambda: self._summon_verify(client)))

    def summon_identify_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_identify(client))

    def _summon_identify(self, client):
        try:
            res = client.send("summon_probe51", timeout=60)
            text = client.read_sidecar("summon_identify.txt") or \
                "(summon_identify.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Identify nearby: {res}."),
                show_probe(self, "Identify nearby", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = (f"Error: {e} - if the command is unknown, the game is "
                   "still running an old bridge: press Start once to update "
                   "it.")
            self.after(0, lambda: self.app.set_status(err))

    def summon_diag_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_diag(client))

    def _summon_diag(self, client):
        try:
            res = client.send("summon_probe49", timeout=60)
            text = client.read_sidecar("summon_probe49.txt") or \
                "(summon_probe49.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Boss diagnosis: {res}."),
                show_probe(self, "Boss diagnosis", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e} - press Start once to update the bridge."
            self.after(0, lambda: self.app.set_status(err))

    def summon_kill_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_kill(client))

    def _summon_kill(self, client):
        try:
            res = client.send("summon_kill", timeout=60)
            text = client.read_sidecar("summon_kill.txt") or \
                "(summon_kill.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Kill nearby enemies: {res}."),
                show_probe(self, "Kill nearby enemies", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e} - press Start once to update the bridge."
            self.after(0, lambda: self.app.set_status(err))

    def summon_killdiag_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_killdiag(client))

    def _summon_killdiag(self, client):
        try:
            res = client.send("summon_probe52", timeout=60)
            text = client.read_sidecar("summon_killdiag.txt") or \
                "(summon_killdiag.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Diagnose kill: {res}."),
                show_probe(self, "Diagnose kill", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e} - press Start once to update the bridge."
            self.after(0, lambda: self.app.set_status(err))

    def summon_catalog_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_catalog(client))

    def _summon_catalog(self, client):
        try:
            res = client.send("summon_probe2", timeout=60)
            text = client.read_sidecar("summon_probe2.txt") or \
                "(summon_probe2.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Dump catalog: {res}."),
                show_probe(self, "Dump catalog", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e} - press Start once to update the bridge."
            self.after(0, lambda: self.app.set_status(err))

    def summon_probedeath_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_probedeath(client))

    def _summon_probedeath(self, client):
        try:
            res = client.send("summon_probe53", timeout=60)
            text = client.read_sidecar("summon_probe53.txt") or \
                "(summon_probe53.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Probe death: {res}."),
                show_probe(self, "Probe death", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e} - press Start once to update the bridge."
            self.after(0, lambda: self.app.set_status(err))

    def summon_probexp_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_probexp(client))

    def _summon_probexp(self, client):
        try:
            res = client.send("summon_probe54", timeout=60)
            text = client.read_sidecar("summon_expdiag.txt") or \
                "(summon_expdiag.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Diagnose EXP credit: {res}."),
                show_probe(self, "Diagnose EXP credit", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e} - press Start once to update the bridge."
            self.after(0, lambda: self.app.set_status(err))

    def summon_log_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._summon_log(client))

    def _summon_log(self, client):
        text = client.read_sidecar("summon_log.txt") or \
            "(no summon_log.txt yet - summon something first)"
        self.after(0, lambda: show_probe(self, "Summon log", text))
