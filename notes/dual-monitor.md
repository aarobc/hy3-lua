# Dual-monitor testing environments + sway cross-monitor behavior

> **Setup note (superseded):** the nested/Xvnc *environments* described
> below have been replaced by the Docker setup in `environment/`
> (headless sway + headless Hyprland, pure-IPC interaction, dual outputs
> via `swaymsg create_output` / `hyprctl output create headless`). The
> **behavioral spec** (sway 1.12 cross-monitor move/focus/insert rules,
> verified against a real sway) is still the source of truth.

Research for the next step of `layout.lua`: emulating sway's window behavior
across monitors (edge moves with/without an adjacent monitor, insertion
rules on the far side). Everything below was verified hands-on on this
machine (sway 1.12, Hyprland 0.56.2, host Hyprland 3 physical monitors).
Raw tree dumps from the test batteries: `notes/dualmove-dumps/`.

## 1. Can we run a dual-display nested environment? Yes — three ways

**Key fact:** a nested compositor on the Wayland backend gets **one**
output per host socket (sway: `WL-1`; Hyprland: `WAYLAND-1`), regardless of
how many physical monitors the host Hyprland has. The host's 3 monitors are
not mirrored. So dual-display testing requires *virtual* outputs, created
inside the nested instance.

### 1a. Xvnc + sway X11 backend — THE WORKING ENVIRONMENT ✓

The only setup where seat-focus behaves correctly (see 1b for why the
alternatives fail).

```sh
# once:
Xvnc :99 -geometry 2560x720 &          # -screen/-SecurityType rejected by this build
echo $! > /tmp/xvnc.pid

# per test session (see sandbox/run-dual-sway.sh):
DISPLAY=:99 WLR_BACKENDS=x11 sway -c <config> &
SOCK=<newest /run/user/1001/sway-ipc.*>
swaymsg -s "$SOCK" create_output                          # adds X11-2
swaymsg -s "$SOCK" 'output X11-1 mode 1280x720 position 0 0'
swaymsg -s "$SOCK" 'output X11-2 mode 1280x720 position 1280 0'
```

- Real X inputs exist (`swaymsg -t get_inputs` → keyboard/pointer/touch), so
  `focus`/`move`/`kill`/`workspace` all act on a consistent focus state and
  the **window-level** `focused` flags in `get_tree` are trustworthy.
- The Xvnc screen stays 1024x768 (its `-geometry` is effectively ignored
  for the root window size that wlroots picks up initially), but the
  outputs resize fine via `output NAME mode WxH` — the second X output is
  just another X window, clipping irrelevant since we read state via IPC.
- A VNC client can attach to `:99` to watch the two "monitors" live.
- Spawning test clients: `swaymsg -s "$SOCK" exec 'foot -T NAME -- sleep 3600'`
  (a real shell clobbers the window title; `-- <cmd>` keeps `-T NAME`).

### 1b. sway headless — broken for focus-sensitive tests ✗

```sh
WLR_BACKENDS=headless sway -c <config> &
swaymsg create_output            # creates HEADLESS-2 (works!)
swaymsg 'output HEADLESS-2 mode 1280x720 position 1280 0'
```

- Outputs work fine (default `HEADLESS-1` 1280x720 appears at startup;
  `create_output` adds more; `mode`/`position` apply).
- **But the headless backend has zero input devices** (`-t get_inputs` is
  empty; sway 1.12 never calls `wlr_headless_add_input`, so `input type:`
  config lines don't help). Consequence: the seat's focus state desyncs —
  `focus`/`move` commands act on *stale* focus from a different
  workspace/monitor than the one you just switched to, and get_tree focus
  flags disagree with what commands actually do. Batteries against this
  environment produced silently wrong results (moves hitting the wrong
  window). Don't use it for anything focus-dependent.
- `/dev/uinput` is not accessible here (no sudo, no uinput group), so a
  virtual keyboard can't be injected either.

### 1c. Nested Hyprland — works for the layout under test ✓

This build has no headless backend (`--backend` flag doesn't exist), so use
a normal nested instance + fake output:

```sh
Hyprland -c ~/code/hy3-lua/sandbox/hypr-nested.lua &
hyprctl instances                              # newest sig = the nested one
hyprctl -i <sig> output create wayland         # -> WAYLAND-2, visible window
hyprctl -i <sig> output remove WAYLAND-2       # tears it down
hyprctl -i <sig> monitors                      # WAYLAND-1 @0,0 + WAYLAND-2 @387,0
```

- `hl.get_monitors()` (userdata list) exposes `name`, `x`, `y`, `width`,
  `height`, `focused`, `active_workspace` for **both** monitors — verified
  via `hyprctl -i <sig> repl`.
- Also available: `hl.get_monitor_at(x, y)`, `hl.get_active_monitor()`,
  `hl.get_workspace(s)`; `workspace.monitor` is an `HL.Monitor` object.
- `HL.LayoutContext` (the `ctx` in `recalculate`/`layout_msg`) does **not**
  carry a monitor field — map a workspace to its monitor via
  `target.window.workspace.monitor` or by matching `ctx.area` against
  monitor geometry. Adjacent-monitor lookup = geometry over
  `hl.get_monitors()`.
- Caveat: host keyboard focus wandering (normal desktop use) can perturb
  focus-sensitive nested state the same way as with 1a's visible nested
  sway; the X11/Xvnc setup above is preferred for sway-side spec work, and
  for Hyprland-side tests the layout's *own* state (not seat focus) is what
  matters, so it's tolerable.

### sway 1.12 CLI gotchas found while building all of this

- `create_output` is a **top-level dev command**. `swaymsg 'output add'`
  silently parses as an *output config line* for an output named "add"
  (log: "Config stored for output add").
- `focus` accepts only `direction|next|prev|parent|child|...` — there is no
  `focus [title=...]` criteria (parse error).
- `kill [title=...]` **ignores the criteria entirely** (source:
  `sway/commands/kill.c` never touches argv) — plain `kill` closes the
  focused window only.
- `output NAME ... position` wants space-separated coords via IPC
  (`position 1280 0`); `position 1280,0` fails with "Missing position
  argument (y)". In headless, `res WxH@60` errors with "Invalid mode
  refresh rate" — use `mode WxH`.
- get_tree: **window-level** `focused` is reliable (with real inputs
  present); output/workspace-level `focused` reports `false` even while a
  window there is focused (seat not keyboard-focused).
- `workspace N` when N doesn't exist **creates it on the current output**;
  empty workspaces are destroyed when focus leaves them; `workspace N`
  **never moves** a workspace between outputs (only
  `move workspace to output NAME` does). These three rules are what make
  naive "clean up then run" scripts corrupt the monitor/workspace layout —
  always start a **fresh sway instance per battery run**
  (`sandbox/run-dual-sway.sh` does this).

## 2. Sway cross-monitor behavior (sway 1.12, empirically verified)

Test harness: `sandbox/dualmove_battery.py` (cases M.*, F.*) and
`sandbox/insert_battery.py` (cases X.*), run via `sandbox/run-dual-sway.sh`
against a fresh dual-output instance: X11-1 (left, ws "1") / X11-2 (right,
ws "2"). Dumps: `notes/dualmove-dumps/<case>.txt`.

### 2.1 `move <dir>` at the workspace edge

- **M.1 (cross):** window at the rightmost edge of the rightmost monitor's
  workspace, `move right` → the window moves to the **active workspace** of
  the adjacent right monitor. It is inserted at **index 0 of the target
  workspace's root container** ("entry edge" — the side it came from).
  Focus follows the moved window.
- **M.2 (screen edge):** `move left` at the left edge of the leftmost
  monitor → **no-op**. Window, tree, and focus unchanged.
- **M.1b (entry edge, not focused child):** target ws2 = [B, C] with **C**
  focused; A crosses right → result [A, B, C]. The newcomer lands at index
  0, *not* at the focused child's index (which would be [B, A, C]).
- **M.3 (empty target):** crossing into an empty active workspace → window
  becomes the sole window, `percent` 1.0, focus follows.
- **M.4 (which target ws):** the target is the **active workspace of the
  target monitor even if it is empty**. With ws2 (has a window) and ws3
  (empty) on the right monitor, and ws3 active, the crossed window lands on
  ws3, not ws2.
- **M.5a/b (nested target focus, horizontal root):** target root =
  [E, W1(F, G)] (W1 a splitv container) with focus **inside W1** (on G or
  on F) → the crossed window still lands at **root index 0**:
  [H, E, W1(F, G)]. Deep target focus does not pull the insertion inward.
- **X.1 (leftward cross):** `move left` from the leftmost window of the
  right monitor's workspace → appended at the **END** of the target's
  horizontal root ([L] → [L, T1]). Symmetric entry-edge rule.
- **X.4 (vertical root target):** target ws root is **splitv** [V1 / V2]
  with V2 (index 1) focused; `move right` into it → [V1, M4, V2] — inserted
  **at the focused child's index** of the root. So: *when the target root's
  axis is perpendicular to the move direction, insertion falls back to the
  focused child's index* (a rightward move has no "left edge" in a vertical
  list).

### 2.2 Promotion at container edges (feeds cross-move design)

- **M.6:** ws2 = [E, W1(F, G)], focus **F** (top child of W1), `move left`:
  F has no left sibling inside W1 → **F is pulled out of W1 to the
  workspace root at W1's position**: [E, F, W1(G)]. W1 keeps the rest and
  all three root children renormalize. (A `move` on a leaf with no sibling
  in that direction acts on the leaf, not on its container — the container
  is never moved as a whole.)

### 2.3 `focus <dir>` at edges (F.*)

- **F.1:** `focus right` past the workspace edge **crosses the monitor**:
  focus goes to the geometrically nearest window on the target monitor's
  active workspace — with ws2 = [E, F, W1(G)], focus landed on **E**
  (leftmost top-level window).
- **F.2:** crossing into an **empty** workspace focuses the **workspace
  node** itself (no window gets focused).
- **F.3:** at the true screen edge (no adjacent monitor) → no-op.

### 2.4 Percent semantics on cross

- In every observed cross, the target root's children ended up with an
  **equal** split after insertion (2×0.5 → 3×⅓; 1×1.0 → 2×0.5). All
  tested pre-cross states happened to have equal siblings, so "does an
  unequal pre-existing split get preserved or flattened on cross?" is still
  **open** (see below).

### 2.5 Open questions (follow-up battery)

1. Cross into a target root with **unequal** sibling percents — preserved
   (newcomer takes the focused child's slot, ratios renormalized) or
   flattened to equal?
2. Leftward cross into a **vertical-root** target — focused-child index too?
3. "Nearest window" for F.1 in complex trees: leftmost top-level, or
   corner-based? (Only the simple case has been tested.)
4. Vertical adjacency: same rules with a monitor *below* (`position 0,720`)
   for `move up/down` + `focus up/down` edge crossing.
5. Cross-move *out* of a workspace whose window was promoted the same tick
   (M.6 + cross combination) — does a leaf at a nested-container edge
   crossing the monitor promote first and then cross?

## 3. Hyprland-side notes for the implementation

- Monitor geometry / adjacency: `hl.get_monitors()` + `hl.get_monitor_at`;
  "adjacent monitor in direction" = geometry test against the moving
  window's workspace rect (or monitor rect).
- Cross-move in `layout_msg('move …')`:
  - target = the *other monitor's active workspace* (M.1/M.4);
  - if none → no-op (M.2/F.3);
  - insertion: target root horizontal & axis-aligned with the move →
    index 0 (rightward) / end (leftward) (M.1/X.1); target root
    perpendicular → focused child's index (X.4);
  - state migration: remove the window's node from the source workspace's
    persisted tree, insert into the target workspace's tree, renormalize
    percents, then `recalculate` on both workspaces and
    `hl.dispatch(hl.dsp.focus({window = <HL.Window>}))`.
- `move` at a nested-container edge (M.6 promotion) is part of the *single*-
  monitor algorithm (B-spec) and interacts: a promoted leaf is then
  root-level, so a *subsequent* edge move can cross (open Q5).

## 4. Implementation status (hy3-lua, `layout.lua`)

Implemented and re-verified on the Hyprland side with
`sandbox/cross_battery.sh` (2-output nested instance via
`hyprctl output create wayland`); all of the following PASS on the
Hyprland layout, not just sway:

- **M.1 / M.1b** — cross to entry edge (index 0 right/down), even when
  the target's focus is elsewhere; equal renormalize of the target root.
- **M.2** — screen edge → no-op.
- **M.3 / M.4** — cross into the target monitor's *active* workspace
  even when it is empty; sole child frac 1.0; focus follows.
- **X.1** — leftward cross appends at the END of a parallel target root.
- **X.4** — perpendicular target root → focused root child's index.
- **F.1** — focus cross to the nearest window; implemented as a
  **Euclidean distance on absolute rendered window centers**
  (`winCenter` in `src/hy3.lua`). (Correction: an earlier version used a
  scale-free center-ratio distance because of a belief that absolute pixel
  math across workspaces was wrong — that belief applied to `ctx.area`, not
  to rendered window geometry. Window `at`/`size` *are* in a shared absolute
  screen space across monitors, so the ratio pick was actually the bug: it
  matched an edge window on the source monitor to the *far-side* window on
  the target monitor. Absolute centers pick the boundary-adjacent window.)
- **F.2 / F.3** — empty target / screen edge → no-op.

Mechanics and gotchas found during implementation:

- The real window migration is `hl.dsp.window.move({ workspace = <name>,
  window = <HL.Window>, follow = true })`. `follow=true` keeps focus on
  the moved window (M.1). The legacy `movetoworkspace <ws>` via
  `hl.dsp.exec_raw` **silently no-ops** in Lua-config builds. The tree
  must be migrated BEFORE the dispatcher call, otherwise the target
  workspace's post-move recalc re-inserts the window at the focus
  anchor instead of the planned slot.
- **`ctx.area` is not a shared coordinate space** between workspaces
  (or with `hl.get_monitors()`): on nested scale-2 outputs, ws1's
  `ctx.area` = (20,20,191,215) while WAYLAND-2 reports x=468 w=461 and
  ws2's `ctx.area` = (488,20,191,215). So **layout math** (fraction → box)
  must stay scale-free per workspace. But a window's **rendered**
  `at`/`size` ARE shared absolute screen coords across monitors, so
  cross-monitor "nearest window" uses absolute window centers, and monitor
  geometry is only for adjacency/ordering.
- **Crossing beats wrapping** for `focus <dir>` (sway tries the
  adjacent output before `focus_wrapping`). The layout wraps only at
  the true screen edge; single-monitor wrap behavior is unchanged.
- `HL.Monitor` fields are `width`/`height` (not `w`/`h`).
- `hl.get_monitor_at(x, y)` exists but was not needed.

Open questions that REMAIN open for the Hyprland side (same list as
§2.5, plus):
6. Focus-cross "nearest" in complex (deeply nested) target trees —
   absolute window-center distance vs sway's exact `con_closest_in_direction`.
7. Cross into a target root with **unequal** sibling percents — the
   battery only exercises equal pre-cross splits (Q1).

## 5. Tooling added (sandbox/)

- `run-dual-sway.sh` — kills the old instance, starts fresh Xvnc-backed
  dual-output sway, runs the battery, leaves sway running
  (sock in `/tmp/xsw.sock`, pid in `/tmp/xsw.pid`, Xvnc pid in
  `/tmp/xvnc.pid`).
- `tree_dump.py <sock> [-v]` — compact get_tree dumper (outputs, workspaces,
  containers with percents/rects/focus marks).
- `dualmove_battery.py <sock> <outdir>` — M.* / F.* battery (fresh instance
  required; asserts the layout and fails loudly otherwise).
- `insert_battery.py <sock> <outdir>` — X.* battery (X.1 and X.4 are valid;
  X.2/X.3 have a seeding bug — their windows landed on the wrong
  workspace — ignore those two dumps).
- `notes/dualmove-dumps/` — all raw dumps from the last runs.

**Current live state at time of writing:** nothing left running — the
follow-up cross-monitor implementation work (section 4) used a
2-output nested Hyprland instance, which was killed along with its test
clients afterward.
