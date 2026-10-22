# Security Policy

## Supported versions

Only the **latest release** of each tool is supported:

- Arisen's Toolbox (desktop app) — latest `v*` release
- Arisen's Toolbox cheat table — latest `ct-*` release

Older versions don't get fixes; update first and check whether the
problem is still there.

## What counts as a security issue here

This is a game modding tool, not a service — there are no accounts or
servers. Reports that matter:

- A bug that can **corrupt or delete save data** outside the documented
  backup/restore behavior.
- The installer writing or replacing files **outside the game folder**
  it was pointed at, or replacing a `dinput8.dll` that is not
  REFramework.
- A downloaded file (e.g. a tampered copy circulating elsewhere)
  behaving differently from the release in this repository — check the
  SHA-256 printed in the release notes first; a mismatch means the
  copy isn't genuine.

## Reporting

Please **do not** open a public issue for a save-corruption or
file-safety problem. Use GitHub's private reporting instead:
**Security tab → Report a vulnerability** on this repository.
(If that button is missing, message Darktenebr01 privately via the
[Nexus Mods page](https://www.nexusmods.com/dragonsdogma2/mods/1784).)

Include the tool + version, game version, what the tool did, and the
relevant log (app Connection tab / CT Connect log). Expect an
acknowledgement within a few days; save-corruption issues take
priority over everything else.
