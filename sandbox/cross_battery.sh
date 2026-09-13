#!/bin/bash
# Cross-monitor battery for hy3-lua (cases from notes/dual-monitor.md).
#
# Runs INSIDE the hyprland docker service, which it also sets up: a second
# headless output (HEADLESS-2) to the right of HEADLESS-1, both 1280x720.
# `hyprctl` in the image is the wrapper that resolves the instance
# signature; the sandbox (this script) is mounted at /root/code/hy3-lua.
# Launch from environment/:
#
#   docker compose exec -T hyprland bash /root/code/hy3-lua/sandbox/cross_battery.sh
#
# Run against a FRESH container (`docker compose up -d --force-recreate
# hyprland` first): the cross target is the adjacent monitor's ACTIVE
# workspace, and a workspace's remembered orientation survives between
# runs — a leftover vertical root would send M.1b/X.1 through the
# documented perpendicular-root path instead of the clean edge cross.
#
# Clients are spawned via the instance's OWN exec dispatch (they can never
# land on the host) and killed by cmdline pattern — in this single-purpose
# container the titles are unique and pkill -f cannot self-match (the
# pattern only exists in this script file, not in any process cmdline).
set -u
H() { hyprctl "$@"; }

focus_title() { # $1 = title
  H repl "local function f() for _,w in ipairs(hl.get_windows()) do if w.title=='$1' then hl.dispatch(hl.dsp.focus({window=w})) return 'focused' end end return 'not found' end return f()" >/dev/null
  sleep 0.7
}
active() {
  H repl "local function f() for _,w in ipairs(hl.get_windows()) do if w.active then return w.title..' ws'..w.workspace.id..' mon'..w.monitor.name end end return 'none' end return f()"
}
spawn() { # $1 = title
  H dispatch "hl.dsp.exec_cmd('foot -T $1 -- sleep 3600')" >/dev/null; sleep 0.6
}
kill_title() { # $1 = title
  pkill -f "foot -T $1 --" 2>/dev/null
  sleep 0.6
}
dump() { # $1 = label
  echo "=== $1"
  echo "active: $(active)"
  H repl 'return hy3dbg.dump()'
  H -j clients 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    print(f\"  {c.get('title')} mon={c['monitor']} ws={c['workspace']['id']} at={c['at']}\")"
}

D() { H dispatch "hl.dsp.layout(\"$1\")" >/dev/null; sleep 0.6; }

# ----------------------------------------------------------------- setup
# close ALL existing windows (leftovers from other batteries would sit
# past the right edge and break the "at the screen edge" preconditions),
# then shape the 2nd output
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  c=$(H repl 'return #hl.get_windows()')
  [ "$c" = "0" ] && break
  H dispatch 'hl.dsp.window.close()' >/dev/null 2>&1
  sleep 0.8
done
for t in A B C D E F G; do kill_title "$t"; done
n=$(H repl 'return #hl.get_monitors()')
if [ "$n" = "1" ]; then
  H output create headless HEADLESS-2 >/dev/null 2>&1
  sleep 1
fi
H repl 'hl.monitor({output = "HEADLESS-1", mode = "1280x720", position = "0x0"})
hl.monitor({output = "HEADLESS-2", mode = "1280x720", position = "1280x0"})
return 1' >/dev/null
sleep 1
# workspace ids drift across reruns in the same container. The target for
# rightward crosses is the ADJACENT monitor's active ws, so focus mon2
# first and let C seed it (its id becomes $W2)

dump "0 setup (2 monitors)"
spawn A; spawn B                       # ws1/mon1: [A B]
H dispatch 'hl.dsp.focus({monitor="HEADLESS-2"})' >/dev/null; sleep 0.7
spawn C                                # C -> active ws of mon2
W2=$(H repl 'local function f() for _,w in ipairs(hl.get_windows()) do if w.title=="C" then return w.workspace.id end end return nil end return f()')
W3=$((W2 + 1))

dump "1 seeded: ws1=[A,B] ws$W2=[C]@mon2"

# M.2: screen edge -> no-op
focus_title A; D "move left"
dump "2 M.2 A move left @ screen edge (expect A unchanged, active A)"

# M.1: rightmost edge, move right -> entry edge (index 0) of target ws
focus_title B; D "move right"
dump "3 M.1 B crossed (expect ws1=[A], ws$W2=[B,C], active B)"

# M.1b: entry edge even when target focus is elsewhere
focus_title C; spawn D                 # ws$W2 = [B,C,D]
focus_title A; D "move right"
dump "4 M.1b A crossed into [B,C,D] (expect ws$W2=[A,B,C,D], ws1 empty)"

# X.1: leftward cross appends at the END of target root
H dispatch 'hl.dsp.focus({workspace="1"})' >/dev/null; sleep 0.7
spawn E                                # ws1 = [E]
focus_title A; D "move left"
dump "5 X.1 A crossed left (expect ws1=[E,A] end-append, ws2=[B,C,D])"

# M.3/M.4: cross into EMPTY active workspace on the target monitor.
# Source must be on the OTHER monitor, or focusing it would steal the
# target monitor's active workspace.
focus_title B                          # mon2 focused
H dispatch "hl.dsp.focus({workspace=\"$W3\"})" >/dev/null; sleep 0.7   # ws$W3 on mon2, empty+active
focus_title A; D "move right"          # A = rightmost of ws1=[E,A]; target = active ws of mon2 = ws$W3
dump "6 M.3/M.4 A into empty active ws$W3 (expect ws$W3=[A], ws1=[E], ws$W2=[B,C,D])"

# X.4: perpendicular target root -> focused child's index
focus_title A; D "togglesplit"         # ws3 root -> vertical (singleton rule)
spawn F                                # ws3 = [A,F] vertical, F focused
focus_title E; D "move right"          # E = sole/rightmost of ws1
dump "7 X.4 E into vertical root [A,F] with F focused (expect ws3=[A,E,F], ws1 empty)"

# F.1: focus cross -> nearest window on adjacent monitor's active ws
H dispatch 'hl.dsp.focus({workspace="1"})' >/dev/null; sleep 0.7
spawn G                                # ws1 = [G]
focus_title G
H dispatch "hl.dsp.layout(\"focus right\")" >/dev/null; sleep 0.7
dump "8 F.1 focus right from ws1 (expect active E ws3, vertical middle nearest)"

# F.3: focus at screen edge -> no-op
focus_title G
H dispatch "hl.dsp.layout(\"focus left\")" >/dev/null; sleep 0.7
dump "9 F.3 focus left @ screen edge (expect active G ws1)"

echo "battery done"
