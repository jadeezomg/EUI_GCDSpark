# Agent rules for EUI_GCDSpark

This repository is the source for EUI_GCDSpark, a standalone EllesmereUI
plugin. The main EllesmereUI repository owns the shared conventions. Read these
files first:

- [EllesmereUI AGENTS.md](https://github.com/EllesmereGaming/EllesmereUI/blob/main/AGENTS.md)
- [EllesmereUI CONTRIBUTING.md](https://github.com/EllesmereGaming/EllesmereUI/blob/main/.github/CONTRIBUTING.md)

If this file and the main files disagree, the main files win. When a reviewer
corrects a mistake, fix the code and add the rule here.

## What the addon is

EUI_GCDSpark draws an overlay spark on the EllesmereUI player power bar for the
global cooldown and on the player cast bar for casts, channels and empowers. It
does not edit or hook an EllesmereUI file. It asks EUI for the player unit
frame and draws its own textures on the power and cast bars. The plugin loads
only when EllesmereUI is present.

## Repository layout

| File | Contents |
| --- | --- |
| `EUI_GCDSpark.lua` | The plugin: frame lookup, sparks, events and combat handling. |
| `EUI_GCDSpark.toc` | Load order, Interface ids, version, SavedVariables. |
| `sync.sh` | Copies the addon files to the local AddOns folder. |

WoW loads a TOC only from a folder with the same name as the TOC. Install the
files in `Interface/AddOns/EUI_GCDSpark/`. The repository and folder names
match.

## Naming

Every addon in this family uses the `EUI_` prefix and CamelCase after it. The
repository folder, addon folder and TOC base must all be `EUI_GCDSpark`. The
Lua file starts with `EUI_` as well. SavedVariables start with `EUI_`.

## Local install

The client reads its own copy from `Interface/AddOns/EUI_GCDSpark`, not from
this repository. `sync.sh` copies the two addon files there.

1. Copy `.install-path.example` to `.install-path`.
2. Put the full path to the client's `EUI_GCDSpark` folder on the first line.
   A leading `~/` is expanded.
3. Run `./sync.sh` after each change.

`.install-path` is gitignored. Do not commit it. The script checks that the
path ends in `/EUI_GCDSpark` and copies only the addon files.

## Client rules

- Every file compiles under Lua 5.1. A file may have at most 200 locals in
  scope at once and 60 upvalues per function.
- Line 1 is
  `if EUI_CLIENT_BLOCKED then return end -- same pre-12.1 client failsafe the EllesmereUI files use`.
- Lua is ASCII only and saved as UTF-8 without a BOM.
- The TOC `Interface` line lists every client that the plugin supports. Do not
  remove an id without testing that client.
- The TOC `Version` follows semantic versioning. Do not bump it for a change
  with no user-visible effect.
- Do not write to protected Blizzard frames and do not call protected
  functions from insecure code. Work with the EllesmereUI unit-frame objects
  and keep the drawing cosmetic.
- Do not compare, index or do arithmetic on secret values. Pass them to the
  widget API that accepts them. Use the plain active flag when combat makes
  cooldown data secret, as the GCD bar does.
- Do not register a raw `PLAYER_REGEN_ENABLED` for deferred work. Use
  `EllesmereUI.CombatQueue.Defer(key, fn)` when work must wait for combat.

## Testing and verification

Run these checks before you commit:

```sh
for f in *.lua; do luac5.1 -p "$f" || exit 1; done
grep -nP "[^\x00-\x7F]" *.lua *.toc
```

`luac5.1` may come from `luac5.1` on `PATH`, from `LUAC=/path/to/luac`, or from
`nix-shell -p lua5_1 --run`. The ASCII check must print nothing.

For a behavior change, load the file in a Lua 5.1 harness that stubs the WoW
and EllesmereUI APIs. Drive the cooldown and cast events and assert on the
timer, visibility and combat paths. Delete the harness before you commit.

After the checks pass, run `./sync.sh` so the client copy matches the
repository. In-game visuals are not covered by the harness, so a client check
is still needed for a drawing change.

## Version control

- Make one topic per commit. Use an imperative subject and explain the reason
  in the body.
- Do not commit harnesses, logs, editor folders or generated files.
- Do not rewrite history on a shared branch.
- Update this file when a convention changes.

## Exceptions

Put an exception in a comment on the offending statement. Name the human who
approved it and why:

```lua
local value = GetItemInfo(id) -- guardrails-allow: deprecated-global until 2026-12-31 by Ellesmere: retail-only path
```

Valid keys are `combat-deferral`, `deprecated-global` and `ascii`. A tag fails
when it has no approver, no reason, an unknown key or a bad date. An expired
date fails every guardrails run until the tag is removed or the date moves.
