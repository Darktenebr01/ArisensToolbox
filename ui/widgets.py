"""Shared UI helpers for Arisen's Toolbox tabs."""
import threading
import tkinter as tk
import customtkinter as ctk

from ui import theme as T

JOB_NAMES = [
    "Fighter", "Archer", "Mage", "Thief", "Warrior", "Sorcerer",
    "Mystic Spearhand", "Magick Archer", "Trickster", "Warfarer",
]
JOB_LABELS = [f"Job{i+1:02d} {n}" for i, n in enumerate(JOB_NAMES)]


def run_async(widget, fn):
    """Run fn() in a daemon thread (for blocking bridge calls)."""
    threading.Thread(target=fn, daemon=True).start()


def require_client(app):
    """Return app.client, or None (with status message) if not connected."""
    if not app.client:
        app.set_status("Not connected - go to the Connection tab first.")
        return None
    return app.client


def Card(parent, **grid_kw):
    """Elevated rounded card for grouping related controls."""
    card = ctk.CTkFrame(parent, fg_color=T.SURFACE, border_color=T.BORDER,
                        border_width=1, corner_radius=10)
    card.grid(**grid_kw)
    return card


def card_content(card, padx=12, pady=10):
    """Inner frame inside a Card with padding, for grid layout."""
    inner = ctk.CTkFrame(card, fg_color="transparent")
    inner.pack(fill="both", expand=True, padx=padx, pady=pady)
    inner.grid_columnconfigure(0, weight=1)
    return inner


def H1(parent, text, **grid_kw):
    lbl = ctk.CTkLabel(parent, **T.h1(text))
    lbl.grid(**grid_kw)
    return lbl


def H2(parent, text, **grid_kw):
    lbl = ctk.CTkLabel(parent, **T.h2(text))
    lbl.grid(**grid_kw)
    return lbl


def Muted(parent, text, **grid_kw):
    lbl = ctk.CTkLabel(parent, **T.muted(text), wraplength=700, justify="left")
    lbl.grid(**grid_kw)
    return lbl


def PrimaryButton(parent, text, command=None, width=140, **kw):
    return ctk.CTkButton(parent, text=text, command=command, width=width,
                         fg_color=T.ACCENT, hover_color=T.ACCENT_HOVER,
                         text_color=T.ACCENT_TEXT,
                         font=(T.FONT_FAMILY, 12, "bold"), corner_radius=8, **kw)


def GhostButton(parent, text, command=None, width=140, **kw):
    return ctk.CTkButton(parent, text=text, command=command, width=width,
                         fg_color=T.SURFACE2, hover_color=T.BORDER,
                         text_color=T.TEXT, border_color=T.BORDER, border_width=1,
                         font=(T.FONT_FAMILY, 12), corner_radius=8, **kw)


def Field(parent, textvariable=None, width=200, **kw):
    return ctk.CTkEntry(parent, textvariable=textvariable, width=width,
                        fg_color=T.BG, border_color=T.BORDER, text_color=T.TEXT,
                        font=(T.FONT_FAMILY, 12), corner_radius=8, **kw)


def Combo(parent, variable=None, values=(), width=200, command=None, **kw):
    return ctk.CTkComboBox(parent, variable=variable, values=values, width=width,
                           command=command, state="readonly",
                           fg_color=T.BG, border_color=T.BORDER, text_color=T.TEXT,
                           button_color=T.SURFACE2, button_hover_color=T.BORDER,
                           dropdown_fg_color=T.SURFACE, dropdown_text_color=T.TEXT,
                           font=(T.FONT_FAMILY, 12), corner_radius=8, **kw)


def Check(parent, text, variable=None, command=None, **kw):
    return ctk.CTkCheckBox(parent, text=text, variable=variable, command=command,
                           fg_color=T.ACCENT, hover_color=T.ACCENT_HOVER,
                           text_color=T.TEXT, border_color=T.BORDER,
                           font=(T.FONT_FAMILY, 12), corner_radius=6, **kw)


def StyledListbox(parent, **kw):
    """tk.Listbox skinned to the theme (fast for hundreds of rows)."""
    lb = tk.Listbox(parent, bg=T.BG, fg=T.TEXT, selectbackground=T.ACCENT_DIM,
                    selectforeground=T.ACCENT, font=(T.FONT_FAMILY, 11),
                    activestyle="none", borderwidth=0, highlightthickness=1,
                    highlightbackground=T.BORDER, highlightcolor=T.ACCENT,
                    relief="flat", **kw)
    return lb


def section_label(parent, text, **grid_kw):
    """Legacy divider — prefer H2 + Card for new layouts."""
    lbl = ctk.CTkLabel(parent, **T.h2(f"----- {text} -----"))
    lbl.grid(**grid_kw)
    return lbl


class ProbeDialog(ctk.CTkToplevel):
    """Popup showing bulk text (dump/probe output) with a copy button."""

    def __init__(self, parent, title, text):
        super().__init__(parent)
        self.title(title)
        self.geometry("900x600")
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)

        self.textbox = ctk.CTkTextbox(self, font=("Consolas", 11), wrap="none")
        self.textbox.grid(row=0, column=0, sticky="nsew", padx=8, pady=8)
        self.textbox.insert("1.0", text)
        self.textbox.configure(state="disabled")

        btn = ctk.CTkButton(self, text="Copy to clipboard", command=self._copy)
        btn.grid(row=1, column=0, sticky="ew", padx=8, pady=(0, 8))
        self._text = text

    def _copy(self):
        self.clipboard_clear()
        self.clipboard_append(self._text)


def show_probe(parent, title, text):
    ProbeDialog(parent, title, text)
