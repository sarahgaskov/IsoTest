extends SceneTree

# Verifies the generated meshes against the dev sheets: every tile's
# rasterized silhouette must coincide with its sprite art (within the 2 px
# outline ring), then a demo layout is composited to tools/fit_scene.png the
# same way occ_diag.gd does, as a visual check of rotations + occlusion.

const ALLOW = 2  # px: art outline sits just outside the mesh silhouette
const HARD = 4   # px: the art rounds stepped silhouettes by up to this much
                 # (risers are drawn as uniform 6 px periods vs the geometric
                 # ~6.9, anchored at the top plateau — measured, not assumed)

var _fail := 0

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var grid = IsoGrid.new()
	var lib = MeshLibrary.new()
	for id in data.tiles.size(): lib.create_item(id)
	grid.mesh_library = lib
	root.add_child(grid)
	grid._build_types(range(data.tiles.size()))  # this tool checks every tile

	_check_fit(grid, data)
	_render_demo(grid, data)
	print("RESULT: %s" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	quit()

func _check_fit(grid: IsoGrid, data: Dictionary) -> void:
	var raws = data.tilesheets.map(func(p):
		var img = Image.load_from_file(ProjectSettings.globalize_path(p))
		img.convert(Image.FORMAT_RGBA8)
		return img)
	for id in data.tiles.size():
		var tile: Dictionary = data.tiles[id]
		var r: Array = tile.region
		var art: Image = raws[tile.get("sheet", 0)].get_region(Rect2i(r[0], r[1], r[2], r[3]))
		var size = Vector2i(r[2], r[3])
		var off: Array = tile.get("offset_px", [0, 0])
		var depth = MeshDepth.rasterize(grid._faces(tile), size, Vector2(off[0], off[1]))

		var soft = 0
		var hard = 0
		for y in size.y:
			for x in size.x:
				var a = art.get_pixel(x, y).a > 0.5
				var m = MeshDepth.covered(depth, size, Vector2(x + 0.5, y + 0.5))
				if a and not m and not _near(depth, size, x, y, ALLOW):
					soft += 1
					if not _near(depth, size, x, y, HARD): hard += 1
				if m and not a and not _near_art(art, x, y, ALLOW):
					soft += 1
					if not _near_art(art, x, y, HARD): hard += 1
		var present = grid._types[id].present if grid._types.has(id) else -1
		print("%-16s rounded=%d off=%d present=%s" % [tile.name, soft, hard,
			String.num_int64(present, 2).pad_zeros(6)])
		if hard > 0 or present == 0: _fail += 1

func _near(depth: PackedVector2Array, size: Vector2i, x: int, y: int, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if MeshDepth.covered(depth, size, Vector2(x + dx + 0.5, y + dy + 0.5)):
				return true
	return false

func _near_art(art: Image, x: int, y: int, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var px = x + dx
			var py = y + dy
			if px >= 0 and py >= 0 and px < art.get_width() and py < art.get_height() \
					and art.get_pixel(px, py).a > 0.5:
				return true
	return false

# name -> id from tiles.json order, for a readable layout table.
func _ids(data: Dictionary) -> Dictionary:
	var ids := {}
	for id in data.tiles.size(): ids[data.tiles[id].name] = id
	return ids

func _render_demo(grid: IsoGrid, data: Dictionary) -> void:
	var id := _ids(data)
	for x in 3: for z in 3: grid.set_cell_item(Vector3i(x, 0, z), id.slab_5)
	for x in 2: for z in 2: grid.set_cell_item(Vector3i(x, 1, z), id.slab_5)
	for x in 2: grid.set_cell_item(Vector3i(x, 1, 2), id.stairs_n)
	for x in 3: grid.set_cell_item(Vector3i(x, 0, 3), id.stairs_n)
	grid.set_cell_item(Vector3i(3, 0, 3), id.corner_stairs_n)
	for n in 5: grid.set_cell_item(Vector3i(5 + n, 0, 0), id["slab_%d" % (n + 1)])
	var quartet = ["n", "e", "s", "w"]
	for i in 4:
		grid.set_cell_item(Vector3i(5 + i * 2, 0, 3), id["stairs_%s" % quartet[i]])
		grid.set_cell_item(Vector3i(5 + i * 2, 0, 5), id["corner_stairs_%s" % quartet[i]])
		grid.set_cell_item(Vector3i(5 + i * 2, 0, 7), id["slope_%s" % quartet[i]])
		grid.set_cell_item(Vector3i(5 + i * 2, 0, 9), id["corner_slope_%s" % quartet[i]])

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
	img.save_png("res://tools/fit_scene.png")
	print("demo scene: %d cells -> tools/fit_scene.png %s" % [items.size(), size])

func _erased(type: Dictionary, res: Dictionary, d: int, p: Vector2) -> bool:
	if (res.neighbors & (1 << d)) == 0: return false
	var e: Vector4 = type.edges[d]
	var a = Vector2(e.x, e.y)
	var ab = Vector2(e.z, e.w) - a
	var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(type.region_size) - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return t >= res.spans[d].x and t <= res.spans[d].y
