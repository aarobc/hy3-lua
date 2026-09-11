#!/usr/bin/env python3
"""Cross-monitor move battery for sway (Xvnc X11-backend, dual output) — v4.

Usage: dualmove_battery.py <ipc-sock> <output-dir>

Requires a FRESH nested sway on Xvnc with two 1280x720 outputs:
  X11-1 (left):  workspace "1" (empty)
  X11-2 (right): workspace "2" (empty)
(use sandbox/run-dual-sway.sh to start this environment).

sway 1.12 facts this script relies on (all verified on this build):
  * `focus [title=...]` does NOT exist — only directional focus.
  * `kill [title=...]` IGNORES the criteria — plain `kill` closes the
    focused window only.
  * `workspace N` when N does not exist CREATES it on the current output;
    empty workspaces are destroyed when focus leaves them.
  * `workspace N` does NOT move a workspace between outputs.
  * `focus <dir>` crosses workspace edges onto the adjacent monitor:
    nearest window of that monitor's active workspace, or the workspace
    node itself if it is empty.
  * `workspace N` focuses the workspace's last-remembered window (or its
    node if empty).
  * get_tree window-level focused flags are reliable; workspace/output
    level flags are not (report False even when a window is focused).

Case flow (windows are named per case; ws1 = left monitor, ws2 = right):
  M.1   ws1=[A,B] ws2=[C]; B moves right -> crosses, inserts at C's idx
  M.2   A (leftmost, leftmost monitor) moves left -> no-op
  M.1b  ws2=[B,C] focus C; A moves right -> inserts at C's idx [B,A,C]
  M.3   seed D on ws1; empty ws2; D moves right -> alone in ws2, p=1
  M.4   seed E4; create ws3 (empty) on right monitor, make it active;
        E4 moves right -> lands on empty ws3
  M.5a  ws2=[E, W1(F,G)] focus G; H moves right -> W1=[F,H,G]
  M.5b  ws2=[E, W1(F,G)] focus F; H2 moves right -> W1=[H2,F,G]
  M.6   ws2=[E, W1(F,G)] focus F; F moves left -> promotion behaviour
  F.1   focus right from empty ws1 -> nearest window on right monitor
  F.2   focus right from empty ws1 into EMPTY ws2 -> ws node focused
  F.3   focus left from leftmost monitor -> no-op
"""
import json, os, subprocess, sys, time

SOCK = sys.argv[1]
OUT = sys.argv[2]
os.makedirs(OUT, exist_ok=True)

def cmd(*args):
    r = subprocess.run(["swaymsg", "-s", SOCK, *args], capture_output=True, text=True)
    if r.stdout.strip().startswith("[") and '"success": false' in r.stdout:
        print(f"  !! cmd failed: {args}: {r.stdout.strip()}")
    return r

def tree():
    return json.loads(cmd("-t", "get_tree").stdout)

def dump(tag):
    t = tree()
    lines = []
    def walk(n, depth):
        if n["type"] == "con" and n.get("layout") == "none":
            p = f" p={n['percent']:.3f}" if "percent" in n else ""
            r = n.get("rect") or {}
            rect = f" rect={r.get('x')},{r.get('y')} {r.get('width')}x{r.get('height')}" if r else ""
            f = " [F]" if n.get("focused") else ""
            lines.append("  " * depth + f"win {n['name']!r}{p}{rect}{f}")
            return
        if n["type"] == "con":
            p = f" p={n['percent']:.3f}" if "percent" in n else ""
            f = " [F]" if n.get("focused") else ""
            lines.append("  " * depth + f"con({n.get('layout')}){p}{f}")
            for c in n.get("nodes", []):
                walk(c, depth + 1)
    for out in t["nodes"]:
        if out["type"] != "output" or out["name"] == "__i3":
            continue
        r = out["rect"]
        lines.append(f"== {out['name']} {r['width']}x{r['height']}+{r['x']},{r['y']}")
        for ws in out["nodes"]:
            if ws["type"] != "workspace":
                continue
            wins = []
            def count(n):
                if n["type"] == "con" and n.get("layout") == "none":
                    wins.append(n["name"])
                for c in n.get("nodes", []):
                    count(c)
            for c in ws.get("nodes", []):
                count(c)
            lines.append(f"  ws {ws['name']} windows={len(wins)} {wins}")
            for c in ws.get("nodes", []):
                walk(c, 2)
    text = "\n".join(lines)
    with open(f"{OUT}/{tag}.txt", "w") as f:
        f.write(text + "\n")
    print(f"\n##### {tag}\n{text}")

def seed(title):
    cmd("exec", f"foot -T {title} -- sleep 3600")
    time.sleep(1)

def focus_ws(name):
    cmd(f"workspace {name}")
    time.sleep(0.4)

def focus(*dirs):
    for d in dirs:
        cmd("focus", d)
        time.sleep(0.15)
    time.sleep(0.25)

def kill_workspace(wsname):
    focus_ws(wsname)
    for _ in range(30):
        t = tree()
        found = False
        def has(n):
            nonlocal found
            if n["type"] == "con" and n.get("layout") == "none":
                found = True
            for c in n.get("nodes", []):
                has(c)
        for o in t["nodes"]:
            if o["type"] == "output" and o["name"] != "__i3":
                for w in o.get("nodes", []):
                    if w["type"] == "workspace" and w["name"] == wsname:
                        for c in w.get("nodes", []):
                            has(c)
        if not found:
            return
        cmd("kill")  # closes the focused window
        time.sleep(0.3)

# sanity: fresh layout
t = tree()
ok = False
for o in t["nodes"]:
    if o["type"] == "output" and o["name"] == "X11-1":
        for w in o["nodes"]:
            if w["type"] == "workspace" and w["name"] == "1" and not w.get("nodes"):
                ok = True
if not ok:
    print("FATAL: X11-1 workspace 1 not empty — start a FRESH instance (run-dual-sway.sh)")
    sys.exit(1)

# ---------- M.1: basic rightward cross, flat target ----------
focus_ws(1)
seed("A"); seed("B")            # ws1 = [A, B], focus B (rightmost)
focus_ws(2)
seed("C")                       # ws2 = [C], focus C
dump("m1-setup")
focus_ws(1)                     # focus -> B (ws1 remembered)
cmd("move", "right")            # B is rightmost of ws1 -> crosses
time.sleep(0.5)
dump("m1-after")                # expect ws2 = [B, C] (insert at C's idx 0), B [F]

# ---------- M.2: left edge, no adjacent monitor ----------
focus_ws(1)                     # focus -> A
cmd("move", "left")             # A is leftmost, no monitor left
time.sleep(0.5)
dump("m2-after")                # expect no-op, A [F]

# ---------- M.1b: insertion index = target's focused child index ----------
focus_ws(2)                     # focus -> B (remembered)
focus("right")                  # -> C (idx 1)
dump("m1b-pre")
focus_ws(1)                     # focus -> A
cmd("move", "right")            # A crosses; C is focused child (idx 1)
time.sleep(0.5)
dump("m1b-after")               # expect ws2 = [B, A, C], A [F]

# ---------- M.3: cross into EMPTY target ws ----------
seed_check_ws1 = False
focus_ws(1)                     # ws1 empty (A,B crossed away) -> ws node
seed("D")                       # D alone on ws1, focused
kill_workspace("2")             # empty ws2
dump("m3-setup")
focus_ws(1)                     # refocus D (kill_workspace left focus on ws2)
cmd("move", "right")            # D crosses into empty ws2
time.sleep(0.5)
dump("m3-after")                # expect ws2 = [D] p=1.0, D [F]

# ---------- M.4: target monitor's active-but-EMPTY ws ----------
focus_ws(1)
seed("E4")                      # ws1 = [E4]
cmd("workspace", "3")           # creates ws3 on current output
time.sleep(0.4)
t = tree()
ws3_out = None
for o in t["nodes"]:
    if o["type"] == "output":
        for w in o.get("nodes", []):
            if w["type"] == "workspace" and w["name"] == "3":
                ws3_out = o["name"]
print(f"  ws3 created on {ws3_out}")
if ws3_out != "X11-2":
    # ws3 was created on X11-1 (if focus was there); move it right
    cmd("move", "workspace", "to", "output", "X11-2")
    time.sleep(0.4)
focus_ws(1)                     # focus -> E4; X11-2 active ws = empty ws3
cmd("move", "right")            # E4 crosses
time.sleep(0.5)
dump("m4-after")                # expect E4 alone in ws3

# ---------- M.5a: cross into target's focused INNER container (child idx 1) ----------
focus_ws(2)                     # ws2 = [D]
kill_workspace("2")             # empty it
focus_ws(2)                     # focus = ws2 node
seed("E"); seed("F")            # ws2 = [E, F]
cmd("splitv")
seed("G")                       # W1 = [F, G], focus G (idx 1)
dump("m5a-setup")
focus_ws(1)                     # ws1 empty -> node
seed("H")
cmd("move", "right")            # H crosses; W1 focused, focused child G
time.sleep(0.5)
dump("m5a-after")               # expect W1 = [F, H, G], H [F]

# ---------- M.5b: same, focused child idx 0 ----------
kill_workspace("2")
focus_ws(2)
seed("E"); seed("F")
cmd("splitv")
seed("G")                       # focus G; remembered child of W1 = G
focus("up")                     # -> F (idx 0)
dump("m5b-pre")
focus_ws(1)
seed("H2")
cmd("move", "right")
time.sleep(0.5)
dump("m5b-after")               # expect W1 = [H2, F, G], H2 [F]

# ---------- M.6: promotion from nested container at ws edge ----------
kill_workspace("2")
focus_ws(2)
seed("E"); seed("F")
cmd("splitv")
seed("G")
focus("up")                     # focus F (top of W1)
dump("m6-pre")
cmd("move", "left")             # F has no left sibling in W1; W1's left = E
time.sleep(0.5)
dump("m6-after")                # observe: leaf F promoted? W1 moved? nested?

# ---------- F.1: focus crosses to nearest window on adjacent monitor ----------
focus_ws(1)                     # ws1 empty (E4 crossed) -> ws node
cmd("focus", "right")           # cross into X11-2 active ws (ws2, M.6 result)
time.sleep(0.4)
dump("f1-after")                # expect focus on leftmost window of ws2

# ---------- F.2: focus into EMPTY adjacent ws ----------
kill_workspace("2")
focus_ws(1)
cmd("focus", "right")           # ws2 now empty
time.sleep(0.4)
dump("f2-after")                # expect no focused window (ws node)

# ---------- F.3: focus at screen edge, no adjacent monitor ----------
cmd("focus", "left")            # X11-1 is leftmost monitor
time.sleep(0.4)
dump("f3-after")                # expect no-op

print("\nbattery done ->", OUT)
