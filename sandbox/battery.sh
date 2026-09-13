#!/bin/bash
# hy3-lua behavioral battery (notes/sway-spec.md A/B/C cases) against the
# DOCKER hyprland service (lua:hy3 layout).
#
# Runs INSIDE the hyprland service: `hyprctl` there is the image wrapper
# that resolves the instance signature, and the sandbox (this script) is
# mounted at /root/code/hy3-lua/sandbox. Launch from environment/:
#
#   docker compose exec -T hyprland bash /root/code/hy3-lua/sandbox/battery.sh
#
# Clients are spawned via the instance's OWN exec dispatch so they can
# never land on the host.

dump() { hyprctl repl 'return hy3dbg.dump()'; }
act()  { hyprctl repl 'local w=hl.get_active_window(); return w and w.stable_id or "none"'; }
cmd()  { hyprctl dispatch "hl.dsp.layout(\"$1\")" >/dev/null 2>&1; sleep 0.4; }
openw(){ hyprctl dispatch 'hl.dsp.exec_cmd("foot")' >/dev/null 2>&1; sleep 1.2; }
closew(){ hyprctl dispatch 'hl.dsp.window.close()' >/dev/null 2>&1; sleep 1.0; }
# close ALL current windows until the tree is actually empty (poll the
# count: closes can take a beat to settle, so a fixed round-count would
# dump a stale state)
reset(){
  local n i=0
  while [ "$i" -lt 30 ]; do
    n=$(hyprctl repl 'return #hl.get_windows()')
    [ "$n" = "0" ] && break
    [ -z "$n" ] && break
    hyprctl dispatch 'hl.dsp.window.close()' >/dev/null 2>&1
    i=$((i+1)); sleep 1.0
  done
  sleep 1.0
  dump
}

echo "== reset to clean"
reset

echo "== build: A, B1 flat; splitv on B1; open B2  ->  [A] [con v [B1][B2]] (B2 focused)"
openw; openw
cmd splitv
openw
dump
echo
echo "== B.8: focus left (A), move right  (B2 is focused child) -> expect [con v 1.0: [B1][A][B2]], A focused"
cmd "focus left"
echo "active: $(act)"
cmd "move right"
dump
echo
echo "== B.10: focus A (top child now), move left -> no parallel sibling left -> A promoted before con v: [A][con v[B1][B2]]"
cmd "move left"
dump
echo
echo "== B.11: open C (joins top level after focused A? A focused top-level -> C after A). Then focus C, move left -> parallel container con v? no, target A is window: cousin? C's parent is root(par), A window, direct level: SWAP. expect [A][C][con v]"
openw
dump
cmd "focus right"
echo "active: $(act)"
cmd "move left"
dump
echo
echo "== B.13: focus leftmost (A), move left -> no-op"
cmd "focus left"; cmd "focus left"
echo "active: $(act)"
cmd "move left"
dump
echo
echo "== C.17/C.18: close the MIDDLE of three top-level -> survivors renormalize proportionally"
# focus middle: focus right from A
cmd "focus right"
echo "active: $(act)"
closew
dump
echo
echo "== focus wrap: with 2 flat windows, focus left at leftmost wraps to rightmost"
cmd "focus left"
echo "active: $(act)"
cmd "focus left"
echo "active: $(act)  (should be the OTHER window)"
echo
