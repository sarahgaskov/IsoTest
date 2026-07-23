extends SceneTree

# Diagnose why the outline between a stairs tile and a neighboring slope tile
# in the real scenes/level.tscn only shows for the bottom couple of steps
# instead of the whole boundary.

const NAMES = ["NW", "NE", "E ", "SE", "SW", "W "]

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var names := []
	for i in data.tiles.size(): names.append(data.tiles[i].name)

	var scene: PackedScene = load("res://scenes/level.tscn")
	var inst: Node = scene.instantiate()
	root.add_child(inst)
	var grid: GridMap = inst.get_node("GridMap")
	grid._refresh_sprites()
	var types: Dictionary = grid._types

	for c in grid.get_used_cells():
		var id = grid.get_cell_item(c)
		print("cell %s -> id=%d name=%s orient=%d" % [c, id, names[id], grid.get_cell_item_orientation(c)])

	print("")
	for c in grid.get_used_cells():
		var id = grid.get_cell_item(c)
		var res = OcclusionContact.resolve(grid, c, types)
		var parts := []
		for d in 6:
			if (res.neighbors & (1 << d)) != 0:
				parts.append("%s=[%.2f,%.2f]" % [NAMES[d], res.spans[d].x, res.spans[d].y])
			else:
				parts.append("%s=NONE" % NAMES[d])
		print("cell %s (%s): %s" % [c, names[id], " ".join(parts)])
		_dump(grid, types, c, names)

	quit()

func _dump(grid: GridMap, types: Dictionary, cell: Vector3i, names: Array) -> void:
	var a: Dictionary = types[grid.get_cell_item(cell)]
	var f = Iso.facing()
	for off in OcclusionContact._neighbor_offsets():
		var nid = grid.get_cell_item(cell + off)
		if nid == GridMap.INVALID_CELL_ITEM: continue
		var b: Dictionary = types[nid]
		var world = grid.global_transform.basis * (Vector3(off) * grid.cell_size)
		var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
		var shift = world.dot(-f.z)
		for d in 6:
			var out: Vector2 = a.out[d]
			if screen.length_squared() > 1e-6 and screen.normalized().dot(out) <= 0.05: continue
			var to_b: Vector2 = b.origin - a.origin - screen
			var probes: PackedFloat32Array = a.probes[d]
			if probes.is_empty(): continue
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
				print("  edge %s off %s (nb=%s):" % [NAMES[d], off, names[nid]])
				for l in lines: print("    ", l)
