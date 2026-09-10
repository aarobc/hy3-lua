# sway 1.12 empirical behavioral spec

Purpose: exact observed behavior of sway 1.12 for window insertion,
movement (`move left/right/up/down`), closure, and split-orientation
bookkeeping — the reference for the Hyprland Lua layout in `layout.lua`.

Every case was run against a real nested sway 1.12 with `foot` clients,
verified via `swaymsg -t get_tree` dumps, and cross-checked against the
sway 1.12 source (tag `1.12`: `sway/tree/container.c`,
`sway/commands/move.c`, `sway/commands/split.c`, `sway/tree/arrange.c`,
`sway/tree/view.c`, `sway/commands/focus.c`, `sway/config.c`).

## Setup

- Live session: Hyprland 0.56.2 on `wayland-1`; nested sway is an ordinary
  Wayland client of it.
- Start: `sway -c /home/mork/code/hy3-lua/sandbox/sway-nested.config &`
  (nested sway pid **413688**).
- IPC: `SOCK=/run/user/1001/sway-ipc.1001.413688.sock`; everything via
  `swaymsg -s "$SOCK" ...`.
- Nested sway's Wayland socket: **wayland-2** (in `/run/user/1001/`; NOT
  visible in `hyprctl instances`, which only lists other Hyprland
  instances). Test clients: `WAYLAND_DISPLAY=wayland-2 foot &` or
  `swaymsg exec foot`.
- Sandbox config: `default_border none`, `gaps inner 4`.
- Workspace-1 rect: `4,4 1883x2078` for A.1–A.3, `4,4 2509x2078` for the
  rest (nested window was resized once early on). Percent reported by
  `get_tree` = child main-axis px / parent main-axis px (parent includes
  gap space); the last child absorbs rounding, so siblings sum to slightly
  < 1.0 (e.g. 0.4994+0.4990=0.9984).

Dump helper (inline, piped from `swaymsg -t get_tree`; prints the
workspace-1 subtree with name/layout/ori/rect/pct/app and `*FOC*`):

```sh
dump() { swaymsg -s "$SOCK" -t get_tree | python3 -c "
import json,sys
def find_ws(n):
    if n.get('type')=='workspace' and n.get('name')=='1': return n
    for c in n.get('nodes') or []:
        r=find_ws(c)
        if r: return r
ws=find_ws(json.load(sys.stdin))
def line(n,ind=0):
    r=n['rect']
    s='  '*ind+n['type']+' name='+repr(n.get('name'))+' layout='+str(n.get('layout'))+' ori='+str(n.get('orientation'))+' rect=%d,%d %dx%d'%(r['x'],r['y'],r['width'],r['height'])
    p=n.get('percent')
    if p is not None: s+=' pct=%.4f'%p
    if n.get('app_id'): s+=' app='+n['app_id']
    if n.get('focused'): s+=' *FOC*'
    print(s)
    for c in n.get('nodes') or []: line(c,ind+1)
if ws: line(ws)
else: print('(no workspace 1)')"; }
```

Windows open identically (`foot`); distinguished by position, percent and
title (shell-spawned foots show cwd `~/code/hy3-lua`, `swaymsg exec foot`
shows `/tmp`). Cleanup between cases: kill tracked foot PIDs; shell-spawned
foots get reparented to init when their bash exits, so the reliable sweep
is `pgrep -x foot` + checking `/proc/$p/environ` for
`WAYLAND_DISPLAY=wayland-2`.

Dumps below are abbreviated: only layout/orientation/pct/focus matter.

---

## A. NEW WINDOW INSERTION

### A.1 — two windows, default orientation

```sh
WAYLAND_DISPLAY=wayland-2 foot &   # #1
WAYLAND_DISPLAY=wayland-2 foot &   # #2 (focus)
```
```
ws splith: [0.4992] [0.4987 *FOC*]        # 940px / 939px @1883
```
**Conclusion:** default is side-by-side (`splith`); a sole window sits at
pct 1.0000.

### A.2 — right window focused, open #3 (NO wrap)

```
BEFORE: [0.4992] [0.4987 *FOC*]
exec foot
AFTER:  [0.3319] [0.3319] [0.3319 *FOC*]   # 625px each, all direct ws children
```
**Conclusion (contradicts the task's expectation):** a plain open does
**not** wrap the focused leaf. The new window is inserted as a **sibling
immediately after the focused window** in its parent's child list, and all
children are re-sized: the newcomer's fraction starts at 0 and at layout
time is set to the **average of the existing siblings' fractions**, then all
fractions renormalize to sum 1. With equal siblings this looks like
"all 1/n". The CLAUDE.md "wrap mechanic" only appears when `splitv`/`splith`
was run first (A.4). Supplemental: with the LEFT window focused, the
newcomer inserted in the MIDDLE — confirms "after the focused window".

### A.3 — repeated opens (rightmost focused each time)

```sh
for i in 4 5 6; do swaymsg focus right; swaymsg exec foot; done
```
```
after #4: 0.2485 0.2485 0.2485 0.2480        (468,468,468,467 px @1883)
after #5: 0.1981 0.1981 0.1981 0.1981 0.1992 (373,373,373,373,375)
after #6: 0.1652 0.1652 0.1652 0.1652 0.1652 0.1636 (311x5,308)
```
**Conclusion:** each open appends after the focused (rightmost) window and
re-equalizes the row in pixel space: `(W-(n-1)*gap)/n` each; no wrappers
ever appear without an explicit split.

### A.4 — armed `splitv` then open

```sh
# X | Y, Y (right) focused
swaymsg splitv;  swaymsg exec foot
```
```
after splitv: [X 0.4994] [W splitv 0.4990: [Y 1.0000 *FOC*]]
after exec:   [X 0.4994] [W splitv 0.4990: [Y 0.4990] [Z 0.4990 *FOC*]]
```
**Conclusion:** `splitv` on a leaf wraps it in an anonymous container
(`name=null`) that takes the leaf's **exact percent and slot**; the leaf is
inside at pct 1.0 and still focused. The new window joins the wrapper as
second child (50/50); the outer sibling is untouched.

### A.5 — armed `splith` then open

```
after splith+exec: [X 0.4994] [W splith 0.4990: [Y 0.4984] [Z 0.4984 *FOC*]]
```
**Conclusion:** identical mechanic, horizontal wrapper.

### A.6 — PERSISTENCE (the key case)

Build `[W1 | [W2 over W3]]` (open W1, W2; `splitv` on W2; exec W3). Then:
1. `focus up` (→W2), plain `exec foot` (W4), **no arming**:
```
[W1 0.4994] [W splitv 0.4990: [W2 0.3321] [W4 0.3321 *FOC*] [W3 0.3321]]
```
2. `splitt` (togglesplit) with W4 focused (parent vertical):
```
[W1 0.4994] [W splitv 0.4990:
  [W2 0.3321] [WH splith 0.3321: [W4 1.0000 *FOC*]] [W3 0.3321]]
```
3. `exec foot` (W5), W4 focused inside the new H wrapper:
```
  [WH splith 0.3321: [W4 0.4984] [W5 0.4984 *FOC*]]
```
**Conclusions:**
- Opening into an existing container creates **no wrapper**: the new window
  joins the focused window's parent container immediately after the focused
  window; orientation = the container's own (VERT). "Container inheritance"
  = "lands as sibling of the focused window". Children renormalize to 1/3.
- `togglesplit` on a leaf whose parent is vertical splits **horizontal**:
  wraps that leaf in an H container (inheriting its fraction) at its slot.
- The next open joins the innermost container holding the focused window —
  here the fresh H wrapper.

---

## B. MOVEMENT

### B.7 — base swap

```
BEFORE: [A 0.6987 *FOC*] [B 0.2997]     # unequal percents (via resize)
move right
AFTER:  [B 0.2997] [A 0.6987 *FOC*]
```
**Conclusion:** adjacent sibling swap in the sibling list; **percents travel
with the windows**; the moved window keeps focus.

### B.8 — move INTO a container (A | [B1 over B2], focus A, move right)

Build: A, B1 flat; `splitv` on B1; exec B2 → `A | W[B1 over B2]`.
```
BEFORE: [A 0.4994] [W splitv 0.4990: [B1 0.4990] [B2 0.4990 *FOC*]]
focus left   # A
move right
AFTER:  [W splitv 1.0000: [B1 0.3321] [A 0.3321 *FOC*] [B2 0.3321]]
```
Variant B.8b — B1 (top) focused in the pair before `move right`:
```
AFTER:  [W splitv 1.0000: [A 0.3321 *FOC*] [B1 0.3321] [B2 0.3321]]
```
**Conclusion:** moving into a container perpendicular to the direction:
sway descends to the target's **focused child** and inserts the mover **at
that child's index (right/down) or index+1 (left/up)** — adjacent to the
focused child, pushing it and later siblings back. Neither "always first"
nor "always last": B2-focused → A lands MIDDLE; B1-focused → A lands FIRST.
Mover's fraction resets to 0 → 1/3 each; the v-container (now sole
top-level) renormalizes to 1.0.

### B.9 — mirror ([B1 over B2] | A, focus A, move left)

Build: flat B1,B2,A → `splitv` on B2 → `move right` with B1 →
`[W[B1 over B2]] | A`, A focused.
```
BEFORE: [W splitv 0.4994: [B1 0.4990] [B2 0.4990]] [A 0.4990 *FOC*]
```
- top child (B1) focused in pair, `move left`:
  `AFTER: [W splitv 1.0000: [B1 0.3321] [A 0.3321 *FOC*] [B2 0.3321]]` (MIDDLE)
- bottom child (B2) focused in pair, `move left`:
  `AFTER: [W splitv 1.0000: [B1 0.3321] [B2 0.3321] [A 0.3321 *FOC*]]` (LAST)

**Conclusion:** symmetric to B.8: mover inserts right after the target's
focused child (index+1 for left moves).

### B.10 — orthogonal parent ([B1 over B2] | A, focus B1, move left)

```
BEFORE: [W splitv 0.4994: [B1 0.4990 *FOC*] [B2 0.4990]] [A 0.4990]
move left
AFTER:  [B1 0.3324 *FOC*] [W splitv 0.3324: [B2 1.0000]] [A 0.3320]
```
**Conclusion:** the whole container does NOT swap. B1's parent W is
orthogonal to the move → sway crawls up to W's parent (workspace,
parallel): no sibling left of W → B1 is **promoted** to workspace level,
inserted just left of its own parent container. W stays put as a **1-child
vertical** container. B1's and W's fractions reset to 0 → 1/3 each.

### B.11 — deep move ([[A | [B1 over B2]] | C], focus C, move left)

Build: flat A,B1; `splitv` on B1; exec B2; `focus parent` ×2 (→ workspace);
`splith` (workspace split wraps `[A | W]` into H container W2; focus lands
on W2); open C (W2 focused → C appended at top level).
```
BEFORE: [W2 splith 0.4994: [A 0.4988] [W splitv 0.4980: B1 0.4990 / B2 0.4990]] [C 0.4990 *FOC*]
move left
AFTER:  [W2 splith 1.0000: [A 0.3324] [W splitv 0.3324: B1 0.4990 / B2 0.4990] [C 0.3320 *FOC*]]
```
**Conclusion:** moving into a container PARALLEL to the direction: inserted
**inside** it at the edge it came from — left → appended at the END (last
child); right → index 0 (first child). C became the **last** child of the H
container; W2 renormalizes to 1.0.

### B.12 — crawl up (same tree, focus B1 inside the pair, move left)

State restored to `[[A | [B2 over B1]] | C]`, B1 focused:
```
BEFORE: [W2 splith 1.0000: [A 0.3324] [W splitv 0.3324: B2 0.4990 / B1 0.4990 *FOC*] [C 0.3320]]
move left
AFTER:  [W2 splith 1.0000: [A 0.2487] [B1 0.2487 *FOC*] [W' splitv 0.2487: [B2 1.0000]] [C 0.2491]]
```
**Conclusion:** B1's parent W is orthogonal → crawl up to W2 (parallel):
there IS a sibling left of W (A) → B1 is inserted **as a child of W2, right
after A** (index(A)+1 for left), i.e. left of its own parent container. W
remains a 1-child vertical container in its old slot. B1 and W fractions
reset to 0 → all four W2 children ~1/4.

### B.13 — edge no-op (A | B, focus leftmost, move left)

```
BEFORE: [0.2997 *FOC*] [0.6987]
move left        # returns success:true
AFTER:  [0.2997 *FOC*] [0.6987]     # identical
```
**Conclusion:** past-the-end at workspace level = no-op on single output
(sway tries a cross-output hand-off; none exists).

### B.14 — vertical pair only (A over B, focus A) — NOT a no-op

Build: sole window + `splitv` (singleton rule flips the WORKSPACE to
splitv, no wrapper) + open second.
```
BEFORE: ws splitv: [A 0.4990 *FOC*] over [B 0.4990]
move left  -> ws splith: [A 0.4994 *FOC*] [W splitv 0.4990: [B 1.0000]]
move right -> ws splith: [W splitv 1.0000: [A 0.4990 *FOC*] [B 0.4990]]
move down  -> ws splith: [W splitv 1.0000: [B 0.4990] [A 0.4990 *FOC*]]
```
**Conclusions:** when no ancestor is parallel to the direction, sway
**re-orients the workspace** (wraps current top-level children in a new
container, sets workspace layout to the move direction) and promotes the
window to top level (left of its former wrapper for `move left`); the
subsequent `move right` re-inserts A at the top of the vertical container
holding B (the focused child it descends into). Only out-of-range moves at
workspace level with no parallel ancestor (B.13) are true no-ops.
`move down` in the stack = plain swap.

### B.15 — cross-orientation ([A1|A2] over [B1|B2], focus B1, move up)

Build: A1,A2 flat; `move down` on A2 (workspace wraps+re-orients to splitv);
open into W0 → `[A1|A2]` top pair; `splith` on lone bottom + open → two H
pairs stacked.
```
BEFORE: ws splitv: [W0 splith 0.4990: A1 0.4994 / A2 0.4990]
                     [W1 splith 0.4990: B1 0.4994 *FOC* / B2 0.4990]
move up
AFTER:  ws splitv:  [W0 splith 0.4990: A1 0.3324 / A2 0.3324 / B1 0.3320 *FOC*]
                     [W1 splith 0.4990: B2 1.0000]
```
**Conclusion:** B1's parent (W1, horizontal) orthogonal to UP → crawl up to
workspace (vertical, parallel) → target W0 (horizontal = perpendicular to
UP) → descend into W0's focused child (A2, last focused there) → B1
inserted **after A2 = last slot of the top pair**. W1 left as 1-child H
container (inner pct 1.0). Top pair renormalizes to thirds.

### B.16 — focus follows move

Verified in every move case above: the moved window carries `*FOC*`
(`"focused": true` in the raw tree) after each `move`.

---

## C. CLOSURE / PERCENT REDISTRIBUTION

### C.17 — close one of two (A | B, focus A, kill)

```
BEFORE: [A 0.4994 *FOC*] [B 0.4990]
swaymsg kill
AFTER:  [B 1.0000 *FOC*]
```
**Conclusion:** sole survivor renormalizes to pct 1.0 and gets focus.

### C.18 — three siblings in one H container, close the MIDDLE

Build: A, B1 flat; `splith` on B1; exec B2; `focus parent`, `focus left`
(→A), `move right` → A joins the H container at index 0 (parallel → first
child): `[W splith 1.0: A 0.3324 / B1 0.3324 / B2 0.3320]`.
```
focus right   # middle (B1)
swaymsg kill
AFTER: [W splith 1.0000: [A 0.4994 *FOC*] [B2 0.4990]]
```
**Conclusion:** remaining siblings keep their stored fractions and
**renormalize proportionally** to sum 1 (1/3 + 1/3 remaining → 50/50). The
neighbor does NOT "absorb" the closed share asymmetrically. Focus → the
left neighbor of the closed window.

### C.19 — container collapse ([[A1|A2] | [B1|B2]])

Build: A1, A2 flat; `splith` on A1 (→ W0 H[A1] at index 0); exec → W0 H[A1,
A2]; `focus right` (→ lone B1), `splith` (→ W1 H[B1]); exec → W1 H[B1, B2].
```
BEFORE: [W0 splith 0.4994: A1 0.4988 / A2 0.4980] [W1 splith 0.4990: B1 0.4984 / B2 0.4984]
focus A2 (2nd child of W0); swaymsg kill
AFTER:  [W0 splith 0.4994: [A1 1.0000 *FOC*]] [W1 splith 0.4990: B1 0.4984 / B2 0.4984]
swaymsg kill      # A1
AFTER:  [W1 splith 1.0000: [B1 0.4994 *FOC*] [B2 0.4990]]
```
**Conclusions:**
- Closing A2 leaves W0 as a **1-child container — it is NOT flattened**
  (A1's inner pct renormalizes to 1.0000; W0's outer pct 0.4994 unchanged).
- Closing A1 empties W0 → the empty container **is reaped**; W1 takes over
  the workspace (pct → 1.0000) with its inner percents unchanged
  (0.4984/0.4984 → 0.4994/0.4990 after outer renormalization).

### C.20 — focus after close

- close MIDDLE of 3 flat → LEFT neighbor focused (C.18).
- close LAST of 3 flat → the (middle) left neighbor focused:
```
[A 0.3324] [B 0.3324] [C 0.3320 *FOC*]  --kill-->  [A 0.4994] [B 0.4990 *FOC*]
```
- close FIRST of 2 → the remaining sibling focused (C.17).
- close a container's last member (W0 gone in C.19) → focus falls to the
  previously-focused view one level up (B1, inside sibling W1).

Rule of thumb: focus goes to the sibling **immediately before** the closed
window in its parent's list, else the next sibling, else up a level.
(Task notes this as not critical for the layout.)

---

## D. ORIENTATION BOOKKEEPING

### D.21 — move B1 out of [B1 over B2]; remaining container; next open

State from B.10-style move: `[A 0.3324] [B1 0.3324 *FOC*] [W splitv 0.3320: [B2 1.0000]]`.
```
# W is still VERTICAL with ONE child (inner pct 1.0000), orientation unchanged
focus into W (focus right from B1 -> descends to B2); exec foot:
AFTER:  [A 0.2487] [B1 0.2487] [/tmp 0.2487 *FOC*]  [W splitv 0.2491:
          [B2 0.4990] [NEW 0.4990 *FOC*]]
```
(Caution: `focus down` from a TOP-LEVEL window in an all-horizontal tree is
a no-op — there is no vertical ancestor; enter W via the horizontal
direction that descends into it.)
**Conclusions:** a container left with one child **keeps its orientation**
(vertical here) and its slot; a new window opened with the remaining child
focused **joins that vertical container** (VERT inherited from the
container), 50/50.

### D.22 — `togglesplit` on a bare leaf at the workspace root

```
BEFORE: ws splith: [A 1.0000 *FOC*]          # sole window
swaymsg splitt
AFTER:  ws splitv: [A 1.0000 *FOC*]          # NO wrapper — the workspace
                                              # node itself flipped to splitv
open 2nd window:
AFTER:  ws splitv: [A 0.4990] over [B 0.4990 *FOC*]
```
Bonus: with the top window focused, `splitt` again (parent ws now V):
```
AFTER:  ws splitv: [WH splith 0.4990: [A 1.0000 *FOC*]] over [B 0.4990]
```
**Conclusions:** `togglesplit` = "split with the opposite of the focused
container's parent layout" (parent V → H, else → V). On a bare leaf that is
the **sole child** of its parent, no wrapper is created — the parent's (or
workspace's) layout is simply rewritten (singleton rule), so the "container"
in the dump is the workspace node itself. With 2+ children present, a
wrapper IS created (as in the bonus).

---

## SUMMARY OF BEHAVIORAL RULES

Data structures: the workspace has a `layout` (H or V; sticky) and a flat
n-ary child list. Containers are anonymous nodes with a `layout` (H or V)
and a flat child list. Every non-workspace container and window carries a
main-axis `fraction` (the "percent" in dumps, recomputed from pixels at
arrange time). There is no notion of percent stored separately from the
node — the node carries it.

### (a) New-window insertion

1. Target = the focused node of the active workspace (deepest focused
   container — normally a window; can be a container right after
   `focus parent` / workspace-split).
2. The new window is inserted into the target's **sibling list
   immediately after the target** (`container_add_sibling(target, new, 1)`):
   - focused node is a window inside container C → new window joins C
     (orientation = C's — this is the "container inheritance");
   - focused node is a top-level window/container → new top-level sibling
     (orientation = workspace layout);
   - empty workspace → first top-level child.
   A new window is NEVER auto-wrapped; a wrapper only exists if a prior
   split created one around the focused window.
3. The new window's fraction is 0. At the next arrange of its parent:
   every child with fraction <= 0 gets `(sum of existing positive
   fractions) / (count of existing children)` — the average share of the
   existing siblings — then ALL fractions are normalized to sum 1. The last
   child absorbs pixel rounding (gaps: (n-1) inner gaps subtracted before
   division). Equal existing siblings ⇒ everyone becomes 1/n.
4. Armed split (`splitv`/`splith` before the open) = `container_split` on
   the focused window:
   - if the window is the SOLE child of its parent (or the sole top-level
     window): NO wrapper; the parent's (or workspace's) layout is
     rewritten to the armed orientation;
   - otherwise: a new container with the armed layout replaces the window
     in its slot, inheriting its exact fraction/position; the window sits
     inside at fraction 1.0, still focused. The following open then lands
     in that wrapper as second child (50/50).
5. Orientation source, in priority order: (1) the innermost container
   containing the focused window (whatever its layout is); (2) if the
   focused window is top-level, the workspace layout; (3) for a brand-new
   workspace, default `splith` (config `default_orientation` can change
   this).
6. The new window receives focus.

### (b) Movement (`move <dir>` on the focused tiled container)

1. Walk up from the mover while the current node's parent layout is NOT
   parallel to the direction (V parent + left/right ⇒ crawl up; H parent +
   up/down ⇒ crawl up).
2. At the first parallel level (node C, parent P, direction dir):
   - desired slot = index(C) ± 1 (dir).
   - If a target sibling exists:
     - C is the mover itself (P is the mover's direct parent):
       target is a window ⇒ **swap list positions**; each window keeps its
       own fraction (percents travel with the windows).
     - C is an ANCESTOR (mover crawled up): the target is a "cousin" (a
       sibling of C). The mover is re-parented next to it, on the side it
       came from, with its **fraction reset to 0**:
       - target is a window: inserted into the target's parent at
         `index(target) + (dir is left/up ? 1 : 0)`;
       - target is a container PARALLEL to dir: inserted as a child of it
         at index 0 (right/down) or end (left/up);
       - target is a container PERPENDICULAR to dir: recurse into the
         target's **focused (last-active) child** and apply the window
         case (insert adjacent to that child: at its index for
         right/down, index+1 for left/up); repeat if that child is itself
         a container.
   - If no target sibling exists at that level:
     - C is the mover and it is top-level (workspace level): attempt
       cross-output hand-off in dir; no adjacent output ⇒ **no-op**.
     - C is the mover and nested: crawl up one more level.
     - C is an ancestor: **promote** — insert the mover as a child of C's
       parent (or top-level if C is top-level) at
       `index(C) + (dir is left ? 0 : 1)` — adjacent to its own parent
       container, on the side moved. The mover's fraction AND C's fraction
       are reset to 0.
3. If the crawl reaches "no parent and workspace layout not parallel"
   (no parallel ancestor at all): wrap ALL current top-level children in a
   new container (inheriting the old workspace layout), set the workspace
   layout to the direction's layout, and continue — in practice this
   promotes the mover to top level next to its (now single-child) former
   wrapper, re-orienting the workspace.
4. After the move: empty (0-child) ancestors are reaped upward; a
   `workspace_squash` then merges the specific redundant pair "V container
   with a single H-container child whose grandparent layout is
   horizontal" (grandchildren move up, both wrappers die). All other
   1-child containers PERSIST (no general flattening; the only explicit
   flatten is `split none`).
5. Percents during moves: mover's fraction reset to 0 in every
   re-parenting/promotion (it then gets the average of its new siblings'
   fractions, renormalized); plain sibling swaps keep each window's
   fraction; the affected containers' own fractions are renormalized at
   arrange (a sole child becomes 1.0).
6. The moved window keeps focus.

### (c) Closure

1. The closed window is removed from its parent's list.
2. 0-child ancestor containers are reaped upward (an emptied container dies
   and its parent may die too); 1-child containers PERSIST (child's inner
   fraction renormalizes to 1.0; outer fraction untouched while siblings
   remain).
3. Remaining siblings keep their stored fractions; at arrange they are
   normalized to sum 1 — i.e. the closed share is distributed
   **proportionally** among the survivors (equal case: renormalize to
   1/(n-1) each; sole survivor: 1.0).
4. The workspace layout survives losing all children.
5. Focus after close: the sibling immediately before the closed window in
   its parent's list; if the closed window was first, the next sibling; if
   the whole parent container died, the previously-focused view one level
   up. (Not critical for the layout.)

### (d) Orientation persistence

1. Every container's layout (H/V) is sticky: it is changed only by an
   explicit split/togglesplit on one of its children (which wraps that
   child in a new container of the other orientation), by the squash rule
   above, or by `split none`.
2. The workspace layout is likewise sticky (persists across all closures).
3. A new window's orientation is determined by the container it lands in
   (a) — orientation is a property of containers, never re-chosen per
   window, except via pre-armed splits.
4. `splitv`/`splith` on a leaf: sole-child-of-parent ⇒ rewrite the parent's
   (or workspace's) layout, no new node; otherwise ⇒ new wrapper node with
   the given layout, inheriting the leaf's fraction and slot.
5. `togglesplit` (`splitt`): split with the opposite of the focused
   container's PARENT layout (parent V ⇒ split H; parent H or none ⇒ split
   V) — then apply rule 4.

### Focus movement (supplemental, used by the tests)

- `focus <dir>` wraps at edges by default (`focus_wrapping` default yes):
  past the end of a parallel sibling list it wraps to the opposite end —
  but only if no higher parallel level provides a target first (crawling
  up wins over wrapping).
- `focus parent` moves focus to the parent container; directional focus
  from a container descends into its last-active child.
- Directional focus with no parallel ancestor at all and no adjacent output
  is a no-op (e.g. `focus down` in an all-horizontal tree).

## Ambiguous / surprising / not tested

- **A.2 vs the task hypothesis:** the "focused leaf gets wrapped on plain
  open" mechanic does NOT exist in sway 1.12 — plain opens always insert a
  sibling after the focused node. Wrappers come exclusively from
  split/togglesplit (and from move-induced re-parenting).
- **B.14 vs the task hypothesis:** orthogonal moves from a 2-window stack
  are NOT no-ops; they re-orient the whole workspace.
- **B.8/B.9 "first or last child"**: the answer is "adjacent to the
  target container's *focused* child" — depends on which child of the
  target was last focused, not on the move direction alone.
- **Focus after close** is "previous sibling", which is the opposite of
  what i3 does (i3 focuses the next window); recorded empirically from
  sway's focus-inactive fallback.
- **1-child containers persist** (C.19, B.10, D.21) — nothing auto-
  flattens them; a Hyprland emulator must keep them too (or explicitly
  decide to flatten, which would diverge from sway).
- **Transient anomaly (not reproduced):** once (B.13 prep), two back-to-
  back `swaymsg focus right` commands behaved as if only one took effect;
  a dedicated probe (3× focus right cycling L→R→L→R) behaved exactly as
  the source predicts. Possibly an IPC/timing race with consecutive
  swaymsg calls; ignore.
- **Not testable here:** cross-output/cross-monitor hand-off on
  `move`/`focus` (single output); `focus_wrapping` other than the default;
  tabbed/stacked layouts (out of scope per CLAUDE.md); floating windows,
  fullscreen, scratchpad; multi-seat.
- **Quirk worth knowing (source):** `container_squash`'s squashability
  check is asymmetric — only a V-with-single-H-child pair is squashable
  (an H-with-single-V-child pair is not), and `resize` amounts default to
  **ppt**, not px (`resize shrink width 500` means 500 percentage points;
  use `... 500px`).
- Percent values above are the exact 4-decimal `get_tree` reports at the
  recorded workspace sizes (1883 or 2509 px wide, gaps inner 4); recompute
  from pixels if geometry differs.
