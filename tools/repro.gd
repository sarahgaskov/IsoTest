extends SceneTree

# Reproduces the arrangements from the user's screenshot on the CPU pipeline:
# multi-cell ramps, 2x2 corner pyramids, and mixed-height slab plates.
# Composites to tools/repro.png (x2) for comparison against the GPU render.

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var grid = IsoGrid.new()
	var lib = MeshLibrary.new()
	for id in data.tiles.size(): lib.create_item(id)
	grid.mesh_library = lib
	root.add_child(grid)
	var id := {}
	for i in data.tiles.size(): id[data.tiles[i].name] = i

	# A: two-cell ramps (continuing slope up one layer)
	grid.set_cell_item(Vector3i(1, 0, 8), id.slope_w)
	grid.set_cell_item(Vector3i(0, 1, 8), id.slope_w)
	grid.set_cell_item(Vector3i(3, 0, 9), id.slope_n)
	grid.set_cell_item(Vector3i(3, 1, 8), id.slope_n)

	# B/C: 2x2 pyramids, apexes meeting at the center
	for py in [["corner_stairs_%s", 5, 6], ["corner_slope_%s", 8, 6]]:
		grid.set_cell_item(Vector3i(py[1], 0, py[2]), id[py[0] % "s"])
		grid.set_cell_item(Vector3i(py[1] + 1, 0, py[2]), id[py[0] % "w"])
		grid.set_cell_item(Vector3i(py[1], 0, py[2] + 1), id[py[0] % "e"])
		grid.set_cell_item(Vector3i(py[1] + 1, 0, py[2] + 1), id[py[0] % "n"])

	# D: mixed-height slab plates + stacking
	for x in 2: for z in 2:
		grid.set_cell_item(Vector3i(x, 0, z), id.slab_5)
		grid.set_cell_item(Vector3i(x, 1, z), id.slab_2)
		grid.set_cell_item(Vector3i(x + 2, 0, z), id.slab_3)
	for x in 4:
		grid.set_cell_item(Vector3i(x, 0, 2), id.slab_2)
		grid.set_cell_item(Vector3i(x, 0, 3), id.slab_1)

	grid._refresh_sprites()  # lazily builds the placed types (headless: no _process)
	var f = Iso.facing()
	var types: Dictionary = grid._types
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
		var res = OcclusionContact.resolve(grid, it.cell, types)
		var dir_of := {}
		for d in 6:
			for p in type.region_px[d]: dir_of[Vector2i(p)] = d
		for y in r[3]:
			for x in r[2]:
				var px = raws[tile.get("sheet", 0)].get_pixel(r[0] + x, r[1] + y)
				if px.a < 0.5: continue
				var d = dir_of.get(Vector2i(x, y), -1)
				if d >= 0 and _erased(type, res, d, Vector2(x, y)): continue
				img.set_pixelv(Vector2i((it.tl - lo).round()) + Vector2i(x, y), Color(px.r, px.g, px.b, 1.0))
	img.resize(size.x * 2, size.y * 2, Image.INTERPOLATE_NEAREST)
	img.save_png("res://tools/repro.png")
	print("repro: %d cells -> tools/repro.png" % items.size())
	quit()

func _erased(type: Dictionary, res: Dictionary, d: int, p: Vector2) -> bool:
	if (res.neighbors & (1 << d)) == 0: return false
	var e: Vector4 = type.edges[d]
	var a = Vector2(e.x, e.y)
	var ab = Vector2(e.z, e.w) - a
	var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(type.region_size) - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return t >= res.spans[d].x and t <= res.spans[d].y
