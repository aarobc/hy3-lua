# hy3-lua test environment
#
# All interaction with the WMs is through their IPC (swaymsg / hyprctl) —
# no input devices, no keybinding emulation.
#
# Base is archlinux:latest: its `extra` repo has the full Hyprland
# ecosystem at current versions — `hyprland 0.56.2` (exact host version)
# plus every dependency (aquamarine 0.15.0, hyprutils, hyprlang,
# hyprgraphics, hyprcursor, hyprwire, hyprwayland-scanner) and sway 1.12
# (exact host version). Nothing desktop-related needs compiling.
#
# The ONE source build: aquamarine. Hyprland 0.56 mandates aquamarine's
# headless backend (AQ_BACKEND_HEADLESS, MANDATORY in Compositor.cpp), but
# the headless backend reports no DRM fd at all (CHeadlessBackend::drmFD()
# and ::drmRenderNodeFD() return -1). Two failures in any GPU-less
# container, even with /dev/dri/renderD128 passed through:
#   1. CBackend::create() -> start() builds its GBM allocator only from a
#      backend-reported fd -> "no allocator available" -> abort.
#   2. CHyprOpenGLImpl takes its DRM fd from the backend; with -1 it
#      falls to openRenderNode(-1) -> RASSERT at init.
# The patch in environment/patches/ fixes both (it also adds a 1280x720
# mode to headless outputs so the test environment can match its
# documented resolution): when no backend provides an fd, CBackend::start()
# scans /dev/dri/renderD* and builds the GBM allocator from the first
# render node that opens, and CHeadlessBackend::drmRenderNodeFD() reports
# the same node so the renderer's GBM/EGL path gets it. We rebuild the
# SAME version arch packages (v0.15.0, identical sha256 to the arch source
# tarball, no arch patches) and install over the packaged
# libaquamarine.so.14, so the packaged Hyprland binary runs the patched
# library.
#
# Cache layout (source pulls are separate steps from builds):
#   base      — arch + shared runtime bits (foot, seatd, fonts)
#   sway      — base + packaged sway 1.12
#   hyprland  — base + packaged hyprland 0.56.2
#               + [RUN] build tooling (base-devel, patch)
#               + [RUN] fetch aquamarine source (cached; a broken build
#                          never re-downloads the source)
#               + [COPY] the patch (changing it never re-fetches)
#               + [RUN] patch + cmake + install
#
# Build via compose (see compose.yml) or directly (context = repo root):
#   docker build -f environment/Dockerfile --target sway -t hy3-sway .
#   docker build -f environment/Dockerfile --target hyprland -t hy3-hyprland .

FROM archlinux:latest AS base
RUN sed -i 's|^http://|https://|g' /etc/pacman.d/mirrorlist \
    && pacman -Sy --noconfirm --needed \
        foot seatd ttf-dejavu fontconfig
COPY --chmod=755 environment/entrypoint.sh /entrypoint.sh

# --- sway (packaged; 1.12, same as the host)
FROM base AS sway
RUN pacman -Sy --noconfirm --needed sway python3 \
    # `swaymsg` without -s relies on `sway --get-socketpath`, which can miss
    # the socket in containers; wrap it to glob the IPC socket on the shared
    # runtime dir
    && printf '#!/bin/sh\nsock=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -1)\n[ -n "$sock" ] || { echo "swaymsg: no sway-ipc socket in $XDG_RUNTIME_DIR" >&2; exit 1; }\nexec /usr/bin/swaymsg -s "$sock" "$@"\n' > /usr/local/bin/swaymsg \
    && chmod 755 /usr/local/bin/swaymsg
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sway", "-c", "/config/sway-nested.config"]

# --- hyprland (packaged 0.56.2 + patched aquamarine)
FROM base AS hyprland
# 1) packages: Hyprland itself (pulls its whole dep chain, incl. the
#    aquamarine 0.15.0 we replace below) + tooling to rebuild aquamarine
RUN pacman -Sy --noconfirm --needed hyprland base-devel cmake patch
# 2) source pull — its own cached step (same tarball arch packages: the
#    PKGBUILD fetches exactly this tag; sha256 pinned from the PKGBUILD)
RUN mkdir -p /src \
    && curl -fsSL -o /src/aquamarine.tar.gz \
        https://github.com/hyprwm/aquamarine/archive/refs/tags/v0.15.0/aquamarine-0.15.0.tar.gz \
    && echo 'bb5323f58cd2f379cb11c39893336e49980fe2e9fb101745addd87cebde3d13d  /src/aquamarine.tar.gz' \
        | sha256sum -c - \
    && tar -C /src -xzf /src/aquamarine.tar.gz
# 3) the patch (COPY before the build step: editing it invalidates only
#    the build layer)
COPY environment/patches/0001-aquamarine-headless-render-node-fallback.patch /src/
# 4) patch + build + install over the packaged library
RUN cd /src/aquamarine-0.15.0 \
    && patch -p1 < /src/0001-aquamarine-headless-render-node-fallback.patch \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -S . \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build \
    && ldconfig \
    && rm -rf /src
# convenience wrapper: 0.56.2's hyprctl needs the instance signature
# (it lives in the per-instance dir under $XDG_RUNTIME_DIR/hypr/); the
# newest one is the live instance in this single-instance environment
RUN printf '#!/bin/sh\nsig=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/1000}"/hypr/ 2>/dev/null | head -1)\n[ -n "$sig" ] || { echo "hyprctl: no hyprland instance dir in ${XDG_RUNTIME_DIR:-/run/user/1000}/hypr" >&2; exit 1; }\nexec /usr/bin/hyprctl -i "$sig" "$@"\n' > /usr/local/bin/hyprctl \
    && chmod 755 /usr/local/bin/hyprctl
ENTRYPOINT ["/entrypoint.sh"]
CMD ["Hyprland", "-c", "/config/hypr-nested.lua"]
