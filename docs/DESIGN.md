# Design notes

The interface is built from a small set of tokens and components. Screens
compose those instead of choosing colours, fonts and paddings locally, which
is what keeps the app coherent as features are added.

## Principles

1. **One accent.** Amber marks the primary action, the selected navigation
   row and the active target. Nothing else is saturated.
2. **Quiet surfaces.** Cards are one step lighter than the window, separated
   by a hairline border, with generous inner padding. No shadows, gradients
   or decorative dividers.
3. **Type carries hierarchy.** A page title, a section title, body text and a
   caption. Sizes are fixed; weight and colour do the rest.
4. **Actions are ranked.** One amber primary button per area, bordered
   secondary buttons for alternatives, borderless quiet buttons for tertiary
   actions.
5. **Short copy.** A hint is one line under a section heading. Long
   explanation belongs in the README or a tooltip, not on screen.

## Tokens

`ui/theme.py` is the only place colours and type sizes are defined.

| Token | Value | Use |
| --- | --- | --- |
| `BG` | `#0d0e10` | window background |
| `SIDEBAR` | `#0a0b0c` | navigation rail |
| `SURFACE` | `#141619` | cards and panels |
| `SURFACE2` | `#1a1d21` | inputs, hover |
| `OVERLAY` | `#101214` | list wells |
| `BORDER` | `#262b31` | hairline borders |
| `TEXT` | `#e9ebee` | primary text |
| `MUTED` | `#8b929b` | hints and captions |
| `ACCENT` | `#e3a84a` | primary action, selection |
| `DANGER` / `SUCCESS` | `#e2756a` / `#68c08d` | state only |

Type scale: 24 display, 18 title, 13 section, 12 body, 11 small, 10 micro.
`Segoe UI Variable Text` is used when installed, otherwise `Segoe UI`.

Spacing scale: 4, 8, 12, 16, 24. Cards use 16 px inner padding and 12 px gaps.
Corner radii: 10 px for cards, 7 px for controls.

## Components

`ui/widgets.py` provides the shared pieces:

- `PageHeader`: title, one-line description, right-aligned actions.
- `Section`: bordered card with optional title, hint and header actions; the
  inner `body` is where controls go.
- `Row`: horizontal cluster of controls with consistent gaps.
- `ListPanel`: dark list well with a slim scrollbar and an empty state.
- `Field`, `Combo`, `Check`, `Switch`, `Slider`, buttons: themed controls with
  one height and radius.
- `Pill`, `Segmented`: status chip and the target switch.
- `Tooltip`, `ProbeDialog`: overlays for destructive actions and dump output.

Layout containers use plain `tk.Frame` via `widgets.Frame`. CustomTkinter
frames draw a canvas each; a screen with dozens of them was slow to build, and
plain frames are invisible in the layout while keeping construction cheap.

## Lists

`ListPanel` fills its listbox in one bulk call. Searching is debounced by
140 ms. Empty states are toggled only when the row count actually changes:
re-placing the empty label on every resize event used to make Tk re-layout in
a loop and cost seconds per tab.

Scrollbars are a small canvas (`SlimScrollbar`) rather than
`CTkScrollbar`, because the latter calls `update_idletasks` on every draw and
forces a full-window redraw.

## Layout

- Navigation rail: 232 px, brand at the top, categories in 10 px uppercase,
  active row tinted with a 3 px amber bar and amber label.
- Command bar: 64 px, one row. Target segmented control, vocation picker, pawn
  picker, then Undo / Use current / Set vocation.
- Content: 24 px horizontal padding, page header, then sections. Screens that
  can outgrow the window scroll as a whole; screens built around a list keep
  the header fixed and let the list take the remaining height.
- Status bar: 30 px, connection pill on the left, one-line status, versions on
  the right.

## Adding a screen

1. Subclass `BaseTab`.
2. Add `PageHeader` on row 0 and a `ScrollArea` on row 1 if the content can
   grow.
3. Build `Section` cards inside it; put controls in `section.body` with grid.
4. Put horizontal groups in `Row` (which packs) and never mix `pack` and
   `grid` in the same parent.
5. Use `run_async` for bridge calls and deliver results with
   `self.after(0, ...)`, which `BaseTab` marshals onto the main thread.
6. Register the tab in `TABS` in `ui/app.py`.

Probe and diagnostic buttons stay behind `dev_only(...)` so the normal UI does
not turn into a laboratory console.
