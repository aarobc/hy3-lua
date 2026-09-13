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

From LuaRocks.org:

```sh
luarocks install hy3
```

Or from a local checkout / rock file:

```sh
# from this repo
luarocks pack hy3-1.0.0-1.rockspec
luarocks --lua-version 5.4 install hy3-1.0.0-1.src.rock
```

> Note: `luarocks pack` with the committed rockspec clones the git
> remote, so local changes must be pushed first. To pack the uncommitted
> working tree, temporarily point `source.url` at a `file://` tarball of
> the tree (the tarball needs a single top-level directory).

Or from a git checkout without installing (Hyprland's config can
`require` from anywhere on `package.path`):

```lua
package.path = package.path .. ';/path/to/hy3-lua/src/?.lua'
require("hy3")
```

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

In your `config.lua`:

```lua
require("hy3")                 -- registers the layout as 'lua:hy3'
hl.config({ general = { layout = "lua:hy3" } })

local mod = "SUPER"
hl.bind(mod .. "+h", hl.dsp.layout("focus left"))
hl.bind(mod .. "+l", hl.dsp.layout("focus right"))
hl.bind(mod .. "+k", hl.dsp.layout("focus up"))
hl.bind(mod .. "+j", hl.dsp.layout("focus down"))

hl.bind(mod .. "+SHIFT+h", hl.dsp.layout("move left"))
hl.bind(mod .. "+SHIFT+l", hl.dsp.layout("move right"))
hl.bind(mod .. "+SHIFT+k", hl.dsp.layout("move up"))
hl.bind(mod .. "+SHIFT+j", hl.dsp.layout("move down"))

hl.bind(mod .. "+v", hl.dsp.layout("splitv"))       -- vertical split
hl.bind(mod .. "+s", hl.dsp.layout("splith"))       -- horizontal split
hl.bind(mod .. "+t", hl.dsp.layout("togglesplit"))
```

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
