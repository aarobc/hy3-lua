#!/bin/bash
# Cross-monitor battery for hy3-lua (cases from notes/dual-monitor.md).
# Needs a running nested Hyprland with TWO monitors (see notes/dual-monitor.md 1c):
#   SIG in /tmp/nested-sig, nested wl socket in /tmp/nested-wl (default wayland-2).
set -u
SIG=$(cat /tmp/nested-sig)
WL=${NESTED_WL:-wayland-2}
H() { hyprctl -i "$SIG" "$@"; }

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
kill_title() { # $1 = title  (host-side kill of the nested test client)
  local pid
  pid=$(H -j clients | jq -r --arg t "$1" '.[] | select(.title==$t) | .pid')
  for p in $pid; do
    if tr '\0' ' ' < /proc/$p/environ 2>/dev/null | grep -q "WAYLAND_DISPLAY=$WL"; then
      kill "$p"
    fi
  done
  sleep 0.6
}
dump() { # $1 = label
  echo "=== $1"
  echo "active: $(active)"
  H repl 'return swaydbg.dump()'
  H -j clients | jq -c '.[] | {t:.title, m:.monitor, ws:.workspace.id, at:.at}'
}

D() { H dispatch "hl.dsp.layout(\"$1\")" >/dev/null; sleep 0.6; }

# ----------------------------------------------------------------- setup
dump "0 setup (empty)"
spawn A; spawn B                       # ws1: [A B]
H dispatch 'hl.dsp.focus({workspace="2"})' >/dev/null; sleep 0.7
spawn C                                # ws2: [C]
dump "1 seeded: ws1=[A,B] ws2=[C]"

# M.2: screen edge -> no-op
focus_title A; D "move left"
dump "2 M.2 A move left @ screen edge (expect A unchanged, active A)"

# M.1: rightmost edge, move right -> entry edge (index 0) of target ws
focus_title B; D "move right"
dump "3 M.1 B crossed (expect ws1=[A], ws2=[B,C], active B)"

# M.1b: entry edge even when target focus is elsewhere
focus_title C; spawn D                 # ws2 = [B,C,D]
focus_title A; D "move right"
dump "4 M.1b A crossed into [B,C,D] (expect ws2=[A,B,C,D], ws1 empty)"

# X.1: leftward cross appends at the END of target root
H dispatch 'hl.dsp.focus({workspace="1"})' >/dev/null; sleep 0.7
spawn E                                # ws1 = [E]
focus_title A; D "move left"
dump "5 X.1 A crossed left (expect ws1=[E,A] end-append, ws2=[B,C,D])"

# M.3/M.4: cross into EMPTY active workspace on the target monitor.
# Source must be on the OTHER monitor, or focusing it would steal the
# target monitor's active workspace.
focus_title B                          # mon2 focused
H dispatch 'hl.dsp.focus({workspace="3"})' >/dev/null; sleep 0.7   # ws3 on mon2, empty+active
focus_title A; D "move right"          # A = rightmost of ws1=[E,A]; target = active ws of mon2 = ws3
dump "6 M.3/M.4 A into empty active ws3 (expect ws3=[A], ws1=[E], ws2=[B,C,D])"

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
