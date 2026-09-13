-- Compat shim: the layout module lives in src/hy3.lua (module name 'hy3',
-- published as the `hy3` LuaRocks package). Old configs that still do
-- `require('layout')` keep working through this file. New configs should
-- `require('hy3')` instead.
--
-- Works both from a git checkout (adds the repo's src/ dir to package.path)
-- and from a luarocks install (where `hy3` sits next to this module).
local function tryRequireHy3()
    return pcall(require, 'hy3')
end

if not tryRequireHy3() then
    local dir = debug.getinfo(1, 'S').source:match('^@(.*)/')
    if dir then
        package.path = package.path .. ';' .. dir .. 'src/?.lua'
    end
    if not tryRequireHy3() then
        error("hy3: layout module not found -- install the hy3 rock or add the repo's src/ dir to package.path")
    end
end
return require('hy3')
