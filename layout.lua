-- hy3-lua: custom Hyprland layout emulating sway/i3 window movement and
-- persistent per-container splits.
--
-- SCOPE (see CLAUDE.md):
--   - directional window movement (mod+shift+dir) that respects a real,
--     persisted tree, not dwindle's opaque one
--   - persistent split orientation per container (sway's splitv/splith,
--     "next window inherits the container's last split direction")
-- OUT OF SCOPE:
--   - tabbed / stacked containers (sway's `layout tabbed`/`stacking`) -
--     do not implement, do not add hooks for it
--
-- Not implemented yet. See CLAUDE.md for the comparison workflow to use
-- while building this out.

hl.layout.register('sway', {
	recalculate = function(ctx)
		-- TODO: replace with real tree-based placement.
		for i, target in ipairs(ctx.targets) do
			target:place(ctx:column(i, #ctx.targets))
		end
	end,
})
