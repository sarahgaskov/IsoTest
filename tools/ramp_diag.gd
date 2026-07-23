extends SceneTree

# Regression board for the ramp-chain outline fix (o_contact.gd's
# ramp_bridge): a straight stairs/slope tile placed at its own baked
# ramp_chain offset from an identical one should read as one continuous
# incline with no seam; anything else (different tile, different rotation,
# a lone tile) must be unaffected. Renders each case to tools/ramp_<name>.png
# and prints the resolved spans so a future change can diff both.

const NAMES = ["NW", "NE", "E ", "SE", "SW", "W "]

var _fail := 0

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var id := {}
	for i in data.tiles.size(): id[data.tiles[i].name] = i

	# Positive cases: a straight ramp tile chained into an identical one at
	# its own ramp_chain offset must fully bridge (no seam).
	_case(data, id, "stairs_e_chain", [[Vector3i(0, 0, 0), "stairs_e"], [Vector3i(1, 1, 0), "stairs_e"]], true)
	_case(data, id, "slope_e_chain", [[Vector3i(0, 0, 0), "slope_e"], [Vector3i(1, 1, 0), "slope_e"]], true)
	_case(data, id, "stairs_n_chain", [[Vector3i(0, 0, 0), "stairs_n"], [Vector3i(0, 1, -1), "stairs_n"]], true)

	# Negative controls: same offset, but not a matching chain — must NOT
	# fully bridge (still just ordinary depth-probe contact, if any).
	_case(data, id, "stairs_e_vs_slab", [[Vector3i(0, 0, 0), "stairs_e"], [Vector3i(1, 1, 0), "slab_5"]], false)
	_case(data, id, "stairs_e_vs_stairs_n", [[Vector3i(0, 0, 0), "stairs_e"], [Vector3i(1, 1, 0), "stairs_n"]], false)
	_case(data, id, "stairs_e_lone", [[Vector3i(0, 0, 0), "stairs_e"]], false)

	print("RESULT: %s" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	quit()

func _case(data: Dictionary, id: Dictionary, name: String, placements: Array, expect_full: bool) -> void:
	var grid = IsoGrid.new()
	var lib = MeshLibrary.new()
	for i in data.tiles.size(): lib.create_item(i)
	grid.mesh_library = lib
	root.add_child(grid)
	for p in placements:
		grid.set_cell_item(p[0], id[p[1]])
	grid._refresh_sprites()
	var types: Dictionary = grid._types

	var res = OcclusionContact.resolve(grid, placements[0][0], types)
	var parts := []
	var any_full = false
	for d in 6:
		if (res.neighbors & (1 << d)) != 0:
			parts.append("%s=[%.2f,%.2f]" % [NAMES[d], res.spans[d].x, res.spans[d].y])
			# A few % of corner residual (e.g. 0.93 not 1.00) is the same
			# "erase-less" corner-pixel jitter tolerated elsewhere in this
			# pipeline (occ_diag.gd) and doesn't show up in the render.
			if res.spans[d].x < 0.05 and res.spans[d].y > 0.9: any_full = true
	print("%s: %s" % [name, " ".join(parts) if not parts.is_empty() else "(none)"])
	if any_full != expect_full:
		_fail += 1
		print("  FAIL: expected %s to %s a fully-bridged edge" % [name, "have" if expect_full else "NOT have"])

	_render(data, grid, types, "ramp_%s" % name)
	grid.queue_free()
	root.remove_child(grid)

func _render(data: Dictionary, grid: GridMap, types: Dictionary, name: String) -> void:
	var f = Iso.facing()
	var raws = data.tilesheets.map(func(p):
		var img = Image.load_from_file(ProjectSettings.globalize_path(p))
		img.convert(Image.FORMAT_RGBA8)
		return img)
	var items := []
	var lo = Vector2(INF, INF)
	var hi = -lo
	for c in grid.get_used_cells():
		var type = types[grid.get_cell_item(c)]
		var world = grid.map_to_local(c)
		var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
		var tl = screen - type.origin
		items.append({"cell": c, "id": grid.get_cell_item(c), "tl": tl, "depth": world.dot(-f.z)})
		lo = Vector2(minf(lo.x, tl.x), minf(lo.y, tl.y))
		hi = Vector2(maxf(hi.x, tl.x + type.region_size.x), maxf(hi.y, tl.y + type.region_size.y))
	items.sort_custom(func(a, b): return a.depth > b.depth)
	var size = Vector2i((hi - lo).ceil()) + Vector2i.ONE
	var img = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.25, 0.25, 0.25))
	for it in items:
		var tile: Dictionary = data.tiles[it.id]
		var type: Dictionary = types[it.id]
		var r: Array = tile.region
		var res2 = OcclusionContact.resolve(grid, it.cell, types)
		var dir_of := {}
		for d in 6:
			for p in type.region_px[d]: dir_of[Vector2i(p)] = d
		for y in r[3]:
			for x in r[2]:
				var px = raws[tile.get("sheet", 0)].get_pixel(r[0] + x, r[1] + y)
				if px.a < 0.5: continue
				var d = dir_of.get(Vector2i(x, y), -1)
				if d >= 0 and _erased(type, res2, d, Vector2(x, y)): continue
				img.set_pixelv(Vector2i((it.tl - lo).round()) + Vector2i(x, y), Color(px.r, px.g, px.b, 1.0))
	img.resize(size.x * 8, size.y * 8, Image.INTERPOLATE_NEAREST)
	img.save_png("res://tools/%s.png" % name)

func _erased(type: Dictionary, res: Dictionary, d: int, p: Vector2) -> bool:
	if (res.neighbors & (1 << d)) == 0: return false
	var e: Vector4 = type.edges[d]
	var a = Vector2(e.x, e.y)
	var ab = Vector2(e.z, e.w) - a
	var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(type.region_size) - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return t >= res.spans[d].x and t <= res.spans[d].y
