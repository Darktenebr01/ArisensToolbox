"""Arisen's Toolbox visual theme — dark fantasy: warm charcoal + antique gold."""

# surfaces
BG = "#14110c"            # app background, warm near-black
SURFACE = "#1e1a13"       # cards
SURFACE2 = "#282219"      # elevated / hover
BORDER = "#3a3122"        # card borders
SIDEBAR_BG = "#171310"

# text
TEXT = "#ece4d3"          # parchment white
MUTED = "#a2987f"         # dim labels
FAINT = "#6e6656"

# accent
ACCENT = "#c9a227"        # antique gold
ACCENT_HOVER = "#ddb93a"
ACCENT_DIM = "#5c4d1f"    # gold-tinted surface for selections
ACCENT_TEXT = "#171204"   # dark text on gold buttons

# states
DANGER = "#c0574a"
SUCCESS = "#6fae7e"

FONT_FAMILY = "Segoe UI"  # Windows default; falls back gracefully elsewhere


def h1(text):
    return {"text": text, "font": (FONT_FAMILY, 20, "bold"), "text_color": TEXT}


def h2(text):
    return {"text": text, "font": (FONT_FAMILY, 13, "bold"), "text_color": ACCENT}


def body(text):
    return {"text": text, "font": (FONT_FAMILY, 12), "text_color": TEXT}


def muted(text):
    return {"text": text, "font": (FONT_FAMILY, 11), "text_color": MUTED}
