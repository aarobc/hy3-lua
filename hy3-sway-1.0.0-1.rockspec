rockspec_format = "3.0"
package = "hy3-sway"
version = "1.0.0-1"

source = {
   url = "git://github.com/aarobc/hy3-lua.git",
   -- tag = "v1.0.0",
}

description = {
   summary = "Custom Hyprland layout ('lua:sway') emulating sway window movement and persistent per-container splits",
   detailed = [[
      hy3-sway is a custom Hyprland layout registered via
      hl.layout.register that emulates sway/i3 behavior that Hyprland's
      built-in layouts (dwindle, bstack) do not provide:

      - Directional window movement (mod+shift+dir) that respects a real,
        persisted n-ary tree, matching sway's `move left/right/up/down`.
      - Persistent per-container split orientation (sway's `splith`/`splitv`):
        a container remembers its orientation and every window that lands in
        it (opened or moved in) inherits it until explicitly toggled.
      - Sway-correct focus traversal with wrapping, and cross-monitor
        hand-off for both `move` and `focus` past a workspace edge.

      Behavioral spec: notes/sway-spec.md (movement/insertion/closure) and
      notes/dual-monitor.md (cross-monitor), both verified against sway 1.12.

      The `hl` API is provided at runtime by Hyprland (>= 0.50, which
      introduced the custom layout API); this rock only installs the Lua
      module. Requiring the module registers the layout as 'lua:sway' and
      exposes a `_G.swaydbg` debug helper.
   ]],
   homepage = "https://github.com/aarobc/hy3-lua",
   license = "MIT",
   labels = { "hyprland", "layout", "sway", "wayland" },
}

dependencies = {
   "lua >= 5.1",
   -- `hl` (Hyprland's Lua API) is a runtime dependency provided by the host
   -- compositor, not a LuaRocks package.
}

build = {
   type = "builtin",
   modules = {
      -- Primary module: require("sway")
      sway = "src/sway.lua",
      -- Compat shim so `require("layout")` keeps working for old configs
      layout = "layout.lua",
   },
}
