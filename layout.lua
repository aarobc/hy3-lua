-- hy3-lua: custom Hyprland layout emulating sway/i3 window movement and
-- persistent per-container splits.
--
-- See CLAUDE.md for scope (tabbed/stacked explicitly OUT of scope) and
-- notes/sway-spec.md for the empirical behavioral spec this implements
-- (sway 1.12, verified against nested instances).
--
-- Model: sway containers are n-ary. A workspace has a sticky `layout`
-- ('h' = splith, 'v' = splitv) and a flat child list; a container is a
-- node with its own sticky orientation, a flat child list, and a
-- main-axis fraction per child. Leaves carry fractions too. No binary
-- nesting anywhere -- that is the whole point.
--
-- Persistent state lives in the module table `S`, keyed by workspace id
-- (window.workspace.id). Everything Hyprland hands us per recalculate
-- (`ctx.targets`) is transient; the tree below is the only source of
-- truth for structure and fractions.
--
-- Commands (bound via hl.layout('<msg>'), see sandbox/hypr-nested.lua):
--   move left|right|up|down      sway `move <dir>` (spec section B)
--   focus left|right|up|down     sway `focus <dir>` w/ wrapping (spec supp.)
--   splitv | splith | togglesplit  spec section D

local S = {} -- [ws id] = { layout = 'h'|'v', children = { nodes } }
             -- node: { kind='win', id, frac }
             --   or { kind='con', orient, frac, last_focus, children }

-- ---------------------------------------------------------------- utils

local function parOf(dir)
    -- direction's parallel orientation: left/right -> 'h', up/down -> 'v'
    return (dir == 'left' or dir == 'right') and 'h' or 'v'
end

local function deltaOf(dir)
    return (dir == 'right' or dir == 'down') and 1 or -1
end

local function orientOf(c)
    -- root workspace node uses .layout, containers use .orient
    return c.layout or c.orient
end

local function leafId(t)
    if t.window and t.window.stable_id ~= nil then
        return t.window.stable_id
    end
    return 'i' .. t.index
end

local function indexOf(list, v)
    for i, x in ipairs(list) do
        if x == v then
            return i
        end
    end
end

local function findLeaf(root, id)
    local function rec(parent, children)
        for i, n in ipairs(children) do
            if n.kind == 'win' and n.id == id then
                return n, parent, i
            end
        end
        for _, n in ipairs(children) do
            if n.kind == 'con' then
                local r, p, i = rec(n, n.children)
                if r then
                    return r, p, i
                end
            end
        end
    end
    return rec(root, root.children)
end

local function findParent(root, child)
    for i, n in ipairs(root.children) do
        if n == child then
            return root
        end
        if n.kind == 'con' then
            local r = findParent(n, child)
            if r then
                return r
            end
        end
    end
end

local function removeNode(root, node)
    local P = findParent(root, node)
    local i = indexOf(P.children, node)
    if i then
        table.remove(P.children, i)
    end
end

-- The direct child of `con` on the remembered last-focus path (a window or
-- a container); fallback is the last child.
local function focusedChild(con)
    if con.last_focus then
        for _, c in ipairs(con.children) do
            if (c.kind == 'win' and c.id == con.last_focus)
                or (c.kind == 'con' and c.last_focus == con.last_focus) then
                return c
            end
        end
    end
    return con.children[#con.children]
end

-- The focused window inside `con` (its remembered last focus), recursing
-- into containers. Always a window or nil.
local function descendToWindow(con)
    local n = con
    while n and n.kind == 'con' do
        n = focusedChild(n)
    end
    return n
end

-- Mark every container on the path to window `id` as last-focused-it.
local function setLastFocusPath(root, id)
    local function rec(parent, children)
        for _, n in ipairs(children) do
            if n.kind == 'win' and n.id == id then
                parent.last_focus = id
                return true
            end
            if n.kind == 'con' and rec(n, n.children) then
                n.last_focus = id
                return true
            end
        end
        return false
    end
    rec(root, root.children)
end

-- ------------------------------------------------- fractions (spec A.3, C)

-- Per-parent fraction pass, mirroring sway's arrange:
--   children with frac <= 0 get the AVERAGE OF THE EXISTING (positive)
--   siblings' fractions, then all fractions renormalize to sum 1
--   (proportional redistribution on close; equal shares after a
--   promotion; sole child -> 1.0).
local function normalize(children)
    local npos = 0
    local possum = 0
    for _, c in ipairs(children) do
        if c.frac > 0 then
            npos = npos + 1
            possum = possum + c.frac
        end
    end
    for _, c in ipairs(children) do
        if c.frac <= 0 then
            c.frac = npos > 0 and (possum / npos) or 1.0
        end
    end
    local s = 0
    for _, c in ipairs(children) do
        s = s + c.frac
    end
    if s > 0 then
        for _, c in ipairs(children) do
            c.frac = c.frac / s
        end
    end
end

local function normalizeAll(children)
    for _, c in ipairs(children) do
        if c.kind == 'con' then
            normalizeAll(c.children)
        end
    end
    normalize(children)
end

-- ------------------------------------------------------------------ ctx

-- Extract (ws id, active window id, live targets map) from a layout ctx.
local function prep(ctx)
    local targets = {}
    local wid = nil
    local activeId = nil
    for _, t in ipairs(ctx.targets) do
        local id = leafId(t)
        targets[id] = t
        if t.window then
            if t.window.workspace and not wid then
                wid = t.window.workspace.id
            end
            if t.window.active and not activeId then
                activeId = id
            end
        end
    end
    return wid, activeId, targets
end

local function getRoot(wid)
    local r = S[wid]
    if not r then
        r = { layout = 'h', children = {} } -- sway default_orientation splith
        S[wid] = r
    end
    return r
end

-- ----------------------------------------------------------------- place

local function placeAll(targets, children, box, orient)
    local x, y = box.x, box.y
    for _, c in ipairs(children) do
        local bw, bh
        if orient == 'h' then
            bw, bh = box.w * c.frac, box.h
        else
            bw, bh = box.w, box.h * c.frac
        end
        local b = { x = x, y = y, w = bw, h = bh }
        if c.kind == 'win' then
            local t = targets[c.id]
            if t then
                t:place(b)
            end
        else
            placeAll(targets, c.children, b, c.orient)
        end
        if orient == 'h' then
            x = x + bw
        else
            y = y + bh
        end
    end
end

-- ------------------------------------------------------------ recalculate

local DBGLOG = os.getenv('HY3_DEBUG_LOG')
local dbgseq = 0
local function dbg(fmt, ...)
    if not DBGLOG then
        return
    end
    dbgseq = dbgseq + 1
    local f = io.open(DBGLOG, 'a')
    if f then
        f:write(string.format('[%d] ' .. fmt .. '\n', dbgseq, ...))
        f:close()
    end
end

local function recalculate(ctx)
    local n = #ctx.targets
    if n == 0 then
        return
    end
    local wid, activeId, targets = prep(ctx)
    if not wid then
        -- targets without window info: fall back to plain columns
        for i, t in ipairs(ctx.targets) do
            t:place(ctx:column(i, n))
        end
        return
    end
    local root = getRoot(wid)

    local live = {}
    for id in pairs(targets) do
        live[id] = true
    end
    local idlist = {}
    for id in pairs(targets) do
        idlist[#idlist + 1] = tostring(id)
    end
    table.sort(idlist)
    dbg('recalc n=%d ids=[%s] active=%s prevActive=%s', n, table.concat(idlist, ','), tostring(activeId), tostring(prevActive))

    -- 1. close: drop dead leaves; reap empty containers (C.17-C.19)
    local function pruneDead(children)
        local m = #children
        for i = m, 1, -1 do
            local c = children[i]
            if c.kind == 'win' then
                if not live[c.id] then
                    table.remove(children, i)
                end
            else
                pruneDead(c.children)
                if #c.children == 0 then
                    table.remove(children, i)
                end
            end
        end
    end
    pruneDead(root.children)

    -- 2. new window: sibling immediately after the focused window in its
    --    innermost container (spec A.2 / rule a.2); never auto-wrapped.
    --    A map-time recalc reports the PRE-MAP focused window as active
    --    (focus settles on the new window after it), so activeId is exactly
    --    sway's insertion anchor; if it is itself new/missing, fall back to
    --    top level.
    local insertedNew = false
    for id in pairs(targets) do
        if not findLeaf(root, id) then
            local parent, idx
            if activeId then
                local _, p, i = findLeaf(root, activeId)
                if p then
                    parent, idx = p, i + 1
                end
            end
            if not parent then
                parent, idx = root, #root.children + 1
            end
            table.insert(parent.children, idx, { kind = 'win', id = id, frac = 0 })
            dbg('insert %s parent=%s idx=%d', tostring(id), parent == root and 'root' or parent.orient, idx)
            -- the new window takes focus on map
            setLastFocusPath(root, id)
            insertedNew = true
        end
    end

    -- keep each container's remembered last-focus in sync with real focus
    -- (recalcs fire after focus changes and closes). Skipped on insert
    -- passes: at map time activeId is still the PRE-MAP window, so syncing
    -- would clobber the just-inserted window's focus mark.
    if not insertedNew and activeId then
        local l = findLeaf(root, activeId)
        if l then
            setLastFocusPath(root, activeId)
        end
    end

    normalizeAll(root.children)
    placeAll(targets, root.children, ctx.area, root.layout)
end

-- ----------------------------------------------------------------- move

-- Reparent `leaf` (already removed) relative to container target T
-- (mover was a direct child of a parallel parent; spec B.8-B.11).
local function insertIntoTarget(leaf, T, par, delta)
    leaf.frac = 0
    if orientOf(T) == par then
        -- parallel container: first child for right/down, last for left/up
        if delta > 0 then
            table.insert(T.children, 1, leaf)
        else
            table.insert(T.children, leaf)
        end
    else
        -- perpendicular container: descend to its focused child; if that
        -- child is a container, RECURSE (spec b.2, B.8); otherwise insert
        -- adjacent to it (right/down: at its index; left/up: after it).
        local F = focusedChild(T)
        if F and F.kind == 'win' then
            local fi = indexOf(T.children, F)
            table.insert(T.children, fi + (delta > 0 and 0 or 1), leaf)
        elseif F and F.kind == 'con' then
            insertIntoTarget(leaf, F, par, delta)
        else
            table.insert(T.children, leaf)
        end
    end
end

-- Reparent `leaf` (already removed) next to sibling target T when the
-- mover came from a crawled-up ancestor (spec B.8b/B.9/B.12).
local function insertNextTo(root, leaf, T, par, delta)
    leaf.frac = 0
    if T.kind == 'win' then
        local P = findParent(root, T)
        local ti = indexOf(P.children, T)
        -- "on the side it came from": left/up movers land right of the
        -- target (index+1), right/down movers land left of it (index).
        table.insert(P.children, ti + (delta < 0 and 1 or 0), leaf)
    else
        insertIntoTarget(leaf, T, par, delta)
    end
end

local function doMove(ctx, dir)
    local wid, fid = prep(ctx)
    local root = wid and S[wid] or nil
    if not root or not fid then
        return 'sway: no focused window'
    end
    local leaf = findLeaf(root, fid)
    if not leaf then
        return 'sway: focused window not in tree'
    end
    local par = parOf(dir)
    local delta = deltaOf(dir)

    -- climb to the first parallel level with a target sibling; a lone
    -- mover at a parallel-but-full level keeps climbing (spec b.2);
    -- no parallel level at all -> re-orient the workspace (spec B.14).
    local C = leaf
    local P = nil
    while true do
        P = findParent(root, C)
        if orientOf(P) ~= par then
            if P == root then
                local nc = {
                    kind = 'con',
                    orient = orientOf(root),
                    frac = 1.0,
                    last_focus = fid,
                    children = root.children,
                }
                root.children = { nc }
                root.layout = par
                C, P = nc, root
                break
            end
            C = P
        else
            local i = indexOf(P.children, C)
            if P.children[i + delta] or C ~= leaf or P == root then
                break
            end
            C = P
        end
    end

    local i = indexOf(P.children, C)
    local T = P.children[i + delta]

    if T then
        if C == leaf then
            if T.kind == 'win' then
                -- plain adjacent-sibling swap; percents travel (spec B.7)
                P.children[i], P.children[i + delta] = T, C
            else
                removeNode(root, leaf)
                insertIntoTarget(leaf, T, par, delta)
            end
        else
            removeNode(root, leaf)
            insertNextTo(root, leaf, T, par, delta)
        end
    else
        if C == leaf and P == root then
            -- past-the-end at workspace level: sway would attempt a
            -- cross-output hand-off; single-monitor here -> no-op (B.13)
            return true
        end
        -- promotion: mover becomes a child of P next to its own parent
        -- container; mover's and the container's fractions reset (B.10).
        removeNode(root, leaf)
        leaf.frac = 0
        C.frac = 0
        table.insert(P.children, i + (delta < 0 and 0 or 1), leaf)
    end

    setLastFocusPath(root, fid)
    return true
end

-- ---------------------------------------------------------------- focus

local function doFocus(ctx, dir)
    local wid, fid, targets = prep(ctx)
    local root = wid and S[wid] or nil
    if not root or not fid then
        return 'sway: no focused window'
    end
    local leaf = findLeaf(root, fid)
    if not leaf then
        return 'sway: focused window not in tree'
    end
    local par = parOf(dir)
    local delta = deltaOf(dir)

    -- levels from bottom up; a target at any level beats wrapping at a
    -- shallower one; failing all, wrap at the DEEPEST parallel level
    -- (sway focus_wrapping); no parallel level at all -> no-op.
    local C = leaf
    local deepest = nil
    local target = nil
    while true do
        local P = findParent(root, C)
        if orientOf(P) == par then
            local i = indexOf(P.children, C)
            if not deepest then
                deepest = { P = P, i = i }
            end
            local T = P.children[i + delta]
            if T then
                target = T
                break
            end
        end
        if P == root then
            break
        end
        C = P
    end
    if not target then
        if not deepest then
            return true
        end
        target = deepest.P.children[delta > 0 and 1 or #deepest.P.children]
    end

    local w = descendToWindow(target)
    if not w then
        return true
    end
    setLastFocusPath(root, w.id)
    local t = targets[w.id]
    if t and t.window then
        -- note: string selectors (address/title) resolve as "window not
        -- found" in this build; the HL.Window object itself works.
        hl.dispatch(hl.dsp.focus({ window = t.window }))
    end
    return true
end

-- ----------------------------------------------------------------- split

local function doSplit(ctx, arg)
    local wid, fid = prep(ctx)
    local root = wid and S[wid] or nil
    if not root or not fid then
        return 'sway: no focused window'
    end
    local leaf, P, idx = findLeaf(root, fid)
    if not leaf then
        return 'sway: focused window not in tree'
    end
    if arg == 'togglesplit' then
        -- opposite of the focused window's PARENT layout (spec d.5)
        arg = orientOf(P) == 'v' and 'h' or 'v'
    end
    if #P.children == 1 then
        -- singleton rule: rewrite the parent's (or workspace's) layout,
        -- no wrapper (spec D.22 / rule d.4)
        if P == root then
            root.layout = arg
        else
            P.orient = arg
        end
    else
        -- wrapper: replaces the leaf in its exact slot (spec A.4 / d.4)
        local old = leaf.frac -- capture BEFORE resetting to 1.0
        leaf.frac = 1.0
        P.children[idx] = {
            kind = 'con',
            orient = arg,
            frac = old,
            last_focus = fid,
            children = { leaf },
        }
    end
    setLastFocusPath(root, fid)
    return true
end

-- ------------------------------------------------------------------ msg

hl.layout.register('sway', {
    recalculate = recalculate,

    layout_msg = function(ctx, msg)
        local parts = {}
        for w in (msg or ''):gmatch('%S+') do
            parts[#parts + 1] = w
        end
        local cmd, arg = parts[1], parts[2]
        if cmd == 'move' then
            return doMove(ctx, arg)
        elseif cmd == 'focus' then
            return doFocus(ctx, arg)
        elseif cmd == 'splitv' then
            return doSplit(ctx, 'v')
        elseif cmd == 'splith' then
            return doSplit(ctx, 'h')
        elseif cmd == 'togglesplit' then
            return doSplit(ctx, 'togglesplit')
        end
        return 'sway: unknown command: ' .. tostring(msg)
    end,
})

-- debug: `hyprctl -i <sig> repl 'return swaydbg.dump()'`
_G.swaydbg = {
    state = S,
    dump = function()
        local out = {}
        for wid, root in pairs(S) do
            out[#out + 1] = string.format('ws %d layout=%s', wid, root.layout)
            local function rec(n, ind)
                local s = string.rep('  ', ind)
                if n.kind == 'win' then
                    s = s .. 'win ' .. tostring(n.id)
                else
                    s = s .. 'con ' .. n.orient
                end
                s = string.format('%s frac=%.4f', s, n.frac or 0)
                if n.last_focus then
                    s = s .. ' focus=' .. tostring(n.last_focus)
                end
                out[#out + 1] = s
                for _, c in ipairs(n.children or {}) do
                    rec(c, ind + 1)
                end
            end
            for _, c in ipairs(root.children) do
                rec(c, 1)
            end
        end
        if #out == 0 then
            return '(no state)'
        end
        return table.concat(out, '\n')
    end,
}
