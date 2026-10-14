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

**v0.86** — Rename hook parent-chain fix (lua 1.86.0):
`get_ItemData` returns `ItemWeaponParam` (no Name methods),
but `call("get_Name")` works via inheritance. The hook now
walks the parent chain to the type that declares `get_Name`.
**v0.85** — Item type probe (lua 1.85.0): "PROBE type" reports
the real type of the item data object and every Name method on
it, so the rename hook can target the true method.
**v0.84** — Rename hook install fix (lua 1.84.0): the hook
looked for `get_Name` on the wrong type (the first type lookup
succeeded but had no such method). It now tries both type names
and falls back to the real item's type. Re-apply the name after
updating — the saved rename did not carry over.
**v0.83** — Rename diagnostics (lua 1.83.0): "DIAG name" button
reports whether the name hook installed, how many name lookups the
game ran, and how many matched a rename.
**v0.82** — Item rename reworked (lua 1.82.0): items have no
settable name field, so the bridge now hooks `ItemDataParam.get_Name`
and returns the custom name. Rename should now show in game.
**v0.81** — Item rename fix (lua 1.81.0): the rename read the
item ID off the wrong object (masters are wrappers — the ID lives
on `get_Param()`). Rename should now apply.
**v0.80** — Item rename (lua 1.80.0): new "Rename item" card in
the Item Editor — set a custom name, re-applied when the inventory
loads. Renames all items of that type (names are shared per type).
Element % display work dropped; the diagnostic buttons are gone.
**v0.79** — Element %: display still 50, calls neither getter,
doesn't read forced `_EqParam`. "PROBE weapon param" button dumps
ALL fields of the weapon's param object — the 50 must be in a field
there that was never fully dumped.
**v0.78** — Element %: the display doesn't call
`EquipParam.get_ElementStore` (0 calls), so the % must come from
`ItemWeaponParam.get_ElementStore`. New hook on that getter returns
the override when the weapon param matches the one you applied % to.
**v0.77** — Element %: new `calc()` hook forces `_EqParam` to
the override after every recompute (the value kept reverting to
50). DIAG now also counts `calc()` calls/sets and
`get_ElementStore` calls, to learn if the display reads through
that getter.
**v0.76** — Element %: "PROBE methods" button lists every
Param/Element/Calc/Enhance method on the item types, to find the
method the display actually uses (it's not `makeEnhancedParam`,
`_EqParam`, or `ArisenWeapons`).
**v0.75** — Element %: probe now also dumps `ArisenWeapons`
(per-weapon data) — the display doesn't read the character-total
`_EqParam`, so the % must live in per-weapon data.
**v0.74** — Element %: the hook works for native `calc()` calls —
the probe proves `_EqParam` goes to 100 after `calc()`. The display
reads a stale cache; close and reopen the equipment screen after
Apply %. Probe now reports hook matches during `calc()`.
**v0.73** — EquipData probe (lua 1.73.0): the game never calls
`makeEnhancedParam` for the display, so the % hook was a dead end.
New "PROBE EquipData" button dumps where the cached EquipParam
actually lives.
**v0.72** — Element % raw-args diagnostic (lua 1.72.0): DIAG now
dumps the hook's raw argument slots and resets counters per run, so
game calls can be told apart from the Toolbox's own calls.
**v0.71** — Element % hook fix (lua 1.71.0): the hook was reading
`this` from the wrong argument slot — the hidden return-buffer pointer
shifts it. The hook now finds the item and the return buffer by field
signature, so the % override should actually land.
**v0.70** — Element % diagnostics (lua 1.70.0): "DIAG element %"
reports whether the override hook is installed, how often the game
called it, what key it saw, and the computed % — to find why the
on-screen value didn't change.
**v0.69** — Element % control (lua 1.69.0): the displayed element %
is hardcoded to 50 by the game (no stored field feeds it), so the
bridge now overrides it per weapon via a `makeEnhancedParam` hook.
Set any % in the Element card; overrides persist across restarts.
**v0.68** — Element % probe round 3 (lua 1.68.0): dumps all
StorageData fields plus every field of the ElementType/StoreType
array entries, to find where the fixed 50 comes from.
**v0.67** — Elements are permanent now (lua 1.67.0): the element
restriction hook installs automatically when the bridge loads, so any
weapon can take any element and forced elements stay after a restart.
Element % probe extended (TempElement / Enhance data) to find what
controls the +50%.
**v0.66** — Element unlock + value probe (lua 1.66.0): "Allow any
element (this session)" lifts the game's per-weapon element restriction
so any weapon can take Fire / Ice / Lightning / Holy. "DUMP element
fields" probes where the element % (e.g. +50%) is stored.
**v0.65** — Element picker in the Item Editor (lua 1.65.0): pick
Fire / Ice / Lightning / Holy (or None) for a weapon. Only elements the
game's own rules allow for that item are offered; setting one replaces
any other blue-triangle enhancement and marks the item appraised so it
shows in game.
**v0.64** — Fall protection scales with drop (lua 1.64.0): high-altitude
pin drops get extended no-fall-damage time (up to 25s) so you land safely.
**v0.63** — Terrain API hunt (lua 1.63.0): "Diagnose warp" searches for a
ground-height query across FieldManager/physics/terrain types.
**v0.62** — Pin selection fixed (lua 1.62.0): uses the game's `IsEnable`
flag to pick your active pin instead of guessing by index — no more warping
to a stale pin.
**v0.61** — Altitude discovery probe (lua 1.61.0): "Diagnose warp" hooks
`setMapPin` to capture what the game passes at placement time, and hunts the
map UI for height/terrain methods — finding the real altitude source.
**v0.60** — Warp altitude + pin order (lua 1.60.0): drops from min 800m when
pin has no altitude (clears high terrain), tries pins from index 0 first, and
reports which pin index was used.
**v0.59** — Pin dump v2 (lua 1.59.0): "Diagnose warp" now reads pins via
`GetValue` and shows ID/time/enable fields to identify the most recent pin —
warps were stuck on a stale pin.
**v0.58** — Pin array reading fixed (lua 1.58.0): use `GetValue` (the real
.NET array accessor) instead of `Get` — warps were falling back to a stale
selected icon, hence the same location every time.
**v0.57** — Warp-to-pin altitude fixed (lua 1.57.0): pin list is an array
(`Get` accessor, not `get_Item`), and `SelectedIcon` y=0 no longer tricks the
warp into landing at 5m under the map — low/zero altitude now drops from safe
height with fall protection.
**v0.56** — Pin list type probe (lua 1.56.0): "Diagnose warp" now reports the
pin list's real type, why `get_Item` fails, and the `SelectedIcon` fallback's
position — pins show 5 in list but unreadable.
**v0.55** — Fast Forward writes all day copies (lua 1.55.0): day+3 now goes
to `_TimeData`, `_TimeDataLook` (display copy), and `_DetectionCacheDay`
together, so the visible clock and game systems follow.
**v0.54** — Fast Forward 3 Days via field write (lua 1.53.0): the clock is
plain data (`_TimeData.<InGameDay>`), so the engine path now writes day+3
directly with read-back verification — no method invokes, no teleport.
**v0.53** — Time field dump v2 (lua 1.52.0): "Dump time fields" now also
reads into `TimeManager._TimeData` (the live clock object) to find the
writable time value.
**v0.52** — Time field dump (lua 1.51.0): new "Dump time fields" button lists
every field of TimeManager/TimeSkipManager (read-only) to find where the
clock lives, since method calls are blocked.
**v0.51** — Fast Forward engine path DISABLED (lua 1.50.0): direct invokes of
`requestTimeSkip`/`setTime` threw and a following `onWarp()` crashed the game
— those methods need an active warp-request context. No more blind invokes.
"Dump time-skip sig" now lists every overload from metadata (safe) to find a
proper entry point.
**v0.50** — Fast Forward 3 Days via `requestTimeSkip` (lua 1.49.0): direct
`setTime` threw (it isn't a standalone entry point), so the engine path now
uses `requestTimeSkip(hr, mn, day+3, nil, false, nil)` — the API that creates
the time-skip request. Still no position parameter, so still no teleport.
**v0.49** — Fast Forward 3 Days fixed (lua 1.48.0): replaced the
`requestPlayerWarp` path (which teleported to the map center) with the exact
inn-rest flow the probe observed — `setTime(totalMinutes, false)` then
`onWarp()`. No position parameter anywhere, so the player stays put.
**v0.48** — Time-skip signature dump (lua 1.47.0): resting fires
`setTime`/`onWarp`; new "Dump time-skip sig" button reads their exact
parameter types from method metadata so the +3-day call can be built without
guessing.
**v0.47** — Time-skip probe v2 (lua 1.46.0): resting never called
`requestTimeSkip`, so the probe now hooks all seven time/warp methods on
TimeSkipManager at once and reports whichever one the rest flow actually uses.
**v0.46** — Time-skip signature probe (lua 1.45.0): the in-place +3-day warp
advanced time but teleported the player to the map center, so Fast Forward
needs the position-less `requestTimeSkip` instead. New "Diagnose time-skip"
button installs a hook capturing the exact args the game passes during a
natural rest — run it, rest at an inn/camp, run it again.
**v0.45** — Fast travel pin/marker lookup fixed (lua 1.44.0): the probe proved
the pin list field is `<MapPinList>k__BackingField` and the quest marker method
is `getQuestTargetMarkerList` — both previous names were wrong, so pins/markers
were never found. Warp now also prefers the most recently placed pin, and the
probe dumps every pin's position fields to pick the true altitude next.
**v0.44** — Warp probe deep scan (lua 1.43.0): the pin/marker lookup paths came
back empty despite a placed pin, so the probe now scans all of GuiManager's
pin/marker/quest fields and methods plus candidate manager singletons to find
where pins really live. No behavior change.
**v0.43** — Fixed a script-breaking syntax error: v1.41.0 used `FT.until` but
`until` is a reserved word in Lua, so the whole game script failed to load.
Renamed to `FT.protect_until` (lua 1.42.0). Added a real Lua syntax parse to
the pre-ship checklist so this class of bug is caught before release.
**v0.42** — Fast travel fixes (lua 1.41.0): 6s fall protection reworked to force
the Jump tab's no-fall-damage patching on during the window (restoring your
setting after), with the handler hook kept as backup — warp results now report
which layers are active. New "Diagnose warp" button dumps pin/marker fields to
find the true altitude. Fast Forward 3 Days now goes through TimeSkipManager's
engine time-skip pipeline (in-place warp +3 days) instead of guessing at
TimeManager internals.
**v0.41** — Removed the Achievements tab and the achievement probe (lua 1.40.0):
the investigation concluded no achievement system is reachable from the
toolbox.
**v0.40** — Achievements tab verdict: the probe proved no achievement system is
reachable from the toolbox (lua unchanged at 1.39.0). Tab now documents the
Steam Achievement Manager route (AppID 2054970) instead.
**v0.39** — Achievement probe calibration (lua 1.39.0): probes known-real and
known-bogus singleton names next to the candidates to decide whether the
native-singleton results are meaningful.
**v0.38** — New Achievements tab with an achievement-system probe (lua 1.38.0):
hunts for the game's achievement/trophy plumbing to decide whether an in-app
unlocker is feasible. Probe only for now.
**v0.37** — Pawn name lookup falls back to the Human's `PawnDataContext` when
the context-dictionary path returns nothing (lua 1.37.0).
**v0.36** — "Browse DD2.exe...": pick your game exe once, the client remembers
it and launches the game directly — no Steam needed. "Reset" goes back to
auto-detection + Steam launch.
**v0.35** — Name editing rewritten: contexts via `get_Context().Contexts`,
Arisen through `PlayerPersonalDataContext`/`get_NameProp`, language stamping so
renames display in-game, old-name field sweep, 12-char cap, save+reload note
(lua 1.36.0).
**v0.34** — Pawn names wired via `PawnDataContext`; added `probe_arisen` deep
hunt for the Arisen's name container (lua 1.35.0).
**v0.33** — `probe_name` diagnostic + Diagnose button on the Names tab, showing
name-related methods/fields in a copyable popup (lua 1.34.0).
**v0.32** — Fixed `get_target` use-before-declaration crash in ddbridge.lua
(lua 1.33.0); fixed the scope checker, which had been silently checking the
wrong file.
**v0.31** — Fixed systemic crash: 75 spots used `except as e` inside deferred
callbacks (the resulting NameError hid every real error message); added
`deferredcheck.py` to the pre-ship checklist.
**v0.29** — Mods tab: Movement Speed section — 100–300% slider, apply-to-pawns
toggle, separate ladder climbing speed slider (lua 1.31.0).
**v0.28** — New Names tab: rename the Arisen, main pawn and hired pawns
(lua 1.30.0).
**v0.27** — 23 badge names mapped via screenshot grid order + quota cross-checks.
**v0.26** — 13 badge names mapped from in-game darken tests; grid order verified
to match PB order.
**v0.25** — Badge name table introduced; PB050 shown as Death Reaper.
**v0.24** — BadgeIDEnums probe (lua 1.29.0): confirmed it's only the raw enum —
the game stores no badge name table.
**v0.23** — Badge-name probe (lua 1.28.0).
**v0.22** — Duplicate Items tab: raw PB labels replaced with quota-based
descriptions.
**v0.21** — Badge and 3-day-respawn diagnostics moved to copyable popups.
**v0.20** — Badge-data probe (lua 1.27.0): badge entries store only ID + count.

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
