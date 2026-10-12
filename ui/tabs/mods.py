"""Mods tab: jump tweaks, fast travel, faster enemy respawn, movement speed (player)."""
import customtkinter as ctk

from bridge.protocol import BridgeError, BridgeTimeout
from ui import theme as T
from ui.widgets import (
    Card, card_content, H1, H2, Muted, PrimaryButton, GhostButton,
    Field, Check, run_async, require_client, show_probe,
)


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


class ModsTab(ctk.CTkFrame):
    def __init__(self, parent, app):
        super().__init__(parent, fg_color="transparent")
        self.app = app
        self._loading = False
        self.orig_height = None
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        H1(self, "Mods", row=0, column=0, sticky="w", pady=(0, 4))
        Muted(self, "Player mods. Jump changes apply live when you release the sliders.",
              row=1, column=0, sticky="w", pady=(0, 10))

        # scrollable content (three sections don't fit a fixed window)
        self.scroll = ctk.CTkScrollableFrame(
            self, fg_color="transparent", border_width=0)
        self.scroll.grid(row=2, column=0, sticky="nsew", padx=0, pady=0)
        self.scroll.grid_columnconfigure(0, weight=1)
        body = self.scroll

        self._build_jump(body, row=0)
        self._build_fast_travel(body, row=2)
        self._build_respawn(body, row=4)
        self._build_movement(body, row=6)

    # -- jump section ----------------------------------------------------

    def _build_jump(self, body, row):
        H2(body, "Jump", row=row, column=0, sticky="w", pady=(6, 0))
        card = Card(body, row=row + 1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)

        self.h_label_var = ctk.StringVar(value="Jump height: ?")
        ctk.CTkLabel(cc, textvariable=self.h_label_var,
                     font=(T.FONT_FAMILY, 13, "bold"),
                     text_color=T.TEXT).grid(row=0, column=0, sticky="w")
        self.h_slider = ctk.CTkSlider(
            cc, from_=1, to=500, number_of_steps=499,
            width=700, command=self._on_height_change,
            fg_color=T.SURFACE2, progress_color=T.ACCENT,
            button_color=T.ACCENT, button_hover_color=T.ACCENT_HOVER)
        self.h_slider.grid(row=1, column=0, sticky="w", pady=(4, 16))
        self.h_slider.set(10)
        self.h_slider.bind("<ButtonRelease-1>", lambda _e: self._send())

        self.a_label_var = ctk.StringVar(value="Air time: ?")
        ctk.CTkLabel(cc, textvariable=self.a_label_var,
                     font=(T.FONT_FAMILY, 13, "bold"),
                     text_color=T.TEXT).grid(row=2, column=0, sticky="w")
        self.a_slider = ctk.CTkSlider(
            cc, from_=30, to=120, number_of_steps=90,
            width=700, command=self._on_air_change,
            fg_color=T.SURFACE2, progress_color=T.ACCENT,
            button_color=T.ACCENT, button_hover_color=T.ACCENT_HOVER)
        self.a_slider.grid(row=3, column=0, sticky="w", pady=(4, 16))
        self.a_slider.set(100)
        self.a_slider.bind("<ButtonRelease-1>", lambda _e: self._send())

        self.nofall_var = ctk.BooleanVar(value=False)
        Check(cc, text="No fall damage", variable=self.nofall_var,
              command=self._on_nofall_toggle).grid(row=4, column=0, sticky="w",
                                                   pady=(0, 12))

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=5, column=0, sticky="w")
        GhostButton(brow, text="Read current", width=140,
                    command=self.read_async).pack(side="left", padx=(0, 8))
        GhostButton(brow, text="Reset to game values", width=170,
                    command=self.reset_async).pack(side="left", padx=8)
        GhostButton(brow, text="DUMP jump/fall data", width=180,
                    command=self.probe_async).pack(side="left", padx=8)

        self.info_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.info_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=6, column=0, sticky="w", pady=(8, 0))
        self._update_labels()

    def height(self):
        return self.h_slider.get() / 10.0

    def air(self):
        return self.a_slider.get() / 100.0

    def _update_labels(self):
        orig = f"{self.orig_height:.1f}" if self.orig_height is not None else "unknown - click Read current"
        self.h_label_var.set(f"Jump height: {self.height():.1f}   (game default: {orig})")
        self.a_label_var.set(f"Air time scale: {self.air():.2f}   "
                             f"(1.00 = game default; lower = longer airborne time)")

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
            self.after(0, lambda: (self.app.set_status(f"Jump: {res}"),
                                   self.info_var.set(res)))
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

    def probe_async(self):
        client = require_client(self.app)
        if not client:
            return
        run_async(self, lambda: self._probe(client))

    def _probe(self, client):
        try:
            res = client.send("jump_probe", timeout=60)
            text = client.read_sidecar("jumpprobe.txt") or "(jumpprobe.txt missing)"
            self.after(0, lambda: (
                self.app.set_status(f"Jump dump: {res} lines."),
                show_probe(self, "Jump / fall dump - copy all of it", text)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- fast travel section ----------------------------------------------

    def _build_fast_travel(self, body, row):
        from ui.widgets import Combo
        H2(body, "Fast Travel", row=row, column=0, sticky="w", pady=(6, 0))
        card = Card(body, row=row + 1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)

        Muted(cc, "Warp to a map pin/icon or your active quest marker through the engine's "
                  "warp pipeline — your pawn party comes along, no Ferrystones needed. "
                  "You get 6 seconds of fall immunity after every warp.",
              row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))

        ctk.CTkLabel(cc, text="Mode:", font=(T.FONT_FAMILY, 12),
                     text_color=T.TEXT).grid(row=1, column=0, sticky="w")
        self.warp_mode_var = ctk.StringVar(value="Fixed altitude drop")
        Combo(cc, variable=self.warp_mode_var, width=230,
              values=["Fixed altitude drop", "Above destination (+offset)"],
              ).grid(row=1, column=1, columnspan=2, sticky="w", padx=8)

        ctk.CTkLabel(cc, text="Altitude / offset:", font=(T.FONT_FAMILY, 12),
                     text_color=T.TEXT).grid(row=2, column=0, sticky="w", pady=(8, 0))
        self.alt_var = ctk.StringVar(value="350")
        Field(cc, textvariable=self.alt_var, width=100).grid(
            row=2, column=1, sticky="w", padx=8, pady=(8, 0))
        ctk.CTkLabel(cc, text="meters (100-2000 fixed; 1-50 offset)",
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=2, column=2, sticky="w", pady=(8, 0))

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=3, column=0, columnspan=4, sticky="w", pady=(10, 0))
        PrimaryButton(brow, text="Warp to map pin", width=170,
                      command=lambda: self.warp_async("warp_to_pin")).pack(side="left", padx=(0, 8))
        PrimaryButton(brow, text="Warp to quest marker", width=190,
                      command=lambda: self.warp_async("warp_to_quest")).pack(side="left", padx=8)

        self.warp_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.warp_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=4, column=0, columnspan=4, sticky="w", pady=(8, 0))

    def warp_async(self, cmd):
        client = require_client(self.app)
        if not client:
            return
        mode = "offset" if "offset" in self.warp_mode_var.get().lower() else "fixed"
        try:
            alt = float(self.alt_var.get())
        except ValueError:
            self.app.set_status("Altitude/offset must be a number.")
            return
        alt = _clamp(alt, 1, 2000) if mode == "offset" else _clamp(alt, 100, 2000)
        run_async(self, lambda: self._do_warp(client, cmd, mode, f"{alt:.1f}"))

    def _do_warp(self, client, cmd, mode, alt):
        try:
            res = client.send(cmd, mode, alt, timeout=30)
            self.after(0, lambda: (self.app.set_status(res),
                                   self.warp_var.set(res)))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- faster respawn section --------------------------------------------

    def _build_respawn(self, body, row):
        H2(body, "Faster Enemy Respawn", row=row, column=0, sticky="w", pady=(6, 0))
        card = Card(body, row=row + 1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)

        Muted(cc, "Overrides how many in-game hours until enemies respawn. "
                  "Rest at a camp/inn once to trigger the reload.",
              row=0, column=0, columnspan=4, sticky="w", pady=(0, 8))

        ctk.CTkLabel(cc, text="Boss respawn (hours):", font=(T.FONT_FAMILY, 12),
                     text_color=T.TEXT).grid(row=1, column=0, sticky="w")
        self.boss_var = ctk.StringVar(value="1")
        Field(cc, textvariable=self.boss_var, width=80).grid(row=1, column=1, sticky="w", padx=8)

        ctk.CTkLabel(cc, text="Normal enemy respawn (hours):", font=(T.FONT_FAMILY, 12),
                     text_color=T.TEXT).grid(row=1, column=2, sticky="w", padx=(16, 0))
        self.normal_var = ctk.StringVar(value="1")
        Field(cc, textvariable=self.normal_var, width=80).grid(row=1, column=3, sticky="w", padx=8)

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=2, column=0, columnspan=4, sticky="w", pady=(10, 0))
        PrimaryButton(brow, text="Apply", width=120,
                      command=self.respawn_apply_async).pack(side="left", padx=(0, 8))
        GhostButton(brow, text="Read current", width=130,
                    command=self.respawn_read_async).pack(side="left", padx=8)
        GhostButton(brow, text="Read defaults", width=130,
                    command=self.respawn_defaults_async).pack(side="left", padx=8)
        GhostButton(brow, text="Reset to defaults", width=150,
                    command=self.respawn_reset_async).pack(side="left", padx=8)
        GhostButton(brow, text="--> Fast Forward 3 Days (Clear Corpses) <--", width=340,
                    command=self.respawn_clear_async).pack(side="left", padx=8)

        self.respawn_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.respawn_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED,
                     wraplength=700, justify="left").grid(
            row=3, column=0, columnspan=4, sticky="w", pady=(8, 0))

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
            self.after(0, lambda: (self.app.set_status(res),
                                   self.respawn_var.set(res)))
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
                self.app.set_status("Fast-forward done - full output in the popup."),
                self.respawn_var.set("Full output in the popup."),
                show_probe(self, "Fast Forward 3 Days - copy all of it", res)))
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
            if len(parts) == 2:
                def _ui():
                    self.boss_var.set(parts[0].strip())
                    self.normal_var.set(parts[1].strip())
                    self.respawn_var.set(
                        f"Reset to game defaults: boss {parts[0].strip()}h, "
                        f"normal {parts[1].strip()}h")
                    self.app.set_status("Respawn times reset to game defaults.")
                self.after(0, _ui)
            else:
                self.after(0, lambda: self.app.set_status(f"Error: unexpected response: {res}"))
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
            if len(parts) == 3:
                b, n, d = (p.strip() for p in parts)
                unknown = "?" in (b, n, d)
                msg = (f"Game defaults: boss {b}h, normal {n}h, repop day {d}"
                       + (" — '?' means the game hasn't reported that value yet; "
                          "kill an enemy or rest at camp, then read again." if unknown else ""))
                self.after(0, lambda: (self.app.set_status(msg),
                                       self.respawn_var.set(msg)))
            else:
                self.after(0, lambda: self.app.set_status(f"Error: unexpected response: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    def _do_respawn_read(self, client):
        try:
            res = client.send("respawn_get", timeout=10)
            parts = (res or "").split(",")
            if len(parts) == 2:
                def _ui():
                    self.boss_var.set(parts[0].strip())
                    self.normal_var.set(parts[1].strip())
                    self.respawn_var.set(f"Current: boss {parts[0].strip()}h, normal {parts[1].strip()}h")
                    self.app.set_status("Respawn times read.")
                self.after(0, _ui)
            else:
                self.after(0, lambda: self.app.set_status(f"Error: unexpected response: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))

    # -- movement speed section ------------------------------------------

    def _build_movement(self, body, row):
        H2(body, "Movement Speed", row=row, column=0, sticky="w", pady=(6, 0))
        card = Card(body, row=row + 1, column=0, sticky="ew", padx=4, pady=6)
        cc = card_content(card)

        Muted(cc, "Walk, run and sprint faster — for you and optionally your pawns. "
                  "100% = game default.",
              row=0, column=0, sticky="w", pady=(0, 8))

        self.mv_label_var = ctk.StringVar(value="Movement speed: 100%")
        ctk.CTkLabel(cc, textvariable=self.mv_label_var,
                     font=(T.FONT_FAMILY, 13, "bold"),
                     text_color=T.TEXT).grid(row=1, column=0, sticky="w")
        self.mv_slider = ctk.CTkSlider(
            cc, from_=100, to=300, number_of_steps=200,
            width=700, command=self._on_mv_change,
            fg_color=T.SURFACE2, progress_color=T.ACCENT,
            button_color=T.ACCENT, button_hover_color=T.ACCENT_HOVER)
        self.mv_slider.grid(row=2, column=0, sticky="w", pady=(4, 8))
        self.mv_slider.set(100)

        self.mv_pawns_var = ctk.BooleanVar(value=True)
        Check(cc, text="Apply to pawns too", variable=self.mv_pawns_var,
              command=self._on_mv_toggle).grid(row=3, column=0, sticky="w", pady=(0, 8))

        self.ld_label_var = ctk.StringVar(value="Ladder climbing speed: 100%")
        ctk.CTkLabel(cc, textvariable=self.ld_label_var,
                     font=(T.FONT_FAMILY, 13, "bold"),
                     text_color=T.TEXT).grid(row=4, column=0, sticky="w")
        self.ld_slider = ctk.CTkSlider(
            cc, from_=100, to=300, number_of_steps=200,
            width=700, command=self._on_ld_change,
            fg_color=T.SURFACE2, progress_color=T.ACCENT,
            button_color=T.ACCENT, button_hover_color=T.ACCENT_HOVER)
        self.ld_slider.grid(row=5, column=0, sticky="w", pady=(4, 16))
        self.ld_slider.set(100)

        brow = ctk.CTkFrame(cc, fg_color="transparent")
        brow.grid(row=6, column=0, sticky="w")
        PrimaryButton(brow, text="Apply", width=120,
                      command=self.movespeed_apply_async).pack(side="left", padx=(0, 8))
        GhostButton(brow, text="Read current", width=140,
                    command=self.movespeed_read_async).pack(side="left", padx=8)

        self.mv_info_var = ctk.StringVar(value="")
        ctk.CTkLabel(cc, textvariable=self.mv_info_var,
                     font=(T.FONT_FAMILY, 11), text_color=T.MUTED).grid(
            row=7, column=0, sticky="w", pady=(8, 0))
        self._update_mv_labels()

    def _update_mv_labels(self):
        self.mv_label_var.set(f"Movement speed: {int(self.mv_slider.get())}%")
        self.ld_label_var.set(f"Ladder climbing speed: {int(self.ld_slider.get())}%")

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
        run_async(self, lambda: self._do_movespeed_apply(client, rate, pawns, ladder))

    def _do_movespeed_apply(self, client, rate, pawns, ladder):
        try:
            res = client.send("movespeed_set", rate, pawns, ladder, timeout=15)
            self.after(0, lambda: (self.app.set_status(f"Movement: {res}"),
                                   self.mv_info_var.set(res)))
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
            if len(parts) == 4:
                rate, pawns, ladder, hook = (p.strip() for p in parts)

                def _ui():
                    self.mv_slider.set(_clamp(int(float(rate)), 100, 300))
                    self.ld_slider.set(_clamp(int(float(ladder)), 100, 300))
                    self.mv_pawns_var.set(pawns == "1")
                    self._update_mv_labels()
                    state = f"Movement {rate}%, pawns {'on' if pawns == '1' else 'off'}, " \
                            f"ladder {ladder}% ({hook})"
                    self.mv_info_var.set(state)
                    self.app.set_status("Movement speed read.")
                self.after(0, _ui)
            else:
                self.after(0, lambda: self.app.set_status(f"Error: unexpected response: {res}"))
        except (BridgeError, BridgeTimeout) as e:
            err = f"Error: {e}"
            self.after(0, lambda: self.app.set_status(err))
