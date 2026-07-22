extends SceneTree

# Issue 2: a frustum — slab_5 flat top (1,0,1) ringed by slopes/corner_slopes
# rising toward it, so the BACK slopes (NW/NE) are hidden behind the body and
# the top's back edges are the real silhouette. Renders x6 and dumps slab_5's
# NW/NE edge: per-neighbour, what the back slope presents. SW=+Z SE=+X NW=-X NE=-Z.

const NAMES = ["NW", "NE", "E", "SE", "SW", "W"]

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var grid = IsoGrid.new()
	var lib = MeshLibrary.new()
	for i in data.tiles.size(): lib.create_item(i)
	grid.mesh_library = lib
	root.add_child(grid)
	var id := {}
	for i in data.tiles.size(): id[data.tiles[i].name] = i

	# issue 1: tall slab_5 flanked by shorter slabs — a separate island
	grid.set_cell_item(Vector3i(8, 0, 8), id.slab_5)
	grid.set_cell_item(Vector3i(8, 0, 9), id.slab_4)   # SW
	grid.set_cell_item(Vector3i(9, 0, 8), id.slab_3)   # SE

	grid.set_cell_item(Vector3i(1, 0, 1), id.slab_5)
	grid.set_cell_item(Vector3i(1, 0, 0), id.slope_s)   # -Z back edge, high toward +Z
	grid.set_cell_item(Vector3i(1, 0, 2), id.slope_n)   # +Z front edge
	grid.set_cell_item(Vector3i(0, 0, 1), id.slope_e)   # -X left edge
	grid.set_cell_item(Vector3i(2, 0, 1), id.slope_w)   # +X right edge
	grid.set_cell_item(Vector3i(0, 0, 0), id.corner_slope_s)
	grid.set_cell_item(Vector3i(2, 0, 0), id.corner_slope_w)
	grid.set_cell_item(Vector3i(0, 0, 2), id.corner_slope_e)
	grid.set_cell_item(Vector3i(2, 0, 2), id.corner_slope_n)
	grid._refresh_sprites()
	var types: Dictionary = grid._types

	var probe = Vector3i(1, 0, 1)
	var res = OcclusionContact.resolve(grid, probe, types)
	var parts := []
	for d in 6:
		if (res.neighbors & (1 << d)) != 0:
			parts.append("%s=[%.2f,%.2f]" % [NAMES[d], res.spans[d].x, res.spans[d].y])
	print("frustum slab_5 spans: ", " ".join(parts))

	var res1 = OcclusionContact.resolve(grid, Vector3i(8, 0, 8), types)
	var p1 := []
	for d in 6:
		if (res1.neighbors & (1 << d)) != 0:
			p1.append("%s=[%.2f,%.2f]" % [NAMES[d], res1.spans[d].x, res1.spans[d].y])
	print("issue1 slab_5 spans: ", " ".join(p1))

	_render(data, grid, types, "i2")
	quit()

func _dump(grid: GridMap, types: Dictionary, cell: Vector3i, d: int) -> void:
	var a: Dictionary = types[grid.get_cell_item(cell)]
	var f = Iso.facing()
	for off in OcclusionContact._neighbor_offsets():
		var nid = grid.get_cell_item(cell + off)
		if nid == GridMap.INVALID_CELL_ITEM: continue
		var b: Dictionary = types[nid]
		var world = grid.global_transform.basis * (Vector3(off) * grid.cell_size)
		var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
		var shift = world.dot(-f.z)
		var out: Vector2 = a.out[d]
		if screen.length_squared() < 1e-6 or screen.normalized().dot(out) <= 0.05: continue
		var to_b: Vector2 = b.origin - a.origin - screen
		var probes: PackedFloat32Array = a.probes[d]
		var con := 0; var exp := 0; var df := 0
		var samples := []
		for i in range(0, probes.size(), 5):
			var from = Vector2(probes[i + 2], probes[i + 3]) + to_b + out
			var sb = MeshDepth.first_covered(b.depth, b.region_size, from, out, OcclusionContact.SLOP_PX - 1)
			if sb == null: exp += 1; continue
			var nb = MeshDepth.at(b.depth, b.region_size, sb)
			var wa = probes[i + 4]
			var tol = OcclusionContact.DEPTH_TOL
			if absf(wa - (nb.x + shift)) <= tol or absf(wa - (nb.y + shift)) <= tol:
				con += 1
				if samples.size() < 3: samples.append("wa=%.1f nbF=%.1f nbB=%.1f shift=%.1f" % [wa, nb.x, nb.y, shift])
			else: df += 1
		print("  %s off %s (%s): contact=%d exposed=%d depthfail=%d  %s" % [
			NAMES[d], off, grid.get_cell_item(cell + off), con, exp, df, samples])

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
	img.resize(size.x * 6, size.y * 6, Image.INTERPOLATE_NEAREST)
	img.save_png("res://tools/%s.png" % name)
	print("  -> tools/%s.png %s" % [name, size])

func _erased(type: Dictionary, res: Dictionary, d: int, p: Vector2) -> bool:
	if (res.neighbors & (1 << d)) == 0: return false
	var e: Vector4 = type.edges[d]
	var a = Vector2(e.x, e.y)
	var ab = Vector2(e.z, e.w) - a
	var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(type.region_size) - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return t >= res.spans[d].x and t <= res.spans[d].y
