#!/usr/bin/env python3
"""Compact sway tree dump for spec work.

Usage: tree_dump.py <ipc-sock> [-v]

Default prints, per output: name, rect, per workspace: name, focused mark,
window count, and the chain of focused containers (with percents).
With -v prints the full container tree with layout/percent/rect per node.
"""
import json, subprocess, sys

def tree(sock):
    out = subprocess.run(["swaymsg", "-s", sock, "-t", "get_tree"],
                         capture_output=True, text=True).stdout
    return json.loads(out)

def fmt_con(c):
    name = c.get("name")
    if c["type"] == "con":
        if name is None:
            return f"con(<anon>)"
        return f"con({name!r})"
    return c["type"]

def walk(n, depth, verbose, lines):
    if n["type"] == "con":
        if n.get("layout") == "none":
            p = f" p={n['percent']:.3f}" if "percent" in n else ""
            r = f" rect={n['rect']['x']},{n['rect']['y']} {n['rect']['width']}x{n['rect']['height']}" if verbose else ""
            focus = " [F]" if n.get("focused") else ""
            lines.append("  " * depth + f"win {n['name']!r}{p}{r}{focus}")
            return
        p = f" p={n['percent']:.3f}" if "percent" in n else ""
        focus = " [F]" if n.get("focused") else ""
        lines.append("  " * depth + f"con({n.get('layout')}){p}{focus}")
        for c in n.get("nodes", []):
            walk(c, depth + 1, verbose, lines)

def main():
    sock = sys.argv[1]
    verbose = "-v" in sys.argv
    t = tree(sock)
    for out in t["nodes"]:
        if out["type"] != "output" or out["name"] == "__i3":
            continue
        r = out["rect"]
        print(f"== {out['name']} {r['width']}x{r['height']}+{r['x']},{r['y']}")
        for ws in out["nodes"]:
            if ws["type"] != "workspace":
                continue
            marks = []
            if ws.get("focused"):
                marks.append("FOCUSED")
            wins = []
            def count(n):
                if n["type"] == "con" and n.get("layout") == "none":
                    wins.append(n["name"])
                for c in n.get("nodes", []):
                    count(c)
            for c in ws.get("nodes", []):
                count(c)
            print(f"  ws {ws['name']} [{', '.join(marks)}] windows={len(wins)} {wins}")
            lines = []
            for c in ws.get("nodes", []):
                walk(c, 1, verbose, lines)
            for l in lines:
                print("    " + l)

if __name__ == "__main__":
    main()
