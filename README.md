# hy3-lua

`hy3` (HYprland + i3) is a custom [Hyprland](https://github.com/hyprwm/Hyprland)
layout (registered via `hl.layout.register`) that emulates the
i3/sway window-management behaviors Hyprland's built-in layouts (dwindle,
bstack) don't provide:

- **Directional window movement** (`move left/right/up/down`) that
  respects a real, persisted n-ary tree — matching sway's
  `move left/right/up/down`, including adjacent swaps, cousin
  insertion, promotion, and workspace re-orientation.
- **Persistent per-container split orientation** — sway's
  `splith`/`splitv` model: a container remembers its orientation and
  every window that lands in it (opened or moved in) inherits it until
  explicitly toggled.
- **Sway-correct focus traversal** with wrapping, plus **cross-monitor
  hand-off** for both `move` and `focus` past a workspace edge.

The behavior is specified empirically against sway 1.12 in
[notes/sway-spec.md](notes/sway-spec.md) (movement/insertion/closure)
and [notes/dual-monitor.md](notes/dual-monitor.md) (cross-monitor).
Tabbed and stacked layouts are deliberately out of scope.

## Requirements

- Hyprland with the custom layout API (`hl.layout.register`,
  Hyprland 0.50+). The `hl` API is provided by the compositor at
  runtime; this rock installs only the Lua module.
- Lua 5.4 (Hyprland's embedded interpreter).

## Installation

Install into your **local** tree (no sudo needed):

```sh
luarocks --local --lua-version 5.4 install hy3
# module lands in ~/.luarocks/share/lua/5.4/
```

A plain `luarocks install hy3` targets the system tree and fails without
root on most distros (e.g. Arch); use `--local`, or `sudo luarocks
install hy3` if you'd rather keep it system-wide (then add whichever
tree your interpreter searches — see the note below).

> **Important — Hyprland does not search LuaRocks trees.** The embedded
> Lua interpreter starts with its default `package.path` only; rocks in
> `~/.luarocks` are invisible to it. You must extend `package.path` from
> your config, as shown in [Usage](#usage). This is the one step that is
> easy to miss.

Or skip installing entirely (e.g. to track `master` of this repo):

```lua
package.path = package.path .. ';/path/to/hy3-lua/src/?.lua'
require("hy3")
```

You can also install straight from git, no server round-trip:
`luarocks --local install aarobc/hy3-lua`.

### Releasing to LuaRocks.org

One-time: create an account at https://luarocks.org and grab your API
key from your profile page (stored locally after first use).

1. Bump `version` in the rockspec **and** rename the rockspec file
   (`hy3-<version>-<serial>.rockspec` — the filename must match the
   contents).
2. Uncomment the `tag = "v<version>"` line in the rockspec, commit,
   then `git tag v<version>` and push both (order matters: the tag
   must point at the commit containing the uncommented rockspec).
3. Upload (this fetches and builds from the pushed tag, exactly like
   a user's install):

   ```sh
   luarocks upload --api-key <key> hy3-<version>-<serial>.rockspec
   # subsequent releases: just `luarocks upload <rockspec>`
   ```

Users can also install without the server at any point:
`luarocks install aarobc/hy3-lua`.

## Usage

In your Hyprland Lua config (`config.lua` or a file it requires). Two
things matter: `require("hy3")` must run **before** the `hl.config` call
that selects the layout (config files execute top to bottom), and the
LuaRocks tree must be on `package.path` first (see the note above).

```lua
-- 1. make the rock visible to Hyprland's interpreter
package.path = package.path .. ';' ..
    os.getenv('HOME') .. '/.luarocks/share/lua/5.4/?.lua'

-- 2. load the module; this registers the layout as 'lua:hy3'
require("hy3")

-- 3. select it (global or per monitor/workspace)
hl.config({ general = { layout = "lua:hy3" } })
```

Then bind the `layout_msg` commands. **Bind `hl.dsp.layout(…)` — not
`hl.dsp.window.move({ direction = … })` or `hl.dsp.focus({ direction =
… })`:** the built-in direction handlers are C++ that walk windows in raw
insertion order and ignore the layout's tree, so they do the wrong thing
once windows have been moved around. Routing through `layout_msg` lets
the layout's own persisted tree decide.

```lua
local mod = "SUPER"
local function hy3(msg) return hl.dsp.layout(msg) end

-- focus (wraps within the workspace; crosses to the nearest window on
-- the adjacent monitor past an edge)
hl.bind(mod .. "+h", hy3("focus left"))
hl.bind(mod .. "+l", hy3("focus right"))
hl.bind(mod .. "+k", hy3("focus up"))
hl.bind(mod .. "+j", hy3("focus down"))

-- move (past the workspace edge, hands the window to the adjacent
-- monitor's active workspace)
hl.bind(mod .. "+SHIFT+h", hy3("move left"))
hl.bind(mod .. "+SHIFT+l", hy3("move right"))
hl.bind(mod .. "+SHIFT+k", hy3("move up"))
hl.bind(mod .. "+SHIFT+j", hy3("move down"))

-- splits (sticky per-container orientation)
hl.bind(mod .. "+v", hy3("splitv"))      -- vertical split
hl.bind(mod .. "+s", hy3("splith"))      -- horizontal split
hl.bind(mod .. "+t", hy3("togglesplit"))
```

After changing the layout or its bindings, **restart Hyprland** — a
config reload re-runs your Lua, but a restart is the clean way to swap
layout registrations.

### `layout_msg` commands

| Command         | Behavior                                                    |
| --------------- | ----------------------------------------------------------- |
| `move <dir>`    | sway `move`; past the workspace edge, hands the window to the adjacent monitor's active workspace |
| `focus <dir>`   | sway `focus` with wrapping; past the edge, crosses to the nearest window on the adjacent monitor |
| `splitv`        | persistent vertical split at the focused container          |
| `splith`        | persistent horizontal split                                 |
| `togglesplit`   | toggle the focused container's orientation                  |

(`<dir>` is `left`, `right`, `up`, or `down`.)

## Debug

The module exposes `_G.hy3dbg`:

```sh
hyprctl repl 'return hy3dbg.dump()'   # pretty tree dump (fracs, focus marks)
hyprctl repl 'return hy3dbg.state'    # raw state table
```

Start Hyprland with `HY3_DEBUG_LOG=/tmp/hy3.log` for a per-recalculation
log (targets, active window, tree changes).

## Development

See [CLAUDE.md](CLAUDE.md) — it documents the docker test environment
(`environment/`), the battery scripts under `sandbox/`, and the
`hl.*` API gotchas. Quick start:

```sh
cd environment
docker compose build
docker compose up -d sway hyprland
# then, e.g.:
docker compose exec -T hyprland bash /root/code/hy3-lua/sandbox/battery.sh
```

## License

MIT — see [LICENSE](LICENSE).
