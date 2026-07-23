extends SceneTree

# Focused repro: a tall slab_5 with a short slab_2 at each of the 4 diagonal
# neighbours (NW/NE/SE/SW cell offsets), isolated one at a time, to find which
# offset causes the taller slab's E/W vertical edge to erase more than it
# should (cutting the visible outline short before it reaches the shorter
# neighbour's top surface).

const NAMES = ["NW", "NE", "E ", "SE", "SW", "W "]

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var id := {}
	for i in data.tiles.size(): id[data.tiles[i].name] = i

	var offsets = {
		"NW": Vector3i(-1, 0, 0), "NE": Vector3i(0, 0, -1),
		"SE": Vector3i(1, 0, 0), "SW": Vector3i(0, 0, 1),
	}
	for key in offsets:
		var grid = IsoGrid.new()
		var lib = MeshLibrary.new()
		for i in data.tiles.size(): lib.create_item(i)
		grid.mesh_library = lib
		root.add_child(grid)
		grid.set_cell_item(Vector3i(5, 0, 5), id.slab_5)
		grid.set_cell_item(Vector3i(5, 0, 5) + offsets[key], id.slab_2)
		grid._refresh_sprites()
		var types: Dictionary = grid._types

		var res = OcclusionContact.resolve(grid, Vector3i(5, 0, 5), types)
		var parts := []
		for d in 6:
			if (res.neighbors & (1 << d)) != 0:
				parts.append("%s=[%.2f,%.2f]" % [NAMES[d], res.spans[d].x, res.spans[d].y])
			else:
				parts.append("%s=NONE" % NAMES[d])
		print("neighbour at %s (%s): %s" % [key, offsets[key], " ".join(parts)])
		_dump(grid, types, Vector3i(5, 0, 5))
		_render(data, grid, types, "r4_%s" % key)
		grid.queue_free()
		root.remove_child(grid)
	quit()

func _dump(grid: GridMap, types: Dictionary, cell: Vector3i) -> void:
	var a: Dictionary = types[grid.get_cell_item(cell)]
	var f = Iso.facing()
	for off in OcclusionContact._neighbor_offsets():
		var nid = grid.get_cell_item(cell + off)
		if nid == GridMap.INVALID_CELL_ITEM: continue
		var b: Dictionary = types[nid]
		var world = grid.global_transform.basis * (Vector3(off) * grid.cell_size)
		var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
		var shift = world.dot(-f.z)
		for d in [2, 5]:  # E, W only
			var out: Vector2 = a.out[d]
			if screen.length_squared() > 1e-6 and screen.normalized().dot(out) <= 0.05: continue
			var to_b: Vector2 = b.origin - a.origin - screen
			var probes: PackedFloat32Array = a.probes[d]
			var lines := []
			for i in range(0, probes.size(), 5):
				var from = Vector2(probes[i + 2], probes[i + 3]) + to_b + out
				var sb = MeshDepth.first_covered(b.depth, b.region_size, from, out, OcclusionContact.SLOP_PX - 1)
				var t_lo = probes[i]; var t_hi = probes[i + 1]; var wa = probes[i + 4]
				if sb == null:
					lines.append("t=[%.2f,%.2f] EXPOSED" % [t_lo, t_hi])
				else:
					var nb = MeshDepth.at(b.depth, b.region_size, sb)
					var tol = OcclusionContact.DEPTH_TOL
					var stat = "CONTACT" if (absf(wa - (nb.x + shift)) <= tol or absf(wa - (nb.y + shift)) <= tol) else "DEPTHFAIL"
					lines.append("t=[%.2f,%.2f] wa=%.2f nbF=%.2f nbB=%.2f shift=%.2f %s" % [t_lo, t_hi, wa, nb.x, nb.y, shift, stat])
			if not lines.is_empty():
				print("  %s off %s (%s):" % [NAMES[d], off, grid.get_cell_item(cell + off)])
				for l in lines: print("    ", l)

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
	print("  -> tools/%s.png %s" % [name, size])

func _erased(type: Dictionary, res: Dictionary, d: int, p: Vector2) -> bool:
	if (res.neighbors & (1 << d)) == 0: return false
	var e: Vector4 = type.edges[d]
	var a = Vector2(e.x, e.y)
	var ab = Vector2(e.z, e.w) - a
	var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(type.region_size) - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return t >= res.spans[d].x and t <= res.spans[d].y
