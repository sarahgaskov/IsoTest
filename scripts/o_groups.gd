@tool
extends RefCounted
class_name OccluderGroups

# Bakes placed cells into fade groups and shell flags. See docs/player_transparency.md.

# The camera looks straight down this diagonal, so `c + VIEW_STEP` is in front of `c`.
const VIEW_STEP = Vector3i(1, 1, 1)

const MAX_GROUPS = 4096  # gate texture width; overflow falls back to ungrouped
const MAX_ZONES = 256    # designer-drawn "occluder" boxes honoured per level

const FX = Vector3i(1, 0, 0)
const FZ = Vector3i(0, 0, 1)
const UP = Vector3i(0, 1, 0)

# True while the (1,1,1) view diagonal holds for the current Iso constants.
static func diagonal_is_exact() -> bool:
	var d := Iso.facing().z / Iso.cell()
	return absf(d.y / d.x - 1.0) < 1e-6 and absf(d.z / d.x - 1.0) < 1e-6

# Designer-drawn fade groups: any node in the "occluder" group with a BoxShape3D.
static func collect_zones(tree: SceneTree) -> Array:
	return InteriorZones.boxes(tree, &"occluder", MAX_ZONES)

# -> {group: {Vector3i: int}, shell: {Vector3i: bool}, count: int, lo, hi: Vector3i}
static func build(cells: Array, grid: GridMap = null, zones: Array = []) -> Dictionary:
	var filled := {}
	var parent := {}
	for c in cells:
		filled[c] = true
		parent[c] = c

	# A wall is the run of cells showing the same camera-facing vertical face.
	for c in cells:
		if not filled.has(c + FX):
			for n in [UP, FZ]:
				if filled.has(c + n) and not filled.has(c + n + FX):
					_union(parent, c, c + n)
		if not filled.has(c + FZ):
			for n in [UP, FX]:
				if filled.has(c + n) and not filled.has(c + n + FZ):
					_union(parent, c, c + n)

	# Corners bury both faces; (1,0,-1) is the only offset where both stay exposed.
	for c in cells:
		if filled.has(c + FX):
			continue
		var turn: Vector3i = c + Vector3i(1, 0, -1)
		if filled.has(turn) and not filled.has(turn + FZ):
			_union(parent, c, turn)

	# A faceless cell joins the wall it backs onto — one hop, so floors never chain.
	for c in cells:
		if not filled.has(c + FX) or not filled.has(c + FZ):
			continue
		for n in [FX, FZ, UP, -FX, -FZ, -UP]:
			var q: Vector3i = c + n
			if filled.has(q) and not (filled.has(q + FX) and filled.has(q + FZ)):
				_union(parent, c, q)
				break

	# Designer override, applied last and union-only: it can fuse, never split.
	if grid != null and not zones.is_empty():
		var anchor := {}
		for c in cells:
			var p: Vector3 = grid.to_global(grid.map_to_local(c))
			for i in zones.size():
				if not InteriorZones.contains(zones[i], p):
					continue
				if anchor.has(i):
					_union(parent, anchor[i], c)
				else:
					anchor[i] = c

	var ids := {}
	var group := {}
	for c in cells:
		var root = _find(parent, c)
		if not ids.has(root):
			if ids.size() >= MAX_GROUPS:
				group[c] = -1
				continue
			ids[root] = ids.size()
		group[c] = ids[root]

	# Shell = nothing of this cell's own group stands in front of it.
	var shell := {}
	for c in cells:
		var g: int = group[c]
		shell[c] = g < 0 or group.get(c + VIEW_STEP, -1) != g

	var lo: Vector3i = cells[0] if not cells.is_empty() else Vector3i.ZERO
	var hi := lo
	for c in cells:
		lo = lo.min(c)
		hi = hi.max(c)

	return {"group": group, "shell": shell, "count": ids.size(), "lo": lo, "hi": hi}

static func _find(parent: Dictionary, c: Vector3i) -> Vector3i:
	var root: Vector3i = c
	while parent[root] != root:
		root = parent[root]
	while parent[c] != root:  # path compression
		var next: Vector3i = parent[c]
		parent[c] = root
		c = next
	return root

static func _union(parent: Dictionary, a: Vector3i, b: Vector3i) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra
