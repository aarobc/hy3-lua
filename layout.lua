-- Compat shim: the layout module moved to src/sway.lua (module name 'sway',
-- published as the `hy3-sway` LuaRocks package). Old configs that still do
-- `require('layout')` keep working through this file. New configs should
-- `require('sway')` instead.
--
-- Works both from a git checkout (adds the repo's src/ dir to package.path)
-- and from a luarocks install (where `sway` sits next to this module).
local function tryRequireSway()
    return pcall(require, 'sway')
end

if not tryRequireSway() then
    local dir = debug.getinfo(1, 'S').source:match('^@(.*)/')
    if dir then
        package.path = package.path .. ';' .. dir .. 'src/?.lua'
    end
    if not tryRequireSway() then
        error("sway: layout module not found -- install the hy3-sway rock or add the repo's src/ dir to package.path")
    end
end
return require('sway')
