-- Hyprland config for hy3-lua testing. Runs inside the docker test
-- environment: docker compose up -d hyprland (see ../environment/).
-- The repo is mounted at /root/code/hy3-lua, so the package.path below
-- resolves `require('hy3')` to ../src/hy3.lua.
-- See ../CLAUDE.md for the full workflow.

package.path = package.path .. ';' .. os.getenv('HOME') .. '/code/hy3-lua/src/?.lua'
require('hy3')
hl.config({ general = { layout = 'lua:hy3' } })

local mod = 'SUPER'
local function sc(...)
    return table.concat({ ... }, ' + ')
end

-- focus/move go through layout_msg so the layout's own tree decides
-- (the built-in hl.dsp.window.move / hl.dsp.focus direction handlers are
-- raw-insertion-order C++ and ignore our structure -- see CLAUDE.md)
hl.bind(sc(mod, 'h'), hl.dsp.layout('focus left'))
hl.bind(sc(mod, 'l'), hl.dsp.layout('focus right'))
hl.bind(sc(mod, 'k'), hl.dsp.layout('focus up'))
hl.bind(sc(mod, 'j'), hl.dsp.layout('focus down'))

hl.bind(sc(mod, 'SHIFT', 'h'), hl.dsp.layout('move left'))
hl.bind(sc(mod, 'SHIFT', 'l'), hl.dsp.layout('move right'))
hl.bind(sc(mod, 'SHIFT', 'k'), hl.dsp.layout('move up'))
hl.bind(sc(mod, 'SHIFT', 'j'), hl.dsp.layout('move down'))

-- split orientation (added to both sandbox configs for parity; sway has
-- no default binds for these)
hl.bind(sc(mod, 'v'), hl.dsp.layout('splitv'))
hl.bind(sc(mod, 's'), hl.dsp.layout('splith'))
hl.bind(sc(mod, 't'), hl.dsp.layout('togglesplit'))

hl.bind(sc(mod, 'RETURN'), hl.dsp.exec_cmd('foot'))
hl.bind(sc(mod, 'q'), hl.dsp.window.close())
