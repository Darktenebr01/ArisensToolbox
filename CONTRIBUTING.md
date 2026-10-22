# Contributing to Arisen's Toolbox

Thanks for helping improve the Toolbox. This is a one-person project
(Darktenebr01) with limited time, so clear reports and small, focused
pull requests are what actually get merged.

## Reporting a bug

Open an issue with the bug report template and include:

- **Which tool**: the desktop app (version from the sidebar, e.g. v0.94)
  or the cheat table (e.g. CT v1.8) — they share the bridge but are
  separate front-ends.
- **Game version** (Steam, Title Update) and whether REFramework and
  the bridge connected OK (the app's Connection tab / the CT's Connect
  log both say so — paste that log).
- What you did, what you expected, what happened instead.
- Whether a save backup from before the change exists.

Reports like "it doesn't work" without versions or logs are closed —
there is nothing to go on.

## Suggesting a feature

Use the feature request template. One idea per issue. Features that
need the game to expose something it doesn't are answered honestly
when that is the case.

## Development setup

- Windows, Python 3.11+.
- `pip install -r requirements.txt -r requirements-dev.txt`
- Run the app: `python main.py` (or `run.bat`).
- Run the tests: `python -m unittest discover -s tests`
- Before opening a PR, also run `python deferredcheck.py` — it catches
  a real crash class this project has shipped before (an exception
  variable used inside a deferred UI callback).

The game-side bridge is `bridge/data/ddbridge.lua`. If you change it,
the Lua must still parse cleanly (CI checks it) and the client/bridge
versions must stay in sync (`version.py` is the single source).

## Pull requests

- One change per PR, with a description of what it does and how you
  tested it (unit tests, and in-game where relevant — say so honestly
  if a change is only verified statically).
- Tests must pass (CI runs them on Windows).
- Don't reformat files you didn't otherwise touch; it hides the change.

## Project rules

Arisen's Toolbox is published for personal use. Forks for your own use
are fine; re-uploading the tool, or lifting its scripts into another
public table/app, needs permission from Darktenebr01 first — ask in an
issue. By submitting a contribution you agree it can ship as part of
the project under the same terms.
