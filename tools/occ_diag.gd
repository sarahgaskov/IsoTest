extends SceneTree

# Headless verifier for the mesh-driven occlusion (docs/occlusion_mesh_plan.md
# section 5). Checks the rasterized depth tile, prints per-offset contact
# spans, then simulates the shader for every cell in the level and diffs the
# visible pixels against the all-or-nothing baseline (ALIGN=0.6, full spans).

const ALIGN = 0.6

var _fail := 0

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

# The original all-cube terraced regression scene, built from slab_5.
func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var grid = IsoGrid.new()
	var lib = MeshLibrary.new()
	for i in data.tiles.size(): lib.create_item(i)
	grid.mesh_library = lib
	root.add_child(grid)
	for x in 3:
		for z in range(-2, 5): grid.set_cell_item(Vector3i(x, 1, z), 0)
		for z in range(-2, 0): grid.set_cell_item(Vector3i(x, 2, z), 0)
		grid.set_cell_item(Vector3i(x, 3, -2), 0)
	grid._refresh_sprites()  # lazily builds the placed types (headless: no _process)
	var types: Dictionary = grid._types
	if not types.has(0):
		print("RESULT: FAIL (no types)")
		quit()
		return

	_check_extent(types[0])
	_print_spans(grid, types)
	_diff_scene(grid, types)

	print("RESULT: %s" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	quit()

func _check_extent(type: Dictionary) -> void:
	var size: Vector2i = type.region_size
	var lo = Vector2i(size)
	var hi = Vector2i(-1, -1)
	for y in size.y:
		for x in size.x:
			if type.depth[y * size.x + x].x != INF:
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	print("depth extent: x[%d..%d] y[%d..%d] in %s" % [lo.x, hi.x, lo.y, hi.y, size])
	if lo.x != 8 or hi.x != 55:
		_fail += 1
		print("  FAIL: expected x[8..55] for the 48px cube silhouette")
	print("edges (UV): ", type.edges)

func _print_spans(grid: GridMap, types: Dictionary) -> void:
	var names = ["NW", "NE", "E ", "SE", "SW", "W "]
	OcclusionContact.clear()
	for off in OcclusionContact._neighbor_offsets():
		var contact = OcclusionContact._contact(grid, 0, 0, types[0], types[0], off)
		var parts := []
		for d in 6:
			for r in contact[d]:
				parts.append("%s=[%.2f,%.2f]" % [names[d], r.x, r.y])
		if not parts.is_empty():
			print("off %s -> %s" % [off, " ".join(parts)])

func _baseline(grid: GridMap, cell: Vector3i, types: Dictionary) -> int:
	var type = types[grid.get_cell_item(cell)]
	var f = Iso.facing()
	var basis = grid.global_transform.basis
	var bits = 0
	for off in OcclusionContact._neighbor_offsets():
		var nid = grid.get_cell_item(cell + off)
		if nid == GridMap.INVALID_CELL_ITEM: continue
		var ntype = types.get(nid)
		if ntype == null: continue
		var world = basis * (Vector3(off) * grid.cell_size)
		var screen = Vector2(world.dot(f.x), -world.dot(f.y))
		if screen.length_squared() < 1e-6: continue
		for d in 6:
			if (type.present & (1 << d)) == 0: continue
			if (ntype.present & (1 << ((d + 3) % 6))) == 0: continue
			if screen.normalized().dot(type.out[d]) > ALIGN:
				bits |= 1 << d
	return bits

# Shader simulation: would the mask pixel p (region-local) be erased?
func _erased(type: Dictionary, neighbors: int, spans: Array, d: int, p: Vector2) -> bool:
	if (neighbors & (1 << d)) == 0: return false
	var e: Vector4 = type.edges[d]
	var a = Vector2(e.x, e.y)
	var ab = Vector2(e.z, e.w) - a
	var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(type.region_size) - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return t >= spans[d].x and t <= spans[d].y

func _diff_scene(grid: GridMap, types: Dictionary) -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var sheets = _raws(data)
	var full = Vector2(0, 1)
	var full_spans := []
	for i in 6: full_spans.append(full)

	var cells := []
	for c in grid.get_used_cells():
		if types.has(grid.get_cell_item(c)): cells.append(c)

	var diffs = 0
	var per_cell := {}
	for c in cells:
		var id = grid.get_cell_item(c)
		var type = types[id]
		var rect = Rect2i(Rect2(data.tiles[id].region[0], data.tiles[id].region[1], data.tiles[id].region[2], data.tiles[id].region[3]))
		var res = OcclusionContact.resolve(grid, c, types)
		var base = _baseline(grid, c, types)
		for d in 6:
			for p in type.region_px[d]:
				var px = sheets[data.tiles[id].get("sheet", 0)].get_pixelv(rect.position + Vector2i(p))
				if px.a < 0.5: continue
				var en = _erased(type, res.neighbors, res.spans, d, p)
				var eb = _erased(type, base, full_spans, d, p)
				if en != eb:
					diffs += 1
					var k = "%s %s" % [c, ["NW","NE","E","SE","SW","W"][d]]
					per_cell[k] = per_cell.get(k, 0) + (1 if en else -1)
	# The all-or-nothing baseline over-erases silhouette corners (a tile's edge
	# above a shorter/absent neighbour). The mesh-driven method correctly KEEPS
	# those (same fix as the tall-slab and frustum cases), so a few "erases
	# less" pixels are expected and good; only "erases MORE" (a silhouette the
	# baseline kept but we dropped) or a gross diff is a real regression.
	var erases_more = 0
	for k in per_cell:
		print("  DIFF %s: %+d px (positive = new erases more)" % [k, per_cell[k]])
		if per_cell[k] > 0: erases_more += per_cell[k]
	print("per-pixel diff vs baseline: %d px over %d cells (%d erase-more)" % [diffs, cells.size(), erases_more])
	if erases_more != 0 or diffs > 8: _fail += 1

	_composite(grid, types, cells, data, sheets)

func _raws(data: Dictionary) -> Array:
	return data.tilesheets.map(func(p):
		var img = Image.load_from_file(ProjectSettings.globalize_path(p))
		img.convert(Image.FORMAT_RGBA8)
		return img)

# Painter-ordered CPU render of the whole scene, baseline vs new, plus a diff
# overlay; saved to tools/ for visual inspection.
func _composite(grid: GridMap, types: Dictionary, cells: Array, data: Dictionary, sheets: Array) -> void:
	var f = Iso.facing()
	var basis = grid.global_transform.basis
	var lo = Vector2(INF, INF)
	var hi = -lo
	var items := []
	for c in cells:
		var id = grid.get_cell_item(c)
		var type = types[id]
		var world = basis * grid.map_to_local(c)
		var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
		var tl = screen - type.origin
		items.append({"cell": c, "id": id, "tl": tl, "depth": world.dot(-f.z)})
		lo = Vector2(minf(lo.x, tl.x), minf(lo.y, tl.y))
		hi = Vector2(maxf(hi.x, tl.x + type.region_size.x), maxf(hi.y, tl.y + type.region_size.y))
	items.sort_custom(func(a, b): return a.depth > b.depth)

	var size = Vector2i((hi - lo).ceil()) + Vector2i.ONE
	var img_base = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var img_new = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var full_spans := []
	for i in 6: full_spans.append(Vector2(0, 1))

	for it in items:
		var type = types[it.id]
		var rect = Rect2i(Rect2(data.tiles[it.id].region[0], data.tiles[it.id].region[1], data.tiles[it.id].region[2], data.tiles[it.id].region[3]))
		var res = OcclusionContact.resolve(grid, it.cell, types)
		var base = _baseline(grid, it.cell, types)
		var dir_of := {}
		for d in 6:
			for p in type.region_px[d]: dir_of[Vector2i(p)] = d
		for y in rect.size.y:
			for x in rect.size.x:
				var px = sheets[data.tiles[it.id].get("sheet", 0)].get_pixelv(rect.position + Vector2i(x, y))
				if px.a < 0.5: continue
				var at = Vector2i((it.tl - lo).round()) + Vector2i(x, y)
				var d = dir_of.get(Vector2i(x, y), -1)
				var opaque = Color(px.r, px.g, px.b, 1.0)
				if d < 0 or not _erased(type, base, full_spans, d, Vector2(x, y)):
					img_base.set_pixelv(at, opaque)
				if d < 0 or not _erased(type, res.neighbors, res.spans, d, Vector2(x, y)):
					img_new.set_pixelv(at, opaque)

	var img_diff = img_base.duplicate()
	var n = 0
	for y in size.y:
		for x in size.x:
			if img_base.get_pixel(x, y) != img_new.get_pixel(x, y):
				img_diff.set_pixel(x, y, Color(1, 0, 1))
				n += 1
	print("composite diff: %d px in %s" % [n, size])
	if n > 8: _fail += 1  # a few silhouette-corner pixels differ by design (see above)
	img_base.save_png("res://tools/diag_base.png")
	img_new.save_png("res://tools/diag_new.png")
	img_diff.save_png("res://tools/diag_diff.png")
