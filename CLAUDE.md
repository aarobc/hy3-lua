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
  Complete: n-ary tree state, movement, splits, focus, closure (see
  "Current status"). Loaded by the sandbox config; debug hooks in
  `_G.swaydbg` (see below).
- `notes/sway-spec.md` — the empirical behavioral spec (sway 1.12) that
  `layout.lua` implements. Every case verified against a real nested sway.
  **Read this before changing movement/insertion/split logic** — it is
  the source of truth, including the surprising bits (no auto-wrap on
  plain open, workspace re-orientation on orthogonal moves, 1-child
  containers persist).
- `notes/dual-monitor.md` — dual-display nested test environments (Xvnc +
  sway X11 backend works; headless sway has broken seat focus; nested
  Hyprland via `hyprctl output create wayland`) plus the verified
  cross-monitor move/focus behavior spec (sway 1.12) and open questions.
  Read before implementing dual-monitor window behavior. Batteries:
  `sandbox/run-dual-sway.sh`, `sandbox/dualmove_battery.py`,
  `sandbox/insert_battery.py`, `sandbox/tree_dump.py`; raw dumps in
  `notes/dualmove-dumps/`.
- `sandbox/hypr-nested.lua` — minimal nested Hyprland config; loads
  `layout.lua`, sets `layout = 'lua:sway'`, binds mod+hjkl to
  `hl.dsp.layout('focus …')`, mod+shift+hjkl to `hl.dsp.layout('move …')`,
  mod+v/s/t to the split commands, mod+Return to `hl.dsp.exec_cmd('foot')`,
  mod+q to close.
- `sandbox/sway-nested.config` — matching nested sway config (same
  keybinds, plus mod+v/s/t for split parity).
- `sandbox/battery.sh`, `sandbox/battery2.sh` — spec-case test sequences
  against a running nested instance (expects `/tmp/nested-sig`). Clients
  are spawned via the instance's own `hl.dsp.exec_cmd` dispatch so they
  can never land on the host.
- `sandbox/cross_battery.sh` — cross-monitor battery (M.*/X.*/F.* from
  `notes/dual-monitor.md`) against a nested instance with a second fake
  output (`hyprctl -i <sig> output create wayland`). Expects
  `/tmp/nested-sig` + `/tmp/nested-wl` (nested wl socket, for safe
  test-client kills).

## Current status

**Done and verified** (nested-instance batteries + one live side-by-side
against real sway 1.12; case numbers refer to `notes/sway-spec.md`):
- Tree model: n-ary containers, sticky H/V orientation, per-child
  fractions; state keyed by `window.workspace.id`; reconciled with
  `ctx.targets` every recalc (prune dead → insert new → fraction pass →
  place).
- Insertion (A): sibling after the pre-map focused window in its innermost
  container; armed `splitv`/`splith` wrapper inherits the leaf's exact
  slot; singleton rule rewrites the parent/workspace layout instead of
  wrapping (A.1–A.6, D.22 ✓).
- Movement (B): parallel-level crawl; adjacent swap with percents
  traveling (B.7); cousin insertion and focused-child descent (B.8–B.9,
  B.12); promotion (B.10); workspace re-orientation (B.14 — side-by-side
  match with sway); past-end no-op (B.13); focus follows the move (B.16).
- Focus: climb-up beats wrapping; wrap at the deepest parallel level;
  descent into the container's remembered focused child.
- Closure (C): proportional fraction renormalize; 1-child containers
  persist (child → frac 1.0); 0-child containers reaped (C.17–C.19).
- Cross-monitor (dual-monitor.md §2, battery `sandbox/cross_battery.sh`,
  all cases pass on a 2-output nested instance): `move` past the
  workspace edge hands the window to the *adjacent monitor's active
  workspace* (M.1/M.4 — even if empty, M.3); insertion at the entry
  edge (right/down: index 0, left/up: end, M.1/X.1/M.1b) or at the
  focused root child's index when the target root is perpendicular
  (X.4); screen edge → no-op (M.2). `focus` past the edge crosses to
  the geometrically nearest window (F.1, center-ratio distance),
  empty target → no-op (F.2), screen edge → no-op (F.3). Crossing
  BEATS wrap: wrap at the deepest parallel level is only the screen-
  edge fallback (verified against sway F.1; single-monitor wrap
  behavior is unchanged). Mechanism: tree is migrated first, then
  `hl.dsp.window.move({workspace=<target name>, window=<HL.Window>,
  follow=true})` moves the real window (see gotchas).

**Fraction semantics** (mirrors sway arrange; in `normalize`): children
with `frac <= 0` get the *average of the existing positive siblings'*
fractions — not `possum/total-count`, which gives 2/3·1/3 on the second
open — then all fractions renormalize to sum 1 per parent level.

**Known gaps / deliberate divergences:**
- `move` past the edge of a workspace whose root is *perpendicular* to
  the direction re-orients first (B.14) and does NOT cross in the same
  tick; a *subsequent* edge move then crosses (sway-side behavior for
  the promote-then-cross combination unverified — dual-monitor.md Q5).
- Focus-cross "nearest window" is a center-ratio distance, not sway's
  exact corner-based `con_closest_in_direction` (simple cases match,
  complex trees unverified — Q3).
- Vertical monitor adjacency (`position 0,720`) is implemented by the
  same geometry code but has not been battery-tested (Q4).
- Per-container `last_focus` is synced by recalcs plus our own
  focus/move/insert bookkeeping, but does NOT follow click-driven focus
  changes: a click into a non-last-focused branch, then a `move` into
  that container, descends into the remembered child instead.
- No gap modeling: placement divides the raw `ctx.area`; topology and
  relative sizes match a gapped sway, absolute geometry does not.
- `S` (per-workspace state) is never pruned for destroyed workspaces;
  workspace ids appear monotonically increasing in practice.

**Debug tooling** (in `layout.lua`, cheap enough to leave in):
- `hyprctl -i <sig> repl 'return swaydbg.dump()'` — pretty tree with
  fracs and last-focus marks for every tracked workspace.
- `swaydbg.state` — the raw state table.
- Start the nested instance as `HY3_DEBUG_LOG=/tmp/hy3-swdbg.log Hyprland
  -c …` for a per-recalc log (targets, active id, inserts).

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

**Run at most ONE nested instance at a time** (sway or Hyprland) unless a
test genuinely needs two side by side. Kill the previous one (exact pid)
before starting the next; leftovers pile up on `wayland-2`/`3`/... and
steal sockets.

**Spawn test clients INTO the nested instance, never onto the host.**
Shell-spawning `foot &` with a stale/empty `WAYLAND_DISPLAY` silently
lands the window on the host's active workspace (popping up on the user's
cursor) and corrupts the test. Canonical ways to spawn a client, all of
which target the nested instance's own active workspace:
- Hyprland: `hyprctl -i <sig> dispatch 'hl.dsp.exec("foot")'`
- sway: `swaymsg -s <SOCK> exec foot`
Only if you must shell-spawn, verify the socket variable is non-empty AND
belongs to the live instance first (`test -S /run/user/1001/<sock>` and
match it against `hyprctl instances`), and after spawning confirm the
window actually appeared via `hyprctl -i <sig> -j clients` / `get_tree` —
not via the "no error" of the spawn command.

**Never `pkill -x foot` (or any broad pkill of user-visible apps)** — it
kills the user's real terminals, including the one this session runs in.
To sweep nested test clients, iterate `pgrep -x foot` and kill only PIDs
whose `/proc/<pid>/environ` contains the nested instance's
`WAYLAND_DISPLAY=<socket>`.

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

### Implementation gotchas found the hard way (all hit, all verified)

- **Cross-monitor window moves use `hl.dsp.window.move({workspace=..., window=..., follow=...})`** — verified working (moves the window, `follow=true` keeps focus on it). The legacy route does NOT work in Lua-config builds: `hl.dsp.exec_raw('movetoworkspace 2')` returns `ok` and silently does nothing. `hl.dsp.window.move({direction=...})` is a *mouse drag* (legacy `movewindow`), not a window move — don't confuse them.
- **No shared coordinate space across workspaces/monitors.** On nested scale-2 outputs: `ctx.area` for ws1 = (20,20,191,215) but `hl.get_monitors()` reports WAYLAND-2 as x=468 w=461 while ws2's actual `ctx.area` = (488,20,191,215). Absolute pixel math across workspaces is wrong (it silently picks the wrong "nearest" window). Use scale-free center ratios (`centerRatios` in `layout.lua`); use monitor geometry ONLY for adjacency/ordering tests.
- **`HL.Monitor` exposes `width`/`height`, not `w`/`h`** — `m.w` is `nil` and geometry comparisons silently never match.
- **`hyprctl repl` return-value quirk:** a chunk whose last top-level statement is a `for` loop with an embedded `return` sometimes prints `ok` instead of the value; wrapping the logic in `local function f() ... end return f()` is reliable.
- **`hyprctl instances` signature capture:** the line is `instance <sig>:` — `awk '{print $2}'` and `sed 's/^instance //; s/:$//'` both keep the colon (the `p` command prints before the second substitution runs). Use `sed -n 's/^instance \([^:]*\):$/\1/p'`.
- **Cross-target active-workspace trap (M.4):** the cross target is the *target monitor's* active workspace at move time. If the source window sits on the target monitor's workspace (or any focus action first touches that monitor), the active ws switches back and the cross degenerates to `twid == wid` (no-op). Batteries must keep the crossing source on the OTHER monitor.

- **The layout_msg dispatcher is `hl.dsp.layout('<msg>')`** (source:
  `LuaBindingsDispatchers.cpp`, `hlLayout`/`dsp_layoutMsg`, registered in
  the `dsp` namespace). There is NO top-level `hl.layout(...)` function —
  `hl.layout` is the *registration* table; calling it in a bind gives
  `attempt to call a table value`. Also `hl.dsp.exec` does not exist —
  it is `hl.dsp.exec_cmd('foot')`.
- **`layout_msg` runs `recalculate()` itself after your callback returns**
  (C++ side); a `false`/string return surfaces as a dispatch error.
  Mutate state in `layout_msg`; don't call your own recalc.
- **Dispatcher objects cannot be called directly** —
  `hl.dsp.focus({...})()` fails with `dispatcher objects cannot be called
  directly; use hl.dispatch(dispatcher)`. From inside `layout_msg`, move
  focus with `hl.dispatch(hl.dsp.focus({ window = <HL.Window object> }))`.
- **Window selectors in this build: pass the `HL.Window` userdata, not a
  string.** `hl.dsp.focus({window = w.address})` and title strings both
  fail with `hl.focus: window not found` for live visible windows;
  `hl.dsp.focus({window = w})` works.
- **A map-time recalc reports the PRE-MAP focused window as
  `window.active`.** When window N maps, the recalc for it still shows N-1
  as active (focus settles on N after the recalc, and no follow-up recalc
  fires until the next event). Consequences:
  - the correct "insert after the focused window" anchor is exactly the
    `activeId` seen in that recalc (it IS the pre-map focus) — a
    remembered last-active is wrong;
  - any "sync remembered state to `activeId`" step must be skipped on
    passes that inserted a new window, or it clobbers the new window's
    focus mark.
- **Lua multi-return-value collapse:** `local r = rec(...); if r then
  return r end` returns only ONE value — a recursive tree search
  returning `(node, parent, index)` silently degrades to `(node, nil, nil)`
  for anything nested one level deep. Thread all values explicitly
  (`local r, p, i = rec(...)`). This bug made every nested container look
  empty to parent/index lookups.
- **`hyprctl instances` output format:** `instance <sig>:` — the
  signature line ends with a colon. `sed 's/^instance //; s/:$//'` when
  capturing it; a stray colon makes `hyprctl -i` fail with a socket path
  containing `:`.
- **`pgrep -f "Hyprland -c"` / `pkill -f …` self-match:** your own shell
  command line contains the pattern, so the kill list includes the shell
  running the command (it dies mid-script, output truncated, side effects
  partial). Kill nested instances by exact pid parsed from
  `hyprctl instances` instead.
- A brand-new nested instance's IPC socket is briefly unreachable
  ("Couldn't connect … (4)") for a couple seconds after it appears in
  `hyprctl instances` — retry, don't conclude it's hung.
- If a nested instance's log reports `Output WAYLAND-1: pending state
  rejected: invalid mode`, its windows stop mapping (clients connect,
  tree stays empty). Just kill and restart it.

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

### Dual outputs (for cross-monitor tests)

A nested Wayland-backend sway sees ONE output (WL-1) regardless of the
host's monitors. For dual-monitor work use the Xvnc + X11-backend setup —
full details, gotchas and the behavior spec in `notes/dual-monitor.md`:

```sh
Xvnc :99 -geometry 2560x720 & echo $! > /tmp/xvnc.pid
DISPLAY=:99 WLR_BACKENDS=x11 sway -c <config> &
swaymsg -s <sock> create_output            # NOT 'output add'
swaymsg -s <sock> 'output X11-1 mode 1280x720 position 0 0'
swaymsg -s <sock> 'output X11-2 mode 1280x720 position 1280 0'
```

or just `sh sandbox/run-dual-sway.sh`. Headless sway (`WLR_BACKENDS=headless`)
can make multiple outputs too, but has **no input devices**, so focus state
desyncs and focus-dependent batteries give silently wrong results — use it
never for anything focus-sensitive. Start a fresh sway per battery run
(empty workspaces get destroyed/recreated and scramble the layout).

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
