#!/usr/bin/env python3
"""Insertion-rule battery (part 2) — where does a cross-monitor move land?

Requires the same fresh dual-output environment (run-dual-sway.sh first):
  X11-1 (left): ws "1" empty; X11-2 (right): ws "2" empty.

Tests:
  X.1  leftward cross: T1 (leftmost of ws2) moves left into ws1=[L]
       -> append (end) or prepend (index 0)?
  X.2  rightward cross with target focused child at idx 2 of 3
       -> index 0 anyway?
  X.3  rightward cross, target focus on an INNER window -> index 0?
  X.4  rightward cross into ws whose root is VERTICAL (splitv)
       -> still index 0? (orientation of target root)
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
            f = " [F]" if n.get("focused") else ""
            lines.append("  " * depth + f"win {n['name']!r}{p}{f}")
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
        cmd("kill")
        time.sleep(0.3)

# ---------- X.1: leftward cross ----------
# ws1 = [L]; ws2 = [T1, T2]. Focus T1 (leftmost of ws2), move left.
focus_ws(1)
seed("L")
focus_ws(2)
seed("T1"); seed("T2")
focus("left")                   # -> T1 (leftmost of ws2)
dump("x1-setup")
cmd("move", "left")             # T1 crosses LEFT into ws1
time.sleep(0.5)
dump("x1-after")                # ws1 = [L, T1]? or [T1, L]?

# ---------- X.2: rightward cross, target focus idx 2 of 3 ----------
# ws2 now = [T2]; add T3a, T3b; focus T3b (idx 2); cross M2 from ws1.
seed("T3a"); seed("T3b")        # ws2 = [T2, T3a, T3b], focus T3b (idx 2)
dump("x2-setup")
focus_ws(1)                     # focus -> L (remembered; T1 left ws1)
focus("right")                  # -> T1 (rightmost of ws1) so this is a cross
cmd("move", "right")            # T1 crosses right into ws2
time.sleep(0.5)
dump("x2-after")                # L at idx 0 or idx 2?

# ---------- X.3: rightward cross, target focus inside inner container ----------
# ws1 = [] (L crossed). ws2 = [L, T2, T3a, T3b].
focus_ws(2)                     # focus -> L (last crossed)
seed("W")                       # appended rightmost: [L, T2, T3a, T3b, W]
cmd("splitv")
seed("X")                       # Wx = (W / X) at idx 4; focus X
focus_ws(1)
seed("M3")
cmd("move", "right")            # M3 crosses; target focus = X (inner)
time.sleep(0.5)
dump("x3-after")                # M3 at idx 0 of root?

# ---------- X.4: rightward cross into VERTICAL-root ws ----------
kill_workspace("2")
focus_ws(2)
seed("V1")
cmd("splitv")                   # W = (V1), focus V1 inside W
seed("V2")                       # W = (V1 / V2) — the ws ROOT is now splitv
dump("x4-setup")
focus_ws(1)
# ws1 empty (T1, L crossed away) -> seed
seed("M4")
cmd("move", "right")
time.sleep(0.5)
dump("x4-after")                # where does M4 land relative to [V1, W(...)]?

print("\nbattery done ->", OUT)
