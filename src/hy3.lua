-- hy3: custom Hyprland layout (HYprland + i3) emulating sway/i3 window
-- movement and persistent per-container splits. Module name: `hy3`
-- (published as the `hy3` LuaRocks package); requiring it
-- self-registers the layout as 'lua:hy3'.
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
--   move left|right|up|down      sway `move <dir>` (spec section B);
--                                past-the-end at the workspace edge does the
--                                cross-output hand-off (notes/dual-monitor.md
--                                M.1/M.3/M.4/X.1/X.4, M.2 screen-edge no-op)
--   focus left|right|up|down     sway `focus <dir>` w/ wrapping (spec supp.);
--                                past the edge crosses to the geometrically
--                                nearest window on the adjacent monitor
--                                (F.1), no-op at the screen edge (F.3)
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

-- A prune can leave containers pointing at a removed window; drop stale
-- last-focus marks so focusedChild() falls back to the last child.
local function repairFocus(node)
    if node.last_focus and not findLeaf(node, node.last_focus) then
        node.last_focus = nil
    end
    for _, c in ipairs(node.children or {}) do
        if c.kind == 'con' then
            repairFocus(c)
        end
    end
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

-- [ws id] = last ctx.area, for scale/coord debugging (shared with hy3dbg)
local dbgareas = {}

-- Drop the remembered trees of workspaces that have no live tiled
-- windows (they keep their root layout; sway keeps empty-workspace
-- orientation). Called from the empty-targets recalc and from
-- hy3dbg.dump(): closing the LAST window on a workspace triggers no
-- recalc at all, so the dead tree would otherwise linger in S until
-- the next window opens (invisible except through the debug dump).
local function pruneEmptyWorkspaces()
    local liveWs = {}
    for _, w in ipairs(hl.get_windows()) do
        if w.workspace and not w.floating then
            liveWs[w.workspace.id] = true
        end
    end
    for wid in pairs(S) do
        if not liveWs[wid] then
            local r = S[wid]
            S[wid] = { layout = r and r.layout or 'h', children = {} }
        end
    end
end

local function recalculate(ctx)
    local n = #ctx.targets
    if n == 0 then
        pruneEmptyWorkspaces()
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
    dbgareas[wid] = { x = ctx.area.x, y = ctx.area.y, w = ctx.area.w, h = ctx.area.h }

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
    repairFocus(root)

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

-- ------------------------------------------------- cross-monitor (M.*/F.*)

-- The index in `root.children` of the child on the remembered last-focus
-- path (fallback: last child).
local function focusedRootIndex(root)
    if root.last_focus then
        for i, c in ipairs(root.children) do
            if (c.kind == 'win' and c.id == root.last_focus)
                or (c.kind == 'con' and findLeaf(c, root.last_focus)) then
                return i
            end
        end
    end
    return #root.children
end

-- Absolute screen-space center of a window, from its rendered `at`/`size`
-- (nil if the window is not currently mapped). Window geometry IS in a
-- shared absolute screen coordinate space across monitors -- verified on a
-- 2-output setup: a window on the right output reports x > the left
-- output's width -- so cross-monitor "nearest window" is a plain Euclidean
-- comparison on these centers. (This is different from ctx.area, whose
-- per-workspace spaces do NOT share a scale; that was the reason for the
-- old ratio-only pick, which is what made the far-side window on the
-- adjacent monitor look "nearer" than the boundary-adjacent one.)
local function winCenter(stableId)
    for _, w in ipairs(hl.get_windows()) do
        if w.stable_id == stableId and w.at and w.size then
            return w.at.x + w.size.x / 2, w.at.y + w.size.y / 2
        end
    end
    return nil
end

-- The monitor in `dir`'s direction sharing an edge with `m` (nil at the
-- screen edge). Overlap test on the other axis, adjacency on this one.
-- Monitor geometry is used ONLY for this adjacency/ordering test, never
-- for layout math (see winCenter).
local function findAdjacentMonitor(m, dir)
    local cands = {}
    for _, mo in ipairs(hl.get_monitors()) do
        if mo.id ~= m.id then
            local mw, mh = m.width, m.height
            local ok
            if dir == 'right' then
                ok = mo.x >= m.x + mw and mo.y < m.y + mh and m.y < mo.y + mo.height
            elseif dir == 'left' then
                ok = m.x >= mo.x + mo.width and mo.y < m.y + mh and m.y < mo.y + mo.height
            elseif dir == 'down' then
                ok = mo.y >= m.y + mh and mo.x < m.x + mw and m.x < mo.x + mo.width
            else
                ok = m.y >= mo.y + mo.height and mo.x < m.x + mw and m.x < mo.x + mo.width
            end
            if ok then
                cands[#cands + 1] = mo
            end
        end
    end
    if #cands == 0 then
        return nil
    end
    table.sort(cands, function(a, b)
        local da = math.abs(a.x - (m.x + m.width)) + math.abs(a.y - (m.y + m.height))
        local db = math.abs(b.x - (m.x + m.width)) + math.abs(b.y - (m.y + m.height))
        return da < db
    end)
    return cands[1]
end

-- Move the edge `leaf` to the active workspace of the adjacent monitor
-- (M.1/M.3/M.4). Insertion rules:
--   target root parallel to the move  -> entry edge (right/down: index 0,
--                                         left/up: end)  (M.1/X.1/M.1b)
--   target root perpendicular         -> at the focused root child's index
--                                        (X.4)
--   empty target                      -> sole child  (M.3)
local function doCross(ctx, wid, leaf, leafWin, dir)
    local par = parOf(dir)
    local delta = deltaOf(dir)
    local m = leafWin and leafWin.monitor
    if not m then
        return true
    end
    local adj = findAdjacentMonitor(m, dir)
    if not adj then
        return true -- screen edge: no-op (M.2)
    end
    local tws = adj.active_workspace
    if not tws or not tws.id then
        return true
    end
    local twid = tws.id
    if twid == wid then
        return true
    end
    -- pull the leaf out of the source tree, keep fractions consistent
    local root = S[wid]
    removeNode(root, leaf)
    repairFocus(root)
    normalizeAll(root.children)

    -- insert into the target workspace's tree
    local troot = getRoot(twid)
    leaf.frac = 0
    if #troot.children == 0 then
        table.insert(troot.children, leaf)
    elseif orientOf(troot) == par then
        if delta > 0 then
            table.insert(troot.children, 1, leaf)
        else
            table.insert(troot.children, leaf)
        end
    else
        local fi = focusedRootIndex(troot)
        table.insert(troot.children, fi + (delta > 0 and 0 or 1), leaf)
    end
    setLastFocusPath(troot, leaf.id)
    repairFocus(troot)
    normalizeAll(troot.children)
    dbg('cross %s ws%d -> ws%d', tostring(leaf.id), wid, twid)

    -- actually move the window to the target workspace. First-class API
    -- (legacy 'movetoworkspace' via exec_raw silently no-ops in
    -- Lua-config builds). The tree is mutated BEFORE the move so the
    -- target workspace's post-move recalc finds the leaf already at its
    -- planned slot instead of inserting it at the focus anchor.
    -- follow=true: focus follows the moved window (M.1).
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(tws.name), window = leafWin, follow = true }))
    return true
end

-- `focus <dir>` past the workspace edge: cross to the geometrically
-- nearest window on the adjacent monitor's active workspace (F.1);
-- empty target workspace or screen edge -> no-op (F.2/F.3).
local function doFocusCross(ctx, wid, leaf, dir, targets)
    local win = targets[leaf.id]
    local m = win and win.window and win.window.monitor
    if not m then
        return true
    end
    local adj = findAdjacentMonitor(m, dir)
    if not adj then
        return nil -- F.3: no adjacent monitor; caller falls back to wrap
    end
    local tws = adj.active_workspace
    if not tws or not tws.id then
        return true
    end
    local troot = S[tws.id]
    if not troot or #troot.children == 0 then
        return true -- F.2: empty target focuses the workspace node
    end
    -- geometrically nearest window, compared in ABSOLUTE screen space
    -- (see winCenter). The source window sits at the workspace edge, so its
    -- closest candidate across the boundary is the boundary-adjacent one --
    -- a ratio-only comparison used to pick the far-side window instead.
    local sx, sy = winCenter(leaf.id)
    if not sx then
        return true
    end
    local bestd, bestid
    local function pick(children)
        for _, c in ipairs(children) do
            if c.kind == 'win' then
                local cx, cy = winCenter(c.id)
                if cx then
                    local d = (cx - sx) ^ 2 + (cy - sy) ^ 2
                    if not bestd or d < bestd then
                        bestd, bestid = d, c.id
                    end
                end
            else
                pick(c.children)
            end
        end
    end
    pick(troot.children)
    if not bestid then
        return true
    end
    setLastFocusPath(troot, bestid)
    for _, w in ipairs(hl.get_windows()) do
        if w.stable_id == bestid and w.workspace and w.workspace.id == tws.id then
            hl.dispatch(hl.dsp.focus({ window = w }))
            break
        end
    end
    dbg('focuscross ws%d -> ws%d win %s', wid, tws.id, tostring(bestid))
    return true
end

local function doMove(ctx, dir)
    local wid, fid, targets = prep(ctx)
    local root = wid and S[wid] or nil
    if not root or not fid then
        return 'hy3: no focused window'
    end
    local leaf = findLeaf(root, fid)
    if not leaf then
        return 'hy3: focused window not in tree'
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
            -- past-the-end at workspace level: cross-output hand-off if an
            -- adjacent monitor exists (M.1); screen edge -> no-op (M.2)
            local t = targets[fid]
            return doCross(ctx, wid, leaf, t and t.window, dir)
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
        return 'hy3: no focused window'
    end
    local leaf = findLeaf(root, fid)
    if not leaf then
        return 'hy3: focused window not in tree'
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
        -- past the workspace edge: crossing an adjacent monitor beats
        -- wrapping (F.1 -- edge focus goes to the nearest window on the
        -- next monitor, NOT back to the opposite end); only at the true
        -- screen edge (no adjacent monitor) does the fallback become a
        -- wrap at the deepest parallel level.
        if doFocusCross(ctx, wid, leaf, dir, targets) then
            return true
        end
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
        return 'hy3: no focused window'
    end
    local leaf, P, idx = findLeaf(root, fid)
    if not leaf then
        return 'hy3: focused window not in tree'
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

hl.layout.register('hy3', {
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
        return 'hy3: unknown command: ' .. tostring(msg)
    end,
})

-- Keep each container's remembered last-focus in step with the REAL focused
-- window, including focus changes that never go through layout_msg (click-
-- driven focus, focusing by workspace/monitor/title, cross-monitor focus
-- cross). Recalcs only fire on topology changes -- and a map-time recalc
-- reports the PRE-map window as active -- so neither of them tracks a bare
-- focus change. Without this, focusedChild() descends into a stale
-- last-focus child and a perpendicular `move` lands the mover adjacent to
-- the wrong window (frequently the first/top one), which is the
-- "always moves to the top" divergence from sway. sway descends into the
-- container's *currently-focused* child; this is what makes that match.
--
-- Guarded by findLeaf: if the event fires before a window has been inserted
-- into the tree (e.g. right after a map, before the recalc) or while a move
-- is mid-flight, the handler is a no-op rather than clobbering state.
local function onWindowActive()
    local w = hl.get_active_window and hl.get_active_window() or nil
    if not w or not w.workspace then
        return
    end
    local root = S[w.workspace.id]
    if root and findLeaf(root, w.stable_id) then
        setLastFocusPath(root, w.stable_id)
    end
end
local windowActiveSub = hl.on('window.active', onWindowActive)

-- debug: `hyprctl -i <sig> repl 'return hy3dbg.dump()'`
_G.hy3dbg = {
    state = S,
    areas = dbgareas,
    windowActiveSub = windowActiveSub,
    dump = function()
        pruneEmptyWorkspaces()
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

-- Module return: the debug table (convenient from a repl). The layout is
-- self-registered as a side effect of the require.
return _G.hy3dbg
