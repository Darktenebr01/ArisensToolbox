# Accessibility

Arisen's Toolbox is a Windows desktop app (CustomTkinter) plus a Cheat
Engine panel. Both are operated with mouse and keyboard and follow the
Windows display scaling of the system they run on.

Known limitations, honestly stated:

- No screen-reader support or certification — the custom UI toolkit
  doesn't expose one.
- No high-contrast theme; the dark theme is fixed.
- Text size follows the app's fixed layout; very high display scaling
  can clip panel controls.

If a barrier stops you from using a feature, open an issue describing
it (use the bug template and say it's an accessibility problem).
Reasonable fixes — keyboard reachability, contrast, clipping — are
welcome issues and welcome PRs.
