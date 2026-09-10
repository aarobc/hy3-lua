# hy3-lua

Custom Hyprland Lua layout (`hl.layout.register`) that emulates sway/i3
window-movement and split behavior, replacing the reactive dwindle-patching
approach in `~/dotfiles/hypr/fallback.lua`.

## Scope

**In scope:**
- Directional window movement (`mod+shift+dir`) that respects a real,
  persisted tree — matching sway's `move left/right/up/down`.
- Persistent per-container split orientation — sway's model where a
  container remembers `splitv`/`splith` and new/moved windows landing in it
  inherit that orientation, until explicitly toggled.

**Out of scope — do not implement:**
- Tabbed layouts (sway `layout tabbed`).
- Stacked layouts (sway `layout stacking`).
- Anything related to sway's tab/stack rendering or cycling. If a sway
  behavior only matters for tabbed/stacked containers, skip it.

## Directory layout

- `CLAUDE.md` — this file.
- `layout.lua` — the `hl.layout.register("sway", {...})` implementation.
  Currently a stub (naive equal-width columns) — not yet doing anything
  tree-based. Build the real thing here.
- `sandbox/hypr-nested.lua` — minimal nested Hyprland config for testing.
  Has commented-out lines to load `layout.lua` once it's worth loading.
- `sandbox/sway-nested.config` — minimal nested sway config with the same
  keybinds, for side-by-side behavior comparison.

## Why nested instances

Both Hyprland and sway can run as ordinary Wayland clients inside the
existing live Hyprland session (`$WAYLAND_DISPLAY` is already set, e.g.
`wayland-1`). This gets a disposable compositor to test against without
touching the real desktop or real windows. Confirmed working on this
machine (Hyprland 0.56.2, sway 1.12) as of this writing.

**Always clean up nested instances when done** — `kill <pid>` them
explicitly. `pkill -f <config-path>` is convenient but only matches while
the config file still exists at that path; if you delete/move the config
first, the process cmdline no longer matches and `pkill -f` silently does
nothing while claiming success. Verify with `hyprctl instances` /
`pgrep -fa sway` afterward, not just by checking pkill's exit code.

## Nested Hyprland: starting and targeting

```sh
Hyprland -c ~/code/hy3-lua/sandbox/hypr-nested.lua &
sleep 1
hyprctl instances        # find the new one — matches by pid/start time
```

Output looks like:

```
instance <sig>:
	time: ...
	pid: 369005
	wl socket: wayland-2
```

Target every subsequent `hyprctl` call at it with `-i <sig>` (signature or
index into the `instances` list, e.g. `-i 1`). Spawn clients into it via
`WAYLAND_DISPLAY=<its wl socket> foot &` (or any Wayland-native app).

```sh
SIG=<signature from hyprctl instances>
WAYLAND_DISPLAY=wayland-2 foot &
WAYLAND_DISPLAY=wayland-2 foot &
hyprctl -i "$SIG" -j clients
hyprctl -i "$SIG" -j monitors
hyprctl -i "$SIG" -j workspaces
hyprctl -i "$SIG" dispatch 'hl.dsp.window.move({direction="right"})'
```

Kill it when done: `kill <pid>` (pid from the `instances` output, or from
the `&` job you started it with).

### Querying / calling into the running Lua config

`hyprctl -i "$SIG" eval '<lua>'` runs arbitrary Lua **but only ever prints
the literal string `ok`, never a return value** — historically the only
way to get data out was writing it to a file inside the eval and `cat`ing
that file afterward.

**Better, verified on this build:** `hyprctl -i "$SIG" repl '<lua>'` DOES
print the return value directly:

```sh
$ hyprctl repl 'return 1+1'
2
$ hyprctl -i "$SIG" repl 'return #hl.get_windows()'
2
```

Prefer `repl` over `eval` for anything that needs to read a value back.
`repl` also works without a trailing `return` for simple expressions
(`hyprctl repl '1+1'` also printed `2` in testing), but write `return ...`
explicitly to be safe with statements.

To call functions defined in your config file (e.g. something in
`layout.lua`), export them onto `_G` from the config so `repl`/`eval` can
reach them by name.

### Interpreting `hyprctl -j clients` / `-j workspaces` / `-j monitors`

Real sample (nested instance, 2 tiled `foot` windows):

```json
{
    "address": "0x557999b4a160",
    "at": [21, 175],
    "size": [269, 142],
    "workspace": { "id": 1, "name": "1" },
    "floating": false,
    "monitor": 0,
    "class": "foot",
    "stableId": "18000002"
}
```

- `at` / `size` are absolute pixel geometry (`GEOMETRIC_GOAL` — the
  post-animation target, correct to read immediately after a dispatch, no
  need to wait for the move animation to finish).
- `workspace` is `{id, name}` here (plain JSON) — contrast with the Lua API
  inside the config, where `window.workspace` is a **userdata** object, not
  a table; see the "Lua API gotchas" section below.
- `monitor` is a numeric **index**, not a name, in `-j clients`. `-j
  workspaces` gives you the monitor **name** instead (`"monitor": "eDP-1"`).
  Don't assume the two are interchangeable across endpoints.
- There is no tree/node structure exposed via `hyprctl` — dwindle's split
  tree is not queryable this way. Orientation/nesting has to be *inferred*
  from geometry (compare `at`/`size` across windows on the same
  `workspace.id`), which is exactly why `fallback.lua` does that (see
  `orientation()`/`is_column()`/`tiled_bounds()` there for the pattern) and
  why a real custom layout that owns its own tree is more tractable than
  trying to introspect dwindle's.

### Lua API gotchas (inside the config, not over `hyprctl -j`)

- `hl.get_monitors()` / `hl.get_workspaces()` / `hl.get_windows()` return
  **userdata** objects (`HL.Monitor`, `HL.Workspace`, `HL.Window`), not
  plain tables. `pairs()` on them throws. `ws.monitor` is an `HL.Monitor`
  object, not a name string — comparing it to a string silently gives
  `false`, no error. Compare `ws.monitor.name == other.name` instead.
- `io.popen(cmd):close()` always returns `nil, "No child processes", 10`
  regardless of the command's actual exit code — Hyprland reaps SIGCHLD
  itself before Lua's `waitpid` sees it. Push exit status through stdout
  instead if you need it (`cmd .. " ; echo $?"`, read from the pipe).
- Legacy string dispatch (`hyprctl dispatch 'workspace 12'`) is a **syntax
  error** in Lua-config Hyprland — everything routes through the Lua
  evaluator. Use `hl.dsp.*` table calls, e.g.
  `hyprctl dispatch 'hl.dsp.focus({workspace=12})'`, or
  `hl.dsp.exec_raw("workspace 12")` as an escape hatch for legacy strings.
- Full API surface (all `hl.*` functions/types, including the layout
  registration API): `/usr/share/hypr/stubs/hl.meta.lua` (1777 lines,
  autogenerated, matches the installed build exactly). Read this before
  guessing at a function signature.
- Matching Hyprland source checkout: `~/.cache/tmp/hl-src`. Custom layout
  API implementation specifically:
  `~/.cache/tmp/hl-src/src/config/lua/layout/LuaLayoutProvider.cpp` and
  `LuaLayoutContext.cpp`. Example layouts (including a `manual.lua` doing
  roughly what this project wants, and a trivial `columns.lua`):
  `~/.cache/tmp/hl-src/example/layouts/`.

### Custom layout API — key facts (verified against source, not guessed)

- `hl.layout.register(name, {recalculate = function(ctx) ... end, layout_msg = function(ctx, msg) ... end})`.
  Registers a layout as `lua:<name>`; select it with
  `hl.config({general={layout="lua:sway"}})`.
- `recalculate(ctx)` is called on basically every topology change (window
  open/close/move, resize, workspace change). `ctx.targets` is the full
  live list of `ITarget`s on that workspace **every time** — there is no
  persistent tree given to you. `ctx.area` is the workspace's usable
  `{x,y,w,h}`. `ctx:split(box, side, ratio)` / `ctx:column(i,n)` /
  `ctx:row(i,n)` / `ctx:grid_cell(...)` are pure geometry helpers — they do
  not remember anything between calls.
- **This means you own all persistent state.** Any notion of "this
  container is a vsplit," "these three windows are grouped," "this was the
  last-focused leaf," etc. has to live in your own module-level Lua table,
  keyed by something stable across calls — `target.window.stable_id`, not
  the target's index (indices shift as windows come and go). See
  `manual.lua`'s `state.order` / `state.split` for the pattern.
- **Critical gotcha for the movement goal:** `mod+shift+dir`
  (`hl.dsp.window.move({direction=...})`) does **not** call into your Lua
  `recalculate`/`layout_msg` at all for the move logic itself. Verified in
  `LuaLayoutProvider.cpp`: `CLuaTiledAlgorithm::moveTargetInDirection` is
  pure C++ that swaps the target with the next/previous entry in the *raw
  insertion-order* `m_targets` list — it knows nothing about whatever tree
  your `recalculate` built. If your visual arrangement's left-to-right
  order doesn't match insertion order (it usually won't, once you support
  moving windows around), the built-in move dispatcher will do the wrong
  thing.
  - To get sway-correct movement, bind `mod+shift+dir` to your own
    `layout_msg` commands instead of `hl.dsp.window.move({direction=...})`,
    and implement the tree-aware neighbor lookup yourself inside
    `layout_msg` (mirroring what `recalculate` already knows from your
    persisted state).
  - Cross-monitor hand-off still isn't covered by anything in the layout
    API — that's a `hl.get_monitors()` / geometry problem regardless of
    layout, same as it is in `fallback.lua` today.
- `target:place(box)` is how you actually position something inside
  `recalculate`. Sample from `columns.lua`:
  ```lua
  hl.layout.register("columns", {
      recalculate = function(ctx)
          local n = #ctx.targets
          if n == 0 then return end
          for i, target in ipairs(ctx.targets) do
              target:place(ctx:column(i, n))
          end
      end,
  })
  ```

## Nested sway: starting and targeting

```sh
sway -c ~/code/hy3-lua/sandbox/sway-nested.config &
sleep 1
```

sway prints its IPC socket path to `--get-socketpath` or you can find it
directly:

```sh
ls /run/user/$(id -u)/sway-ipc.*
```

Target every `swaymsg` call at that socket with `-s`:

```sh
SOCK=/run/user/1001/sway-ipc.1001.<pid>.sock
WAYLAND_DISPLAY=<its wayland socket, e.g. wayland-3> foot &
swaymsg -s "$SOCK" -t get_tree
swaymsg -s "$SOCK" splitv
swaymsg -s "$SOCK" move left
```

Kill with `kill <pid>` when done — same caveat as Hyprland re: `pkill -f`
and deleted config paths.

### Interpreting `get_tree`

`get_tree` returns the **entire** node tree (root → outputs → workspaces →
containers → windows), unlike Hyprland's flat `clients` list. Walk it
recursively; each node has (at least) `type`, `name`, `layout`,
`orientation`, `percent`, `rect`, `nodes` (tiled children),
`floating_nodes`.

Real sample (nested instance, single monitor, 2 windows, before any
explicit split):

```
root                       layout=splith  rect=0,0 621x329
  output __i3 (scratchpad) layout=output
    workspace __i3_scratch layout=splith
  output WL-1               layout=output
    workspace 1             layout=splith  rect=0,0 621x329
      con "foot"             layout=none    percent=0.5008  rect=0,25 311x304
      con "foot"             layout=none    percent=0.4992  rect=311,25 310x304
```

Key things this confirms:

- A workspace itself has a `layout` (its top-level split direction) and
  its direct children are the top-level containers — no separate "root
  split node" the way dwindle's binary tree has; sway's containers are
  **n-ary**, not binary. A workspace with 3 windows side by side is one
  `splith` workspace node with 3 leaf children directly, not nested pairs.
- Leaf windows (`con`) have `layout=none` — the container *around* them
  carries the split direction, not the leaf itself.
- `percent` is each child's share of its parent's main axis — this is
  where "equal thirds" or any explicit ratio actually lives; it's a flat
  per-child value in an n-ary list, not something you have to reconstruct
  by nesting resizes like dwindle forces you to.

**This is the core structural difference to emulate:** sway containers are
n-ary lists with per-child `percent`, not a binary tree. A Hyprland custom
layout that models containers this way (a list of children + orientation +
percent per node, keyed by stable id, held in your own Lua state) sidesteps
the entire class of "nested binary nodes don't resize evenly" and "wrong
pair gets its orientation flipped" problems that `fallback.lua`'s
dwindle-patching approach runs into.

### Persistent split, verified behavior

Splitting a leaf and adding a window does **not** just retarget the leaf —
sway wraps the leaf in a new anonymous split container, and the new window
becomes second child of that wrapper:

```sh
swaymsg -s "$SOCK" splitv        # focused leaf now
swaymsg -s "$SOCK" exec foot     # new window
```

Tree after:

```
workspace 1                 layout=splith
  con "foot"                 layout=none    rect=0,25 311x304      (unchanged sibling)
  con (anonymous, name=null) layout=splitv  rect=311,0 310x329     (new wrapper)
    con "foot"                layout=none    rect=311,25 310x140
    con "foot"                layout=none    rect=311,190 310x139
```

This is the exact mechanic behind "persistent splits": the split direction
is a property of the **container**, set once (`splitv`/`splith` or the
toggle), and every window that subsequently lands in that container
(open or moved-in) inherits it until the container is explicitly
re-split. Whatever tree structure `layout.lua` ends up maintaining needs to
support this "wrap a leaf in a new container with an explicit, sticky
orientation" operation directly — that's the sway behavior actually being
emulated, not the workaround `fallback.lua` and its `armed`/`preselect`/
`togglesplit` dance were built for the *lack* of.

## Comparison workflow

1. Start both nested instances side by side (different Wayland sockets, so
   they render as separate windows in the live session — move them next to
   each other).
2. Reproduce the same sequence of opens/moves/splits in both, using the
   matching keybinds from `sandbox/hypr-nested.lua` /
   `sandbox/sway-nested.config`.
3. Dump `swaymsg -t get_tree` and `hyprctl -j clients` after each step;
   diff geometry/nesting by hand. Save interesting dumps under a scratch
   subdirectory (not created yet — make one, e.g. `notes/`, if a comparison
   is worth keeping around) rather than losing them.
4. When `layout.lua` is far enough along to test, point
   `sandbox/hypr-nested.lua` at it (uncomment the `require` lines) instead
   of comparing against stock dwindle.
