#!/bin/bash
# hy3-lua: promotion / re-orientation / collapse battery.
SIG=$(cat /tmp/nested-sig)

dump() { hyprctl -i "$SIG" repl 'return swaydbg.dump()'; }
act()  { hyprctl -i "$SIG" repl 'local w=hl.get_active_window(); return w and w.stable_id or "none"'; }
cmd()  { hyprctl -i "$SIG" dispatch "hl.dsp.layout(\"$1\")" >/dev/null 2>&1; sleep 0.4; }
openw(){ hyprctl -i "$SIG" dispatch 'hl.dsp.exec_cmd("foot")' >/dev/null 2>&1; sleep 1.2; }
closew(){ hyprctl -i "$SIG" dispatch 'hl.dsp.window.close()' >/dev/null 2>&1; sleep 1.0; }
# close ALL current windows (by address list), for a clean start
reset(){
  local ids
  ids=$(hyprctl -i "$SIG" -j clients | python3 -c "
import json,sys
print(' '.join(c['stableId'] for c in json.load(sys.stdin)))")
  for id in $ids; do
    hyprctl -i "$SIG" dispatch "hl.dsp.window.close()" >/dev/null 2>&1
  done
  sleep 1.2
  dump
}

echo "############ PART 1: B.10-style PROMOTION"
echo "== reset to clean"
reset
echo "== open P0, P1 flat; focus left (P0); splitv on P0; open P2 (joins con) -> [con v [P0][P2]] [P1]"
openw; openw
cmd "focus left"
echo "active: $(act)"
cmd splitv
openw
dump
echo "== focus up (P0, top of pair); move left -> NO sibling left of con v -> P0 PROMOTED: [P0] [con v [P2]] [P1]"
cmd "focus up"
echo "active: $(act)"
cmd "move left"
dump
echo

echo "############ PART 2: B.14 WORKSPACE RE-ORIENTATION"
echo "== reset to clean"
reset
echo "== open A; splitv (singleton: ws flips to v); open B -> ws v [A][B]"
openw
cmd splitv
openw
dump
echo "== focus A (up), move left -> no parallel ancestor -> wrap all in con v, ws->h, A promoted left: ws h [A] [con v [B]]"
cmd "focus up"
echo "active: $(act)"
cmd "move left"
dump
echo "== now move A right again -> re-enters con v at focused child (B) index: [con v [A][B]]"
cmd "move right"
dump
echo

echo "############ PART 3: C.19 CONTAINER COLLAPSE"
echo "== reset to clean"
reset
echo "== build [W0 h [A1][A2]] [W1 h [B1][B2]]:"
openw            # A1
cmd splith       # singleton: ws->h (already h, no-op)
openw            # A2 -> [A1][A2]
cmd "focus right" # A2? no: A1 focused? build differently below
dump
echo "(skip complex build; direct test: close middle-of-3 then last-of-container)"
echo "== close-focused until 1 window remains, watching 1-child containers persist and empty ones vanish"
dump
closew
dump
closew
dump
closew
dump
echo
