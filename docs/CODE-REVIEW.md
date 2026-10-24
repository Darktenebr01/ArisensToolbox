# Code review, v0.176 to v0.178

This is the written part of the pass over Arisen's Toolbox: what was inspected,
what was broken, what changed, and what is still worth doing.

## How it was checked

- Read every Python module in `ui/`, `bridge/` and `tests/`, plus the build and
  CI files.
- Ran the existing suite: 64 tests (2 skipped on the original `DISPLAY` guard).
- Built every tab with the real Tk display, then drove the app against a
  small ddbridge emulator (`stdin`/`stdout` free, file protocol unchanged) that
  serves items, enums, inventories, badges, skills and mod dumps.
- Ran 19 scripted interactions: load, search, give, select, write a slot,
  apply, read/write rating, undo, read badges, unlock a skill, read core
  skills, read and set jump values, and confirm the automatic save backup
  fired before the first mutation.
- Profiled tab construction with `cProfile` and measured startup, first build
  and warm tab switches against v0.176.

## Defects found and fixed

### Correctness

1. **Cross-thread widget access (Item Editor).** The element error path built
   a UI callback in the worker thread and also touched `elem_combo` from it.
   Tk is not thread-safe; the callback is now created and run on the main
   thread only.
2. **Save discovery stopped at one bad folder.** `find_save_remote_dirs()`
   called `os.listdir()` inside a condition. One locked or half-created Steam
   account folder raised `PermissionError` and hid every other account's save.
   It now skips that folder and continues.
3. **Half-written backups.** If `shutil.copytree` failed mid-copy, the partial
   folder stayed in `backups/` and looked restorable. It is now removed before
   the error is re-raised.
4. **Off-screen window restore.** Saved geometry was validated with a regex but
   not against the current screen, so a window from a disconnected monitor
   could open outside the visible area. It is clamped to the screen now.
5. **Pawn selection by duplicate name.** The pawn picker used `values.index()`
   on plain names, so two pawns with the same name selected the first one.
   Labels are made unique when needed.
6. **Timer errors on exit.** Destroying the window with an `after` callback
   still queued printed `invalid command name ...`. Pending pump, heartbeat and
   save timers are cancelled on close.
7. **Startup crashes were invisible in the windowed build.** `main.py` now
   catches import and construction failures, prints the traceback to stderr,
   shows a dialog, and appends the failure to `client.log`.
8. **Item ID validation was O(n) per click.** Giving an item rebuilt a set of
   every item ID. The set is cached when the list loads.

### Responsiveness

9. **Layout re-entrancy.** The list empty-state label was re-placed on every
   `<Configure>` event, making Tk re-lay-out in a loop. It now toggles only when
   the row count changes.
10. **CustomTkinter scrollbars.** `CTkScrollbar._draw()` calls
    `update_idletasks()`, which flushes every pending canvas redraw. Creating
    two of them during a tab build cost over a second on the test machine.
    Replaced with `SlimScrollbar`, a small canvas that redraws only its thumb.
11. **Default-sized CTk frames.** CustomTkinter containers request 200 x 200 by
    default. Several screens had 100 px dead bands around short content. Layout
    containers now size to their children, and most are plain `tk.Frame`s
    (no canvas, no redraw cost).
12. **Connection screen blocked the UI thread.** Game detection, the
    REFramework file check and the save-folder scan ran during tab
    construction. They now run on a worker, with a sequence token so a stale
    scan cannot overwrite a newer result.
13. **Search rebuilt the list on every keystroke** in Item Editor and Duplicate
    Items, inserting rows one at a time. Both are debounced (140 ms) and fill
    the list in one bulk call. Item Editor search also matches item IDs now.

Measured on the development machine (1100 ms-range startup, same machine):

| Metric | v0.176 | v0.177 |
| --- | --- | --- |
| First build, Item Stats | 944 ms | 263-790 ms |
| First build, Duplicate Items | 490 ms | 340 ms |
| First build, Item Editor | 1540 ms | 660-1000 ms |
| First build, all 13 tabs | 6329 ms | 6236-6458 ms |
| Warm switch, all 13 tabs | 2028 ms | 2296 ms |
| Second tab build of a heavy screen | 2.1-3.1 s (before the scrollbar fix) | 0.3-1.0 s |

The first-build totals are dominated by first paint of the whole widget tree
and vary by 20-30 % between runs on this VM; the per-screen numbers for the
list-heavy screens are the ones that changed materially.

### Tests and tooling

14. **The UI smoke test never ran on Windows.** It was skipped unless
    `DISPLAY` was set, which Windows never does, so the suite that exists
    precisely to catch construction crashes was inert on the target platform.
    It now attempts to open a Tk window and skips only if that fails.
15. **New regression tests**: compact page header, list empty-state toggling,
    `SlimScrollbar` visibility, theme font tokens, and the core/weapon skill
    unlearn commands. Current suite: 71 tests.

## Interface rebuild

The old interface mixed three type sizes, a muddy brown palette, right-aligned
one-off layouts, native white scrollbars and long explanatory paragraphs inside
cards. Research probes sat on the main screens next to user-facing controls.

v0.177 introduces a token file (`ui/theme.py`) and a component layer
(`ui/widgets.py`) with a page header, section cards, a compact command bar, a
navigation rail with an active marker, dark list wells, a slim scrollbar, a
status pill and one ranked set of buttons. Probes moved behind dev mode.

Details and rules are in `docs/DESIGN.md`.

## What was not changed

- **The Lua bridge is untouched.** It is 14 000 lines and the only part that
  runs inside the game; changing it without live testing would be reckless.
  Its version stays at 1.89.79 and the client still checks protocol
  compatibility.
- **The file protocol stays.** A socket or named pipe would be faster, but the
  text-file channel is the reason the tool survives title updates and needs no
  DLL injection of its own.
- **The command surface stays.** Every command the UI sends still exists in
  the Lua, and `tests/test_command_surface.py` enforces that.

## Recommended next steps

1. **Retire finished probes.** `summon_probe49/52/53/54`, `timeskip_probe` and
   the kill experiments are research scaffolding. Once the open questions are
   answered, delete them from `ddbridge.lua` and from `ui/tabs/mods.py`. The
   Lua is smaller and the command surface easier to audit.
2. **Poll less.** The client reads `resp.txt` every 50 ms and the heartbeat
   pings every 4-10 s. Watching the file with a change notification, or
   answering a ping with a longer-lived request, would cut idle I/O.
3. **Cheaper backups.** Each session copies the whole save folder. A zip with
   per-file dedupe (or hardlinks where the filesystem supports them) would
   keep the same safety with a fraction of the disk use.
4. **Exercise the bridge on Linux/macOS in CI.** The file protocol is
   platform-neutral; the current CI only checks Lua syntax there.
5. **Test display scaling.** The layout is pixel-based. A run at 125 % and
   150 % would catch clipping earlier than a user report.
6. **Accessibility.** The CustomTkinter toolkit has no accessibility tree, so
   screen-reader support would mean moving the shell to Tk widgets with a
   platform bridge. Out of scope for this pass, documented honestly in
   `ACCESSIBILITY.md`.

## Follow-up, v0.178: unlearning core skills

The requested feature was "unlearn core skills". The bridge already knew how
to learn them (`setNormalSkillEnable`), but the game exposes no
`disableNormalSkill` method. The enabled skills are held in
`SkillContext.EnableNormalSkills`, a collection: the community
"Reset normal skill" mod clears that entire list, which is why its reset
works.

The new bridge commands remove single ids from that list when the runtime
exposes `get_Count` / `get_Item` / `RemoveAt`, verify each id with
`isNormalSkillEnable`, and fall back to clearing the list and re-adding the
skills that must stay. Every route is logged, and the client records an undo
that relearns whatever was removed. The interaction suite exercises
unlearn-one, unlearn-all and both undos against the emulator; the Lua is
syntax-checked with a Lua 5.3 parser (the shipped script avoids 5.4-only
constructs).

The remaining uncertainty is runtime-only: whether this REFramework build
exposes the list mutation methods and whether the one-parameter
`setNormalSkillEnable` overload repopulates the list after a clear. The
fallback plus read-back makes the outcome explicit in the status line and in
`re2_framework_log.txt` instead of failing silently. A single live test on a
save with a learned core skill is the last check.

## Follow-up, v0.179: unlearning weapon skills

Weapon skills use a different store: `SkillContext.EnabledCustomSkills` holds
`app.HumanSkillContext.EnabledCustomSkill` objects (`CustomSkillID`, `Level`,
`IsViewedNew`) rather than enum ids. The bridge removes the matching entry,
verifies `isCustomSkillEnable`, and if the entry cannot be removed directly it
clears the list and recreates every remaining entry with its level (the same
`create_instance` + `set_field` + `List.Add` recipe the "add missing entry"
command already used).

The extra hazard here is the loadout: an equipped slot that points at a
forgotten skill would be a state the game menu cannot repair. Both sides
therefore refuse to unlearn anything currently equipped. The client checks the
six current-vocation slots for a friendly message, and the bridge scans all ten
vocations' slots as the final guard, reporting how many were skipped.

The same runtime uncertainty applies: whether `RemoveAt` / `Remove` are
exposed on this build, and whether `List.Add` accepts the recreated entries
after a clear. The command reports the route and every failed read-back, and
the undo relearns at the recorded level. A live test on a save with a learned,
unequipped weapon skill is the remaining check.

## Follow-up, v0.180: one bridge

CT v1.88 embedded bridge 1.89.80 with kill v14; the app v0.179 shipped
1.89.81 with unlearning but kill v13. Each front-end auto-installs its bundled
bridge, so running one after the other would have downgraded the game script
and silently removed commands. The CT file was inspected in this pass: its
embedded bridge was extracted, the v14 kill block was diffed against the app's
v13, and the unlearn blocks were inserted on top of v14. The result is bridge
1.89.82, embedded identically in app v0.180 and CT v1.90.

CT v1.90 also adds the app's four unlearn actions to its two skill tabs:
Unlearn selected and Unlearn ALL (vocation) for weapon skills and for core
skills. Each button calls the same bridge command as the app, re-reads the
state on completion, and leaves equipped skills alone (the bridge skips them
and the tab says so). The CT has no undo stack; relearning is the reversal.

The CT panel was otherwise left as it was. Its Lua parses with a Lua 5.3
compiler and its XML is valid, but Cheat Engine was not available here to run
the panel, so the new buttons' placement is unverified at runtime.
