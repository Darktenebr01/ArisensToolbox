"""Design tokens for Arisen's Toolbox.

One neutral ramp, one accent, one type scale. Tabs compose these through
``ui.widgets`` instead of picking colours and font sizes by hand, which is
what keeps every screen looking like the same application.
"""
import tkinter.font as tkfont

# --- surfaces ---------------------------------------------------------
BG = "#0d0e10"            # window / content background
SIDEBAR = "#0a0b0c"       # navigation rail
SIDEBAR_BG = SIDEBAR      # legacy alias
SURFACE = "#141619"       # cards, panels
SURFACE2 = "#1a1d21"      # inputs, hovered rows
SURFACE3 = "#22262c"      # raised control, scrollbar thumb
BORDER = "#262b31"        # hairline separators
BORDER_STRONG = "#343b44"  # focus / hover outlines
OVERLAY = "#101214"       # list wells

# --- text -------------------------------------------------------------
TEXT = "#e9ebee"          # primary
TEXT_SOFT = "#c3c8ce"     # secondary
MUTED = "#8b929b"         # hints, captions
FAINT = "#5f666e"         # disabled, category labels

# --- accent -----------------------------------------------------------
ACCENT = "#e3a84a"        # warm amber - the only saturated colour
ACCENT_HOVER = "#f2bc63"
ACCENT_PRESS = "#c98f34"
ACCENT_TEXT = "#17120a"   # text on amber
ACCENT_DIM = "#2a2115"    # selected nav / row tint
ACCENT_SOFT = "#3a2d1a"   # border on selected rows

# --- state ------------------------------------------------------------
DANGER = "#e2756a"
DANGER_DIM = "#3a201e"
SUCCESS = "#68c08d"
SUCCESS_DIM = "#173327"
WARNING = "#e3a84a"

# --- type -------------------------------------------------------------
FONT_FAMILY = "Segoe UI"  # replaced by init() with the best installed face
MONO_FAMILY = "Consolas"
SIZE_DISPLAY = 24
SIZE_TITLE = 18
SIZE_SECTION = 13
SIZE_BODY = 12
SIZE_SMALL = 11
SIZE_MICRO = 10

# --- geometry ---------------------------------------------------------
RADIUS_CARD = 10
RADIUS_CONTROL = 7
SIDEBAR_WIDTH = 232
CONTROL_HEIGHT = 32
PAD_XS, PAD_S, PAD_M, PAD_L, PAD_XL = 4, 8, 12, 16, 24


def init(root=None):
    """Pick the best available UI font once a Tk root exists."""
    global FONT_FAMILY
    if root is None:
        return FONT_FAMILY
    try:
        available = set(tkfont.families(root))
    except Exception:
        return FONT_FAMILY
    for candidate in ("Segoe UI Variable Text", "Segoe UI", "Inter",
                      "Noto Sans", "Helvetica Neue", "Arial"):
        if candidate in available:
            FONT_FAMILY = candidate
            break
    return FONT_FAMILY


def font(size=SIZE_BODY, weight="normal", family=None):
    return (family or FONT_FAMILY, size, weight)


def mono(size=SIZE_SMALL):
    return (MONO_FAMILY, size)


# --- role helpers (text -> widget kwargs) -----------------------------
def display(text):
    return {"text": text, "font": font(SIZE_DISPLAY, "bold"), "text_color": TEXT}


def h1(text):
    return {"text": text, "font": font(SIZE_TITLE, "bold"), "text_color": TEXT}


def h2(text):
    return {"text": text, "font": font(SIZE_SECTION, "bold"), "text_color": TEXT}


def body(text):
    return {"text": text, "font": font(SIZE_BODY), "text_color": TEXT}


def muted(text):
    return {"text": text, "font": font(SIZE_SMALL), "text_color": MUTED}
