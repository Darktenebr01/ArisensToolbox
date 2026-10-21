# Arisen's Toolbox

Standalone companion app for **Dragon's Dogma 2** (PC/Steam). Press **Start**
and it handles everything: installs REFramework if missing, installs/updates
its game-side script, launches the game through Steam, and connects
automatically once your save is loaded.

It talks to the game through a small REFramework Lua script (`ddbridge.lua`)
using plain text files in `reframework/data/ddbridge/` — **no memory scanning,
no AOB patterns**, so it keeps working after Capcom title updates.

## Features

- **Item Giver** — searchable list of every item; give any quantity instantly
- **Item Editor / Item Stats** — inspect and edit items, including hidden
  special effects (the mechanism behind rings)
- **Duplicate Items** — one-click duplication
- **Pawn** — rating & badges editor
- **Character** — weapon skills, upgraded (Ex) skills, core skills & augments
- **Mods** — jump tweaks, fast travel (warp to map pin / quest marker via the
  engine's warp pipeline, 6s fall immunity), faster enemy respawn (custom
  timers, read/reset game defaults, corpse fast-forward)
- **Header bar** — target selector, vocation picker, pawn picker, Set Vocation
  anywhere, Unlock All vocations

## Changelog

- **v0.93** - External-review fixes (bridge v1.89.3): Faster Respawn no longer changes the game just by being installed - its hooks stay inert until you press Apply in the Mods tab (Reset turns the override back off). Save-backup safety net hardened: a failed backup copy now BLOCKS the change instead of failing open; a game restart re-arms the backup and clears undo history (old undo values can no longer be written into a new session); the first backup ever made is pinned so the pre-tool baseline can't be pruned away; Restore now only writes into the Steam account the backup came from. A mutating command that times out is removed from cmd.txt and reported as “may or may not have run”. Ctrl+Z no longer fires while you're typing in a text field. “Clean dump files” no longer deletes itemnames.txt (your custom item names live there). The REFramework installer never replaces a dinput8.dll that doesn't look like REFramework (another mod's proxy), logs the installed DLL's SHA256, and moved to bridge/installer.py so it is testable headless. Item Giver validates the item ID against the loaded list and clamps quantity to 1-999 (the Lua clamps too). The heartbeat no longer queues behind long commands, two Toolbox windows can no longer fight over the bridge files, and timeskip_probe is no longer classed read-only (it installs capture hooks). CI now runs deferredcheck.py plus a command-surface cross-check.
- **v0.92** - Save protection + UX + cuts (bridge v1.89.2): automatic save backup before the first save-writing command of a session (Steam `userdata\<id>\2054970\remote` copied to `%LOCALAPPDATA%\ArisensToolbox\backups`, last 10 kept), plus Backup now / Restore backup (restore backs up the current save first) on the Connection tab; "Undo last change" for edits that record their previous value (rating, badges incl. fill, vocation, renames, weapon-skill level); confirm prompts with counts for bulk writes (unlock all vocations / weapon skills / core skills / augments, fill badges); Export diagnostics (.zip with versions, game build, last 200 commands with timings, log tail). Connection heartbeat dot with auto-reconnect; last tab / window / target / vocation are remembered; item search debounced (150 ms); Item Giver falls back to the on-disk items/enums cache offline; tooltips on save-writing buttons; Ctrl+F search, F5 refresh, Esc closes dialogs, Ctrl+Z undo; Clean dump files + Reset installed files. Cuts: the Signatures tab and the Lua `fn_addr` command are deleted; 19 probe/diagnostic buttons moved to dev mode (`DD2BRIDGE_DEV=1`); `ddbridge.lua` and `dinput8.dll` backups are a single `.bak`, replaced on update. Also fixes the one mixed-version trap in v0.91: a pre-1.89.1 bridge still answers `ping`, so the version check reports the old bridge instead of a 5-minute timeout.
- **v0.91** - Reliability hardening: one version source (`version.py`); per-game-session boot token rejects replayed `cmd.txt` commands; responses carry an `|END` sentinel and are written temp+rename where possible; UI callbacks are marshalled to the Tk main thread; the REFramework installer validates the zip, backs up the old `dinput8.dll` and swaps atomically; settings and logs live in `%LOCALAPPDATA%\ArisensToolbox`; bridge v1.89.1. Adds CI and unit tests.
- **v0.90** — Weapon Skills cleanup: removed the temporary diagnostic buttons (Probe skill detail, Dump enabled list, Try fix selected). Kept Probe levels/upgrades, equipment probes, and Add missing entry. Lua unchanged at v1.89.0.
- **v0.89** — SmokeGiants: "Add missing entry" — if the skill has no EnabledCustomSkills entry (120 has none while all others do), create one (CustomSkillID + Level) and List.Add it, with read-backs; if an entry exists, set its Level field.
- **v0.88** — SmokeGiants follow-up: read-only "Dump enabled list" (every EnabledCustomSkills entry + ReachLevel) + "Try fix selected" (prepareEnableCustomSkillList, then enable, then level-up + enable again, with read-backs and a check that no other skill changed).
- **v0.87** — Read-only "Probe skill detail" on Weapon Skills: lists every CustomSkill method + every SkillContext field + LevelNo enum + per-skill getters (for the SmokeGiants diagnosis).
- **v0.86** — Item rename: the `get_Name` hook now walks the parent type chain to the type that declares it.
- **v0.85** — "PROBE type" reports the real item-data type and its Name methods.
- **v0.84** — Rename hook tries both type names and falls back to the real item's type.
- **v0.83** — "DIAG name" reports hook install status, lookup calls, and matches.
- **v0.82** — Item rename reworked: hooks `get_Name()` (items have no settable name field).
- **v0.81** — Rename reads the item ID via `get_Param()` (masters are wrappers).
- **v0.80** — New "Rename item" card in the Item Editor (per item type). Element % work dropped.
- **v0.68–v0.79** — Element % investigation (probes + hooks): the displayed +50% comes from a field, not the getters. Dropped in v0.80.
- **v0.67** — Elements are permanent (restriction hook auto-installs at load).
- **v0.66** — Element unlock: any weapon can take any element.
- **v0.65** — Element picker (Fire / Ice / Lightning / Holy) in the Item Editor.
- **v0.64** — Fall protection scales with drop height (up to 25s).
- **v0.63** — Terrain API hunt: no ground-height query found.
- **v0.62** — Pin selection via the game's `IsEnable` flag (no more stale pins).
- **v0.61** — Altitude discovery probe (`setMapPin` hook).
- **v0.60** — Warp drops from min 800m when the pin has no altitude.
- **v0.59** — Pin dump via `GetValue`.
- **v0.58** — Pin array read via `GetValue` (not `Get`).
- **v0.57** — Warp-to-pin altitude fixed; `SelectedIcon` y=0 no longer lands under the map.
- **v0.56** — Pin list type probe.
- **v0.46–v0.55** — Fast Forward 3 Days investigation: engine time-skip calls threw/crashed, field writes move only the day counter. Parked.
- **v0.45** — Pin/marker lookup fixed (correct field/method names).
- **v0.44** — Warp probe deep scan.
- **v0.43** — Fixed `FT.until` (reserved word) breaking script load; real Lua parse added to the checklist.
- **v0.42** — Fast travel fixes (fall protection, Diagnose warp, engine time-skip).
- **v0.41** — Achievements tab removed (no reachable system).
- **v0.40** — Achievements verdict: Steam Achievement Manager route documented (AppID 2054970).
- **v0.39** — Achievement probe calibration.
- **v0.38** — Achievements tab + probe.
- **v0.37** — Pawn name lookup falls back to the Human's `PawnDataContext`.
- **v0.36** — "Browse DD2.exe...": direct game launch, remembered.
- **v0.35** — Name editing rewritten (contexts, language stamping, 12-char cap).
- **v0.34** — Pawn names via `PawnDataContext`.
- **v0.33** — `probe_name` diagnostic on the Names tab.
- **v0.32** — Fixed `get_target` use-before-declaration; scope checker fix.
- **v0.31** — Fixed 75 deferred `except as e` NameErrors; added `deferredcheck.py`.
- **v0.29** — Movement Speed sliders (100–300%, pawns, ladder).
- **v0.28** — New Names tab (rename Arisen, main pawn, hired pawns).
- **v0.20–v0.27** — Badge investigation: game stores ID + count only; 23 names mapped via darken tests.

## Run from source

Requires Python 3.11+ on Windows (the game is Windows-only).

```
pip install -r requirements.txt
python main.py
```

Or double-click `run.bat` (installs dependencies automatically).

## Tests

```
python -m unittest discover -s tests -v
```

CI runs those tests on Windows and syntax-checks `ddbridge.lua` with Lua 5.4
on Linux; see `.github/workflows/ci.yml`.

## Build the .exe (Windows)

Double-click `build.bat` — installs PyInstaller via pip and builds
`dist\ArisensToolbox.exe` (~40MB, no console window). Share just the exe;
first run installs REFramework itself.

## Protocol

- `ddbridge.lua` (REFramework, in-game) polls ~10x/sec. `ping` returns
  `pong ddbridge 1.89.1 boot={token}`, where the token is unique to that
  game process.
- Client writes `{id}|{command}|{arg}|...|B:{token}|END` to `cmd.txt`
  (atomic tmp+replace, one in-flight command at a time). Commands carrying a
  stale or missing token are rejected with `STALE_SESSION` without being
  executed; the client re-pings and retries once.
- The game writes `{id}|OK|{payload}|END` or `{id}|ERR|{msg}|END` to
  `resp.txt`, temp+rename where possible. The `|END` sentinel makes a
  truncated read detectable, so a partial payload is never treated as a
  successful result.
- Bulk data (item lists, dumps) travels through sidecar files in the same dir.
- Settings and logs: `%LOCALAPPDATA%\ArisensToolbox` (`logs\client.log`).
  Set `ARISENS_CONFIG_DIR` to override the folder for a portable install.

## Credits

- **Fearless** — item-names list (used with permission)
- **Dutchysaur** — Set Vocation Anywhere (vocation logic adapted)
- **Caique Aguiar (OhCato)** — FastTravel Anywhere (warp pipeline adapted)
- **praydog** — REFramework
