-- Minimal nested Hyprland config for hy3-lua comparison testing.
-- Launch with: Hyprland -c ~/code/hy3-lua/sandbox/hypr-nested.lua
-- See ../CLAUDE.md for the full workflow.

hl.config({ general = { layout = 'dwindle' } })

-- Uncomment once layout.lua has something worth loading:
-- package.path = package.path .. ";" .. os.getenv("HOME") .. "/code/hy3-lua/?.lua"
-- require("layout")
-- hl.config({ general = { layout = 'lua:sway' } })

local mod = 'SUPER'
local function sc(...) return table.concat({...}, ' + ') end

hl.bind(sc(mod, 'h'), hl.dsp.focus({ direction = 'left' }))
hl.bind(sc(mod, 'l'), hl.dsp.focus({ direction = 'right' }))
hl.bind(sc(mod, 'k'), hl.dsp.focus({ direction = 'up' }))
hl.bind(sc(mod, 'j'), hl.dsp.focus({ direction = 'down' }))

hl.bind(sc(mod, 'SHIFT', 'h'), hl.dsp.window.move({ direction = 'left' }))
hl.bind(sc(mod, 'SHIFT', 'l'), hl.dsp.window.move({ direction = 'right' }))
hl.bind(sc(mod, 'SHIFT', 'k'), hl.dsp.window.move({ direction = 'up' }))
hl.bind(sc(mod, 'SHIFT', 'j'), hl.dsp.window.move({ direction = 'down' }))

hl.bind(sc(mod, 'RETURN'), hl.dsp.exec('foot'))
hl.bind(sc(mod, 'q'), hl.dsp.window.close())
