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
