"""Shared UI building blocks.

Tabs build screens out of these primitives - PageHeader, Section, ListPanel,
buttons, fields - so spacing, colour and type stay consistent everywhere.
"""
import logging
import threading
import tkinter as tk

import customtkinter as ctk

from ui import theme as T

log = logging.getLogger("arisens.async")

JOB_NAMES = [
    "Fighter", "Archer", "Mage", "Thief", "Warrior", "Sorcerer",
    "Mystic Spearhand", "Magick Archer", "Trickster", "Warfarer",
]
JOB_LABELS = [f"{n}" for n in JOB_NAMES]  # values shown in the vocation picker


# -- threading ---------------------------------------------------------

def run_async(widget, fn):
    """Run fn() on a daemon thread; surface unexpected failures."""
    def _runner():
        try:
            fn()
        except Exception:
            log.exception("background task failed")
            app = getattr(widget, "app", None)
            if app is None and hasattr(widget, "call_soon"):
                app = widget
            if app is not None:
                app.call_soon(app.set_status,
                              "Something went wrong - see the log file.")

    threading.Thread(target=_runner, daemon=True,
                     name="bridge-task").start()


def require_client(app):
    """Return app.client, or None (with a status message) when offline."""
    if not app.client:
        app.set_status("Not connected - open Connection and press Start.")
        return None
    return app.client


def dev_only(tab, factory):
    """Build a probe/diagnostic widget only in dev mode."""
    if getattr(getattr(tab, "app", None), "dev_mode", False):
        return factory()
    return None


# -- text helpers ------------------------------------------------------

def _wrap(label, parent, pad=40):
    """Keep a label's wraplength in step with its container."""
    def _resize(event):
        width = event.width - pad
        if width > 120:
            label.configure(wraplength=width)
    parent.bind("<Configure>", _resize, add="+")


def caption(parent, text, **grid_kw):
    """Small muted paragraph under a heading."""
    label = ctk.CTkLabel(parent, text=text, font=T.font(T.SIZE_SMALL),
                         text_color=T.MUTED, anchor="w", justify="left")
    label.grid(**grid_kw)
    _wrap(label, parent)
    return label


def divider(parent, **grid_kw):
    line = tk.Frame(parent, height=1, bg=T.BORDER, bd=0,
                    highlightthickness=0)
    line.grid(**grid_kw)
    return line


# -- layout ------------------------------------------------------------

def _parent_bg(widget, fallback=T.BG):
    """Resolve the effective background colour behind a layout container."""
    node = widget
    for _ in range(8):
        try:
            fg = node.cget("fg_color")
        except Exception:
            fg = None
        if isinstance(fg, (tuple, list)):
            fg = fg[0]
        if fg and fg != "transparent":
            return fg
        node = getattr(node, "master", None)
        if node is None:
            break
    return fallback


def Frame(parent, bg=None, **kw):
    """Plain layout frame - no canvas, so building a screen stays cheap."""
    kw.pop("fg_color", None)
    kw.setdefault("bd", 0)
    kw.setdefault("highlightthickness", 0)
    return tk.Frame(parent, bg=bg or _parent_bg(parent), **kw)


class PageHeader(tk.Frame):
    """Screen title, one-line description, optional right-aligned actions."""

    def __init__(self, parent, title, subtitle=None):
        super().__init__(parent, bg=_parent_bg(parent), bd=0,
                         highlightthickness=0)
        self.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(self, text=title, font=T.font(T.SIZE_DISPLAY, "bold"),
                     text_color=T.TEXT, anchor="w").grid(
            row=0, column=0, sticky="w")
        if subtitle:
            sub = ctk.CTkLabel(self, text=subtitle,
                               font=T.font(T.SIZE_BODY), text_color=T.MUTED,
                               anchor="w", justify="left")
            sub.grid(row=1, column=0, sticky="w", pady=(3, 0))
            _wrap(sub, self)
        self.actions = Frame(self)
        self.actions.grid(row=0, column=1, rowspan=2, sticky="e",
                          padx=(16, 0))

    def action(self, widget, pad=(8, 0)):
        widget.pack(side="left", padx=pad)
        return widget


class Section(ctk.CTkFrame):
    """A bordered panel with an optional title, hint and header actions."""

    def __init__(self, parent, title=None, hint=None, **grid_kw):
        super().__init__(parent, fg_color=T.SURFACE, border_color=T.BORDER,
                         border_width=1, corner_radius=T.RADIUS_CARD,
                         width=1, height=1)
        if grid_kw:
            self.grid(**grid_kw)
        self.grid_columnconfigure(0, weight=1)
        row = 0
        self.header_actions = None
        if title:
            head = Frame(self, bg=T.SURFACE)
            head.grid(row=row, column=0, sticky="ew", padx=T.PAD_L,
                      pady=(T.PAD_M + 2, 0))
            head.grid_columnconfigure(0, weight=1)
            ctk.CTkLabel(head, text=title,
                         font=T.font(T.SIZE_SECTION, "bold"),
                         text_color=T.TEXT, anchor="w").grid(
                row=0, column=0, sticky="w")
            self.header_actions = Frame(head, bg=T.SURFACE)
            self.header_actions.grid(row=0, column=1, sticky="e")
            row += 1
        if hint:
            hint_label = ctk.CTkLabel(self, text=hint,
                                      font=T.font(T.SIZE_SMALL),
                                      text_color=T.MUTED, anchor="w",
                                      justify="left")
            hint_label.grid(row=row, column=0, sticky="ew", padx=T.PAD_L,
                            pady=(2, 0))
            _wrap(hint_label, self, pad=T.PAD_L * 2)
            row += 1
        self.body = Frame(self, bg=T.SURFACE)
        self.body.grid(row=row, column=0, sticky="nsew", padx=T.PAD_L,
                       pady=(T.PAD_M, T.PAD_M + 2))
        self.body.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(row, weight=1)

    def action(self, widget, pad=(8, 0)):
        widget.pack(side="left", padx=pad)
        return widget


class SlimScrollbar(tk.Canvas):
    """A 10 px rounded scrollbar that does not redraw the whole window.

    CustomTkinter's CTkScrollbar calls ``update_idletasks`` on every draw,
    which flushes every pending canvas redraw and made the first build of a
    tab cost up to a second. This one only redraws its own thumb.
    """

    def __init__(self, parent, command=None, orientation="vertical",
                 trough=T.BG, thumb=T.SURFACE3, hover=T.BORDER_STRONG,
                 width=10, **kwargs):
        super().__init__(parent, width=width, bd=0, highlightthickness=0,
                         bg=trough, cursor="hand2")
        self._command = command
        self._orientation = orientation
        self._thumb_color = thumb
        self._hover_color = hover
        self._first = 0.0
        self._last = 1.0
        self._drag = None
        self._hovering = False
        self._pad = 6
        self._line = self.create_line(0, 0, 0, 0, width=6,
                                      capstyle="round", fill=thumb)
        self.bind("<Configure>", lambda _e: self._redraw())
        self.bind("<Button-1>", self._on_press)
        self.bind("<B1-Motion>", self._on_drag)
        self.bind("<ButtonRelease-1>", self._on_release)
        self.bind("<Enter>", lambda _e: self._set_hover(True))
        self.bind("<Leave>", lambda _e: self._set_hover(False))
        self.bind("<MouseWheel>", self._on_wheel)

    # -- scrollbar protocol ------------------------------------------

    def set(self, first, last):
        try:
            self._first, self._last = float(first), float(last)
        except (TypeError, ValueError):
            return
        self._redraw()

    def get(self):
        return self._first, self._last

    # -- drawing ------------------------------------------------------

    def _track(self):
        if self._orientation == "horizontal":
            total = self.winfo_width()
        else:
            total = self.winfo_height()
        return self._pad, max(self._pad + 1, total - self._pad)

    def _redraw(self):
        lo, hi = self._track()
        span = max(0.0, min(1.0, self._last - self._first))
        if span >= 0.999:
            self.itemconfigure(self._line, state="hidden")
            return
        self.itemconfigure(self._line, state="normal")
        length = hi - lo
        thumb = max(18, int(length * span))
        start = lo + int((length - thumb) * (self._first / max(1e-6, 1 - span)))
        color = self._hover_color if self._hovering else self._thumb_color
        if self._orientation == "horizontal":
            self.coords(self._line, start, self.winfo_height() / 2,
                        start + thumb, self.winfo_height() / 2)
        else:
            cx = self.winfo_width() / 2
            self.coords(self._line, cx, start, cx, start + thumb)
        self.itemconfigure(self._line, fill=color)

    def _set_hover(self, hovering):
        self._hovering = hovering
        self._redraw()

    # -- interaction --------------------------------------------------

    def _fraction_at(self, event):
        lo, hi = self._track()
        pos = event.x if self._orientation == "horizontal" else event.y
        return max(0.0, min(1.0, (pos - lo) / max(1, hi - lo)))

    def _on_press(self, event):
        frac = self._fraction_at(event)
        span = max(0.01, self._last - self._first)
        if self._first <= frac <= self._last:
            self._drag = (frac - self._first, frac)
        else:
            self._novement(frac - span / 2)
            self._drag = (0.0, frac)

    def _on_drag(self, event):
        if self._drag is None:
            return
        delta = self._fraction_at(event) - self._drag[1]
        self._novement(self._first + delta)

    def _on_release(self, _event):
        self._drag = None

    def _on_wheel(self, event):
        if self._command is None:
            return
        step = -1 if event.delta > 0 else 1
        self._command("scroll", step * 3, "units")

    def _novement(self, start):
        if self._command is None:
            return
        self._command("moveto", max(0.0, min(1.0, start)))

    # -- compatibility with CTkScrollbar config keys ------------------
    def configure(self, **kwargs):
        for key in ("button_color", "button_hover_color", "fg_color",
                    "border_spacing", "corner_radius"):
            value = kwargs.pop(key, None)
            if key == "button_color" and value:
                self._thumb_color = value
            elif key == "button_hover_color" and value:
                self._hover_color = value
            elif key == "fg_color" and value not in (None, "transparent"):
                kwargs["bg"] = value
        if kwargs:
            super().configure(**kwargs)
        self._redraw()


class ScrollArea(ctk.CTkScrollableFrame):
    """Themed scrolling body for screens that outgrow the window."""

    def __init__(self, parent, trough=T.BG, **kw):
        kw.setdefault("fg_color", "transparent")
        kw.setdefault("corner_radius", 0)
        # Swap CustomTkinter's scrollbar class for the cheap one just for
        # this construction, so the expensive widget is never created.
        factory = None
        module = None
        try:
            from customtkinter.windows.widgets import (
                ctk_scrollable_frame as module,
            )
            original = module.CTkScrollbar
        except Exception:
            module = None
            original = None

        def factory(master, command=None, orientation="vertical",
                    fg_color=None, button_color=None,
                    button_hover_color=None, **_ignored):
            return SlimScrollbar(
                master, command=command, orientation=orientation,
                trough=trough,
                thumb=button_color or T.SURFACE3,
                hover=button_hover_color or T.BORDER_STRONG)

        if module is not None:
            module.CTkScrollbar = factory
        try:
            super().__init__(parent, **kw)
        finally:
            if module is not None:
                module.CTkScrollbar = original
        self.grid_columnconfigure(0, weight=1)


class Row(tk.Frame):
    """Horizontal control cluster. Children are packed, one manager only."""

    def __init__(self, parent, tight=False, **grid_kw):
        super().__init__(parent, bg=_parent_bg(parent), bd=0,
                         highlightthickness=0)
        if grid_kw:
            self.grid(**grid_kw)
        self._gap = T.PAD_S if tight else T.PAD_M

    def add(self, widget, gap=None):
        widget.pack(side="left", padx=(0, self._gap if gap is None else gap))
        return widget

    def add_right(self, widget, gap=None):
        widget.pack(side="right", padx=(self._gap if gap is None else gap, 0))
        return widget

    def spacer(self, weight=1):
        Frame(self).pack(side="left", fill="x", expand=bool(weight))
        return self


def field_row(parent, label, control, hint=None, row=0, label_width=130):
    """``label   control`` on one grid row, with an optional inline hint."""
    ctk.CTkLabel(parent, text=label, font=T.font(T.SIZE_BODY),
                 text_color=T.TEXT_SOFT, anchor="w", width=label_width).grid(
        row=row, column=0, sticky="w", pady=T.PAD_XS)
    control.grid(row=row, column=1, sticky="w", padx=(T.PAD_S, 0),
                 pady=T.PAD_XS)
    if hint:
        ctk.CTkLabel(parent, text=hint, font=T.font(T.SIZE_SMALL),
                     text_color=T.MUTED, anchor="w").grid(
            row=row, column=2, sticky="w", padx=(T.PAD_M, 0))
    return control


# -- controls ----------------------------------------------------------

HEIGHT = T.CONTROL_HEIGHT


def PrimaryButton(parent, text, command=None, width=120, **kw):
    return ctk.CTkButton(
        parent, text=text, command=command, width=width, height=HEIGHT,
        fg_color=T.ACCENT, hover_color=T.ACCENT_HOVER,
        text_color=T.ACCENT_TEXT, font=T.font(T.SIZE_BODY, "bold"),
        corner_radius=T.RADIUS_CONTROL, **kw)


def GhostButton(parent, text, command=None, width=120, **kw):
    return ctk.CTkButton(
        parent, text=text, command=command, width=width, height=HEIGHT,
        fg_color="transparent", hover_color=T.SURFACE2,
        text_color=T.TEXT_SOFT, font=T.font(T.SIZE_BODY),
        border_width=1, border_color=T.BORDER,
        corner_radius=T.RADIUS_CONTROL, **kw)


def QuietButton(parent, text, command=None, width=100, **kw):
    """Borderless text button for secondary actions inside dense rows."""
    return ctk.CTkButton(
        parent, text=text, command=command, width=width, height=HEIGHT,
        fg_color="transparent", hover_color=T.SURFACE2,
        text_color=T.TEXT_SOFT, font=T.font(T.SIZE_BODY),
        corner_radius=T.RADIUS_CONTROL, **kw)


def DangerButton(parent, text, command=None, width=120, **kw):
    return ctk.CTkButton(
        parent, text=text, command=command, width=width, height=HEIGHT,
        fg_color="transparent", hover_color=T.DANGER_DIM,
        text_color=T.DANGER, font=T.font(T.SIZE_BODY),
        border_width=1, border_color=T.DANGER_DIM,
        corner_radius=T.RADIUS_CONTROL, **kw)


def Field(parent, textvariable=None, width=200, **kw):
    kw.setdefault("placeholder_text", "")
    return ctk.CTkEntry(
        parent, textvariable=textvariable, width=width, height=HEIGHT,
        fg_color=T.OVERLAY, border_color=T.BORDER, text_color=T.TEXT,
        placeholder_text_color=T.FAINT, font=T.font(T.SIZE_BODY),
        corner_radius=T.RADIUS_CONTROL, **kw)


def Combo(parent, variable=None, values=(), width=200, command=None, **kw):
    return ctk.CTkComboBox(
        parent, variable=variable, values=list(values) or [""], width=width,
        command=command, state="readonly", height=HEIGHT,
        fg_color=T.OVERLAY, border_color=T.BORDER, text_color=T.TEXT,
        button_color=T.SURFACE2, button_hover_color=T.SURFACE3,
        dropdown_fg_color=T.SURFACE2, dropdown_text_color=T.TEXT,
        dropdown_hover_color=T.SURFACE3,
        font=T.font(T.SIZE_BODY), dropdown_font=T.font(T.SIZE_BODY),
        corner_radius=T.RADIUS_CONTROL, **kw)


def Check(parent, text, variable=None, command=None, **kw):
    return ctk.CTkCheckBox(
        parent, text=text, variable=variable, command=command,
        fg_color=T.ACCENT, hover_color=T.ACCENT_HOVER,
        text_color=T.TEXT_SOFT, font=T.font(T.SIZE_BODY),
        border_color=T.BORDER_STRONG, checkmark_color=T.ACCENT_TEXT,
        corner_radius=T.RADIUS_CONTROL - 3, **kw)


def Switch(parent, text, variable=None, command=None, **kw):
    return ctk.CTkSwitch(
        parent, text=text, variable=variable, command=command,
        fg_color=T.SURFACE3, progress_color=T.ACCENT,
        button_color=T.TEXT_SOFT, button_hover_color=T.TEXT,
        text_color=T.TEXT_SOFT, font=T.font(T.SIZE_BODY),
        **kw)


def Slider(parent, from_=0, to=100, command=None, width=520, **kw):
    return ctk.CTkSlider(
        parent, from_=from_, to=to, command=command, width=width,
        height=18, fg_color=T.SURFACE3, progress_color=T.ACCENT,
        button_color=T.ACCENT, button_hover_color=T.ACCENT_HOVER,
        **kw)


# -- lists -------------------------------------------------------------

def StyledListbox(parent, **kw):
    """tk.Listbox skinned to the theme (fast enough for thousands of rows)."""
    kw.setdefault("font", T.font(T.SIZE_BODY))
    kw.setdefault("height", 10)
    return tk.Listbox(
        parent, bg=T.OVERLAY, fg=T.TEXT_SOFT, selectbackground=T.ACCENT_DIM,
        selectforeground=T.ACCENT,
        activestyle="none", borderwidth=0, highlightthickness=0,
        relief="flat", selectborderwidth=0, exportselection=False,
        **kw)


def ListPanel(parent, height=10, empty="Nothing to show yet.", **grid_kw):
    """Bordered list well: listbox + rounded scrollbar + empty state."""
    panel = ctk.CTkFrame(parent, fg_color=T.OVERLAY,
                         border_color=T.BORDER, border_width=1,
                         corner_radius=T.RADIUS_CARD - 2, width=1, height=1)
    if grid_kw:
        panel.grid(**grid_kw)
    panel.grid_columnconfigure(0, weight=1)
    panel.grid_rowconfigure(0, weight=1)
    panel.listbox = StyledListbox(panel, height=height)
    panel.listbox.grid(row=0, column=0, sticky="nsew",
                       padx=(T.PAD_S + 2, 2), pady=T.PAD_S)
    panel.scrollbar = SlimScrollbar(
        panel, command=panel.listbox.yview, width=10,
        trough=T.OVERLAY, thumb=T.SURFACE3, hover=T.BORDER_STRONG)
    panel.scrollbar.grid(row=0, column=1, sticky="ns",
                         pady=T.PAD_S, padx=(0, 4))

    # Forward only changed fractions, and bind after the first layout pass:
    # a tab spends its first frame settling, so forwarding every transient
    # yscroll call used to cost a full redraw each time.
    last_fraction = [None]

    def _on_scroll(first, last):
        if last_fraction[0] == (first, last):
            return
        last_fraction[0] = (first, last)
        panel.scrollbar.set(first, last)

    def _bind_scroll():
        try:
            panel.listbox.configure(yscrollcommand=_on_scroll)
        except Exception:
            pass

    panel.after_idle(_bind_scroll)
    panel._empty = ctk.CTkLabel(
        panel, text=empty, font=T.font(T.SIZE_BODY), text_color=T.FAINT,
        justify="center")
    panel._empty.place(relx=0.5, rely=0.5, anchor="center")
    panel._empty_shown = True

    def set_rows(rows):
        panel.listbox.delete(0, tk.END)
        if rows:
            panel.listbox.insert(tk.END, *rows)
        sync_empty()

    def sync_empty():
        """Show the empty-state label only when the list is actually empty.

        Guarded on the current state: re-placing the label on every
        <Configure> event makes Tk re-lay-out forever, which used to add
        seconds to tab construction.
        """
        try:
            show = panel.listbox.size() == 0
            if show == panel._empty_shown:
                return
            panel._empty_shown = show
            if show:
                panel._empty.place(relx=0.5, rely=0.5, anchor="center")
                panel._empty.lift()
            else:
                panel._empty.place_forget()
        except Exception:
            pass

    panel.listbox.bind("<Configure>", lambda _e: sync_empty(), add="+")
    def set_empty(text):
        panel._empty.configure(text=text)

    panel.set_rows = set_rows
    panel.sync_empty = sync_empty
    panel.set_empty = set_empty
    return panel


class Segmented(ctk.CTkFrame):
    """Two or three mutually exclusive choices, with a clearly lit selection."""

    def __init__(self, parent, values, variable, command=None, width=None):
        super().__init__(parent, fg_color=T.SURFACE2, corner_radius=8,
                         border_width=1, border_color=T.BORDER,
                         width=width or 32 * len(values), height=HEIGHT)
        self._var = variable
        self._command = command
        self._buttons = {}
        for i, value in enumerate(values):
            btn = ctk.CTkButton(
                self, text=value, height=HEIGHT - 6, width=1,
                corner_radius=5, fg_color="transparent",
                hover_color=T.SURFACE3, text_color=T.MUTED,
                font=T.font(T.SIZE_BODY),
                command=lambda v=value: self._select(v))
            btn.pack(side="left", fill="x", expand=True, padx=3, pady=3)
            self._buttons[value] = btn
        self._var.trace_add("write", lambda *_: self._paint())
        self._paint()

    def _select(self, value):
        self._var.set(value)
        if self._command is not None:
            self._command(value)

    def _paint(self):
        current = self._var.get()
        for value, btn in self._buttons.items():
            active = value == current
            btn.configure(
                fg_color=T.ACCENT_DIM if active else "transparent",
                text_color=T.ACCENT if active else T.MUTED,
                font=T.font(T.SIZE_BODY, "bold") if active
                else T.font(T.SIZE_BODY))


class Pill(ctk.CTkFrame):
    """Small status chip: coloured dot + label."""

    def __init__(self, parent, text="Offline", tone="muted"):
        super().__init__(parent, fg_color=T.SURFACE2, corner_radius=999,
                         border_width=1, border_color=T.BORDER,
                         width=1, height=1)
        self._dot = ctk.CTkLabel(self, text="●", width=12,
                                 font=T.font(T.SIZE_SMALL),
                                 text_color=T.FAINT)
        self._dot.pack(side="left", padx=(9, 0), pady=3)
        self._label = ctk.CTkLabel(self, text=text, font=T.font(T.SIZE_MICRO),
                                   text_color=T.MUTED)
        self._label.pack(side="left", padx=(5, 10), pady=3)
        self.set(text, tone)

    def set(self, text, tone="muted"):
        dots = {"ok": T.SUCCESS, "warn": T.WARNING, "bad": T.DANGER,
                "accent": T.ACCENT, "muted": T.FAINT}
        texts = {"ok": T.SUCCESS, "warn": T.TEXT, "bad": T.DANGER,
                 "accent": T.ACCENT, "muted": T.MUTED}
        fg = {"ok": T.SUCCESS_DIM, "bad": T.DANGER_DIM}.get(tone, T.SURFACE2)
        border = (T.SUCCESS_DIM if tone == "ok" else
                  T.DANGER_DIM if tone == "bad" else T.BORDER)
        self.configure(fg_color=fg, border_color=border)
        self._dot.configure(text_color=dots.get(tone, T.FAINT))
        self._label.configure(text=text,
                              text_color=texts.get(tone, T.MUTED))


# -- legacy shims (still used by a few tabs) ---------------------------

def Card(parent, **grid_kw):
    return Section(parent, **grid_kw)


def card_content(card, padx=0, pady=0):
    """Inner frame of a Card/Section, kept for older call sites."""
    return card.body


def H1(parent, text, **grid_kw):
    label = ctk.CTkLabel(parent, **T.h1(text), anchor="w")
    label.grid(**grid_kw)
    return label


def H2(parent, text, **grid_kw):
    label = ctk.CTkLabel(parent, **T.h2(text), anchor="w")
    label.grid(**grid_kw)
    return label


def Muted(parent, text, **grid_kw):
    label = ctk.CTkLabel(parent, **T.muted(text), anchor="w", justify="left",
                         wraplength=760)
    label.grid(**grid_kw)
    _wrap(label, parent)
    return label


def section_label(parent, text, **grid_kw):
    label = ctk.CTkLabel(parent, text=text.upper(),
                         font=T.font(T.SIZE_MICRO, "bold"),
                         text_color=T.FAINT, anchor="w")
    label.grid(**grid_kw)
    return label


# -- overlays ----------------------------------------------------------

class Tooltip:
    """Small hover tooltip for destructive or save-writing actions."""

    def __init__(self, widget, text, delay_ms=500):
        self.widget = widget
        self.text = text
        self.delay_ms = delay_ms
        self._after_id = None
        self._tip = None
        widget.bind("<Enter>", self._schedule, add="+")
        widget.bind("<Leave>", self._hide, add="+")
        widget.bind("<ButtonPress>", self._hide, add="+")

    def _schedule(self, _event=None):
        self._after_id = self.widget.after(self.delay_ms, self._show)

    def _show(self):
        if self._tip is not None:
            return
        try:
            x = self.widget.winfo_rootx() + 10
            y = self.widget.winfo_rooty() + self.widget.winfo_height() + 6
        except Exception:
            return
        tip = tk.Toplevel(self.widget)
        tip.wm_overrideredirect(True)
        tip.wm_geometry(f"+{x}+{y}")
        tk.Label(tip, text=self.text, justify="left", wraplength=300,
                 background=T.SURFACE3, foreground=T.TEXT_SOFT,
                 font=T.font(T.SIZE_SMALL), padx=10, pady=6,
                 relief="flat", borderwidth=0).pack()
        self._tip = tip

    def _hide(self, _event=None):
        if self._after_id is not None:
            try:
                self.widget.after_cancel(self._after_id)
            except Exception:
                pass
            self._after_id = None
        if self._tip is not None:
            self._tip.destroy()
            self._tip = None


class ProbeDialog(ctk.CTkToplevel):
    """Popup showing bulk text (dump/probe output) with a copy button."""

    def __init__(self, parent, title, text):
        super().__init__(parent)
        self.title(title)
        self.geometry("920x620")
        self.configure(fg_color=T.BG)
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)
        self._text = text

        header = Frame(self)
        header.grid(row=0, column=0, sticky="ew", padx=T.PAD_L,
                    pady=(T.PAD_M, T.PAD_S))
        header.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(header, text=title, font=T.font(T.SIZE_TITLE, "bold"),
                     text_color=T.TEXT, anchor="w").grid(
            row=0, column=0, sticky="w")

        self.textbox = ctk.CTkTextbox(
            self, font=T.mono(T.SIZE_SMALL), wrap="none",
            fg_color=T.OVERLAY, text_color=T.TEXT_SOFT,
            border_color=T.BORDER, border_width=1,
            corner_radius=T.RADIUS_CARD, scrollbar_button_color=T.SURFACE3,
            scrollbar_button_hover_color=T.BORDER_STRONG)
        self.textbox.grid(row=1, column=0, sticky="nsew",
                          padx=T.PAD_L, pady=(0, T.PAD_S))
        self.textbox.insert("1.0", text)
        self.textbox.configure(state="disabled")

        footer = Frame(self)
        footer.grid(row=2, column=0, sticky="ew", padx=T.PAD_L,
                    pady=(0, T.PAD_L))
        footer.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(footer, text=f"{len(text.splitlines())} lines",
                     font=T.font(T.SIZE_SMALL), text_color=T.MUTED).grid(
            row=0, column=0, sticky="w")
        GhostButton(footer, text="Close", width=90,
                    command=self.destroy).grid(row=0, column=1, padx=(0, 8))
        PrimaryButton(footer, text="Copy all", width=110,
                      command=self._copy).grid(row=0, column=2)

    def _copy(self):
        self.clipboard_clear()
        self.clipboard_append(self._text)


def show_probe(parent, title, text):
    return ProbeDialog(parent, title, text)
