#!/bin/sh
# entrypoint for the hy3-lua test containers.
#
# - XDG_RUNTIME_DIR is a shared volume (see compose.yml): the wayland + IPC
#   sockets live there, so `docker compose exec`/`run --rm` containers can
#   reach the running compositor's sockets from another container.
# - WLR_BACKENDS=headless: both WMs run their wlroots headless backend.
# - seatd: libseat backend required by wlroots; started only for the
#   long-running compositor (one-shot exec/run containers just need
#   XDG_RUNTIME_DIR to point at the shared volume).

export XDG_RUNTIME_DIR=/run/user/1000
export WLR_BACKENDS=headless
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

case "$1" in
    sway|Hyprland)
        seatd &
        sleep 0.3
        ;;
esac

exec "$@"
