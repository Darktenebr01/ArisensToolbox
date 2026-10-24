# Accessibility

Arisen's Toolbox is a Windows desktop app built with CustomTkinter. It is
operated with mouse and keyboard and follows the Windows display scaling of
the machine it runs on.

Keyboard support:

- `Tab` / `Shift+Tab` move focus through the controls on the current screen.
- `Ctrl+F` opens the Item Giver and focuses its search field.
- `F5` refreshes the current screen.
- `Ctrl+Z` undoes the last recorded change, except while an entry has focus.
- `Esc` closes an open probe or dump window.

Text contrast was checked against the tray of surfaces in `ui/theme.py`: body
text is `#e9ebee` on `#0d0e10`, hints are `#8b929b`. The accent amber
`#e3a84a` is only used for actions and selection, never for long text.

Known limitations, honestly stated:

- No screen-reader support or certification. The custom UI toolkit does not
  expose an accessibility tree.
- No high-contrast theme. The dark theme is fixed; `ui/theme.py` is the single
  place to change it.
- Layout is fixed in pixels, so very high display scaling can clip panel
  controls. The minimum window size is 1024 x 720.
- The list widgets are native Tk listboxes. They respond to arrow keys and
  `Home`/`End` but do not announce rows to assistive technology.

If a barrier stops you from using a feature, open an issue describing it (use
the bug template and say it is an accessibility problem). Keyboard
reachability, contrast and clipping fixes are welcome issues and welcome PRs.
