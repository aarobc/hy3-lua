#!/bin/sh
# Start a fresh dual-output sway (X11 backend on Xvnc :99) and run the
# cross-monitor battery. Kills any previous instance first.
set -e
: > /tmp/sh-empty.conf
XVNC_PID=$(cat /tmp/xvnc.pid 2>/dev/null || true)
[ -n "$XVNC_PID" ] || { echo "no Xvnc pid at /tmp/xvnc.pid" >&2; exit 1; }
kill $(cat /tmp/xsw.pid 2>/dev/null) 2>/dev/null || true
sleep 1.5

cd "$(dirname "$0")/.."
DISPLAY=:99 WLR_BACKENDS=x11 sway -c /tmp/sh-empty.conf >/tmp/xsw.log 2>&1 &
echo $! > /tmp/xsw.pid
sleep 2.5
SOCK=$(ls -t /run/user/1001/sway-ipc.* | head -1)
echo "$SOCK" > /tmp/xsw.sock
swaymsg -s "$SOCK" create_output >/dev/null
sleep 1
swaymsg -s "$SOCK" 'output X11-1 mode 1280x720 position 0 0' >/dev/null
swaymsg -s "$SOCK" 'output X11-2 mode 1280x720 position 1280 0' >/dev/null

mkdir -p notes/dualmove-dumps
python3 sandbox/dualmove_battery.py "$SOCK" notes/dualmove-dumps
echo
echo "sway left running: sock=$SOCK pid=$(cat /tmp/xsw.pid)"
