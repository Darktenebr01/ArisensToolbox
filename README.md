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

## Build the .exe (Windows)

Double-click `build.bat` — installs PyInstaller via pip and builds
`dist\ArisensToolbox.exe` (~40MB, no console window). Share just the exe;
first run installs REFramework itself.

## Protocol

- Client writes `{id}|{command}|{arg1}|...|END` to `cmd.txt` (atomic tmp+replace,
  one in-flight command at a time).
- `ddbridge.lua` (REFramework, in-game) polls ~10x/sec and writes
  `{id}|OK|{payload}` or `{id}|ERR|{msg}` to `resp.txt`.
- Bulk data (item lists, dumps) travels through sidecar files in the same dir.

## Credits

- **Fearless** — item-names list (used with permission)
- **Dutchysaur** — Set Vocation Anywhere (vocation logic adapted)
- **Caique Aguiar (OhCato)** — FastTravel Anywhere (warp pipeline adapted)
- **praydog** — REFramework
