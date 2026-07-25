extends SceneTree

# Headless verifier for the keyhole occlusion gate (docs/player_transparency.md).
#   godot --headless --path <project> --script res://tools/keyhole_diag.gd
#
# Sweeps the player across the level, and for each stop reports which fade
# groups the diagonal walk finds, how much of the body they cover, and how the
# gate settles. Also checks the invariants the gate depends on.

const SETTLE_FRAMES = 90

var lvl: Level
var grid: IsoGrid
var plr: Node3D
var fails := 0

func _init() -> void:
	var scn = load("res://scenes/level.tscn").instantiate()
	root.add_child(scn)
	await process_frame
	lvl = scn
	grid = scn.get_node("GridMap")
	plr = scn.get_node("Player")

	_check_invariants()
	_report_groups()
	_check_synthetic()
	_check_occluder_zone()
	await _sweep()

	print("\nRESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)

func _expect(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("  FAIL: ", what)

func _check_invariants() -> void:
	print("== invariants ==")
	var d := Iso.facing().z / Iso.cell()
	print("view dir in grid space: ", d / d.x)
	_expect(OccluderGroups.diagonal_is_exact(),
		"view diagonal is not (1,1,1) — the walk needs a general DDA")

	# A cell and cell+(1,1,1) must land on the same screen pixel.
	var cam := root.get_camera_3d()
	var a := cam.unproject_position(grid.to_global(grid.map_to_local(Vector3i(0, 0, 0))))
	var b := cam.unproject_position(grid.to_global(grid.map_to_local(OccluderGroups.VIEW_STEP)))
	print("screen drift over one diagonal step: ", a.distance_to(b))
	_expect(a.distance_to(b) < 0.01, "a diagonal step moved the cell on screen")

func _report_groups() -> void:
	print("\n== grouping ==")
	var cells := grid.get_used_cells()
	var sizes := {}
	var shell_of := {}
	for c in cells:
		var g := grid.cell_group(c)
		sizes[g] = sizes.get(g, 0) + 1
	print("cells=%d groups=%d ungrouped=%d" % [cells.size(), grid.group_count(), sizes.get(-1, 0)])

	# Shell check: a cell is interior exactly when its own group sits in front.
	var interior := []
	for c in cells:
		var g := grid.cell_group(c)
		var front := grid.cell_group(c + OccluderGroups.VIEW_STEP)
		if not (g < 0 or front != g):
			interior.append(c)
	print("interior (non-shell) cells: %d %s" % [interior.size(), interior])

	var hist: Array = sizes.values()
	hist.sort()
	print("group sizes: ", hist)

# The shipped level happens to have no group that is more than one cell deep
# along the view diagonal, so exercise the grouping rules on layouts that are.
func _check_synthetic() -> void:
	print("\n== synthetic layouts ==")

	# A flat wall plane: one group, every cell a shell cell.
	var flat := []
	for y in 3:
		for z in 4:
			flat.append(Vector3i(0, y, z))
	var r := OccluderGroups.build(flat)
	print("flat wall     count=%d interior=%d" % [r.count, _interior(r)])
	_expect(r.count == 1, "a flat wall plane should be exactly one group")
	_expect(_interior(r) == 0, "a flat wall plane should have no interior cells")

	# An L-corner: two planes fused into one group by the shared corner cell.
	var corner := []
	for y in 3:
		for z in range(1, 4):
			corner.append(Vector3i(0, y, z))
		for x in 4:
			corner.append(Vector3i(x, y, 0))
	r = OccluderGroups.build(corner)
	print("L-corner      count=%d interior=%d" % [r.count, _interior(r)])
	_expect(r.count == 1, "an L-corner should fuse into a single group")

	# An alcove return: a cell tucked one diagonal step behind its own group,
	# which is exactly the case tile_shell exists for.
	var nook := []
	for y in 2:
		for z in 3:
			nook.append(Vector3i(0, y, z))
	nook.append(Vector3i(1, 1, 1))
	r = OccluderGroups.build(nook)
	var g0: int = r.group[Vector3i(0, 0, 0)]
	var g1: int = r.group[Vector3i(1, 1, 1)]
	print("alcove return count=%d interior=%d  g(0,0,0)=%d g(1,1,1)=%d shell(0,0,0)=%s"
		% [r.count, _interior(r), g0, g1, r.shell[Vector3i(0, 0, 0)]])
	_expect(g0 == g1, "the return should join the wall it belongs to")
	_expect(not r.shell[Vector3i(0, 0, 0)], "the hidden cell should be interior")
	_expect(r.shell[Vector3i(1, 1, 1)], "the front cell should stay shell")

# The designer override: an "occluder" box fuses everything inside it.
func _check_occluder_zone() -> void:
	print("\n== occluder zone override ==")
	var before := grid.group_count()

	var area := Area3D.new()
	area.add_to_group(&"occluder")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 4096.0
	cs.shape = box
	area.add_child(cs)
	lvl.add_child(area)

	grid._refresh_sprites()
	var after := grid.group_count()
	print("  groups: %d without a box, %d with one box over the whole level" % [before, after])
	_expect(after == 1, "a box covering the level should fuse it into one group")

	# Every cell is in one group now, so everything but the frontmost cell of
	# each screen column must read as interior.
	var interior := 0
	for c in grid.get_used_cells():
		if grid.cell_group(c + OccluderGroups.VIEW_STEP) == grid.cell_group(c):
			interior += 1
	print("  interior cells under one fused group: ", interior)

	area.free()
	grid._refresh_sprites()
	_expect(grid.group_count() == before, "removing the box should restore the grouping")
	lvl.refresh()

func _interior(r: Dictionary) -> int:
	var n := 0
	for c in r.shell:
		if not r.shell[c]:
			n += 1
	return n

# Ground truth: every placed cell that really covers the body and reaches past it
# toward the camera. O(cells), far too slow for _process, but exact — so the
# walk's cheap column enumeration can be checked against it.
func _oracle(camera: Camera3D, foot: Vector3, height: float) -> Dictionary:
	var samples := lvl._body_samples(camera, foot, height)
	var view := Iso.facing().z
	var floor_depth := foot.dot(view)
	var out := {}
	for c in grid.get_used_cells():
		var g := grid.cell_group(c)
		if g < 0: continue
		var type = grid.cell_type(c)
		if type == null: continue
		var center: Vector3 = grid.to_global(grid.map_to_local(c))
		if (center + type.near_offset).dot(view) <= floor_depth: continue
		var cover: float = lvl._coverage(type, camera.unproject_position(center), samples)
		if cover > 0.0 and cover > float(out.get(g, 0.0)):
			out[g] = cover
	return out

func _fmt(hits: Dictionary) -> String:
	var keys: Array = hits.keys()
	keys.sort()
	var parts := []
	for g in keys:
		parts.append("g%d=%.2f" % [g, hits[g]])
	return ", ".join(parts) if parts else "none"

func _sweep() -> void:
	print("\n== sweep: walk vs brute-force oracle ==")
	print("  (the walk must find every group the oracle does, at the same coverage)")
	var spots := []
	# A dense lattice around the built-up part of the map, so the enumeration is
	# exercised from every side of every wall — the NE approach included.
	for x in range(-7, 3):
		for z in range(-5, 3):
			spots.append(Vector3(x * 24.0, 40.0, z * 24.0))

	var checked := 0
	var mismatched := 0
	var worst := ""
	for spot in spots:
		plr.global_position = spot
		plr.velocity = Vector3.ZERO
		for i in 6:
			await process_frame
		var cam := root.get_camera_3d()
		var foot: Vector3 = plr.global_position
		var height: float = lvl.keyhole_body_layers * Iso.cell().y
		var walk := {}
		lvl._gather_occluders(cam, foot, height, walk)
		var truth := _oracle(cam, foot, height)
		checked += 1
		var bad := false
		for g in truth:
			if not walk.has(g) or absf(float(walk[g]) - float(truth[g])) > 0.001:
				bad = true
		if bad:
			mismatched += 1
			if worst == "":
				worst = "  at %s\n    walk:   %s\n    oracle: %s" % [
					str(spot), _fmt(walk), _fmt(truth)]

	print("  positions checked: %d   mismatched: %d" % [checked, mismatched])
	if worst != "":
		print(worst)
	_expect(mismatched == 0,
		"the column walk missed occluders the oracle found at %d/%d positions" %
		[mismatched, checked])

	# Fade timing: from a clean state, the gate must ramp, not snap.
	print("\n== fade-in ramp (must rise gradually) ==")
	lvl.refresh()
	plr.global_position = Vector3(-120, 40, -72)
	plr.velocity = Vector3.ZERO
	var trace := []
	for i in 24:
		await process_frame
		var peak := 0.0
		for v in lvl._gate:
			peak = maxf(peak, v)
		if i % 4 == 0:
			trace.append("%.2f" % peak)
	print("  peak gate over 24 frames: ", " -> ".join(trace))

	# The shader applies the gate as mix(1.0, faded_alpha, gate), so a gate in
	# [0,1] can only ever make a tile *more* opaque than the ungated rules.
	# Guard the precondition; the algebra does the rest.
	var bad := 0
	for v in lvl._gate:
		if v < 0.0 or v > 1.0:
			bad += 1
	_expect(bad == 0, "%d gate values escaped [0,1] — the gate would stop being subtractive" % bad)
