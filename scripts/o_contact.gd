@tool
extends RefCounted
class_name OcclusionContact

# Where a cell touches its neighbors, per edge. See docs/outline_occlusion.md.

const SLOP_PX = 6.0     # px of outward probing for the neighbor's surface
const DEPTH_TOL = 1.23  # world-unit slack for "surfaces touch"
const GAP = 0.42        # merge contact runs separated by less than this
const MIN_SPAN = 0.51   # a run must outlast a corner-touch halo to be contact
const CORNER_EPS = 0.05 # tolerance for corner-pixel jitter at an edge end

const ID_BITS = 10  # tile ids per memo key; 1024 tiles per config

# The 26 surrounding cell offsets (3x3x3 minus the center), built once.
static var _offsets: Array = []
static var _cache := {}

static func clear() -> void:
	_cache.clear()

# -> {neighbors: int (6-bit edge mask), spans: Array[Vector2] ([t0,t1] per edge)}.
static func resolve(grid: GridMap, cell: Vector3i, types: Dictionary) -> Dictionary:
	if _offsets.is_empty(): _offsets = _neighbor_offsets()
	var id = grid.get_cell_item(cell)
	var type = types[id]
	var spans = _zero_spans()
	var neighbors = 0
	var runs := []
	for d in 6: runs.append([])

	for off in _offsets:
		var nid = grid.get_cell_item(cell + off)
		if nid == GridMap.INVALID_CELL_ITEM: continue
		var ntype = types.get(nid)
		if ntype == null: continue
		var contact = _contact(grid, id, nid, type, ntype, off)
		for d in 6:
			runs[d].append_array(contact[d])

	for d in 6:
		var span = _merge(runs[d])
		if span != null:
			spans[d] = span
			neighbors |= 1 << d

	return {"neighbors": neighbors, "spans": spans}

# Longest union of overlapping runs along one edge; null below a corner halo.
static func _merge(runs: Array) -> Variant:
	if runs.is_empty(): return null
	runs.sort_custom(func(a, b): return a.x < b.x)

	var best = null
	var cur: Vector2 = runs[0]
	for i in range(1, runs.size() + 1):
		if i < runs.size() and runs[i].x <= cur.y + GAP:
			cur.y = maxf(cur.y, runs[i].y)
			continue
		if best == null or cur.y - cur.x > best.y - best.x:
			best = cur
		if i < runs.size(): cur = runs[i]
	return best if best.y - best.x >= MIN_SPAN else null

# Contact runs of one type pair at one offset; memoized until the next rebuild.
static func _contact(grid: GridMap, a_id: int, b_id: int, a: Dictionary, b: Dictionary, off: Vector3i) -> Array:
	var key = a_id | (b_id << ID_BITS) | ((off.x + 1) << 20) | ((off.y + 1) << 22) | ((off.z + 1) << 24)
	if _cache.has(key):
		return _cache[key]

	var f = Iso.facing()
	var runs := []
	for d in 6: runs.append([])

	# Cells are shorter than UNIT, so vertical offsets get both placements.
	var worlds = [Vector3(off) * grid.cell_size]
	if off.y != 0:
		worlds.append(Vector3(off) * Vector3(grid.cell_size.x, Iso.UNIT, grid.cell_size.z))

	# An identical tile at its own ramp_chain offset is a designed seamless join.
	var chain = a.get("ramp_chain")
	var ramp_bridge = a_id == b_id and chain != null and (off == chain or off == -chain)

	for w in worlds:
		var world = grid.global_transform.basis * w
		var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
		var shift = world.dot(-f.z)
		for d in 6:
			runs[d].append_array(_span(a, b, d, screen, shift, off, ramp_bridge))
	_cache[key] = runs
	return runs

# Contact spans along edge d of a, against b `screen` px away and `shift` deeper.
static func _span(a: Dictionary, b: Dictionary, d: int, screen: Vector2, shift: float, off: Vector3i, ramp_bridge: bool) -> Array:
	if (a.present & (1 << d)) == 0:
		return []

	var out: Vector2 = a.out[d]
	var probes: PackedFloat32Array = a.probes[d]
	var to_b: Vector2 = b.origin - a.origin - screen

	var hits := []
	var keep_lo := INF
	var keep_hi := -INF

	for i in range(0, probes.size(), 5):
		var t_lo = probes[i]
		var t_hi = probes[i + 1]
		var from = Vector2(probes[i + 2], probes[i + 3]) + to_b + out
		var sb = MeshDepth.first_covered(b.depth, b.region_size, from, out, SLOP_PX - 1)
		var contact := false
		if sb != null:
			var nb = MeshDepth.at(b.depth, b.region_size, sb)
			var wa = probes[i + 4]
			contact = ramp_bridge \
				or absf(wa - (nb.x + shift)) <= DEPTH_TOL \
				or absf(wa - (nb.y + shift)) <= DEPTH_TOL
		if contact:
			hits.append(Vector2(t_lo, t_hi))
		else:
			keep_lo = minf(keep_lo, t_lo)
			keep_hi = maxf(keep_hi, t_hi)

	if hits.is_empty():
		return []
	hits.sort_custom(func(x, y): return x.x < y.x)

	# TODO: runs currently bridge across keep probes; see docs/outline_occlusion.md.
	var runs := []
	var cur: Vector2 = hits[0]
	for i in range(1, hits.size()):
		if hits[i].x <= cur.y + GAP:
			cur.y = maxf(cur.y, hits[i].y)
		else:
			runs.append(cur)
			cur = hits[i]
	runs.append(cur)

	var out_runs := []
	for idx in runs.size():
		var r: Vector2 = runs[idx]
		if r.y - r.x < MIN_SPAN:
			continue
		var lo = 0.0 if idx == 0 and keep_lo >= r.x - CORNER_EPS else r.x
		var hi = 1.0 if idx == runs.size() - 1 and keep_hi <= r.y + CORNER_EPS else r.y
		# The W edge against a SW neighbor needs one extra pixel of outline.
		if d == 5 and off.x == 0 and off.z == 1 and lo > 0.0:
			lo = minf(lo + 0.04, hi)
		out_runs.append(Vector2(lo, hi))
	return out_runs

static func _zero_spans() -> Array:
	var out := []
	for i in 6: out.append(Vector2.ZERO)
	return out

static func _neighbor_offsets() -> Array:
	var out := []
	for x in [-1, 0, 1]:
		for y in [-1, 0, 1]:
			for z in [-1, 0, 1]:
				if x != 0 or y != 0 or z != 0:
					out.append(Vector3i(x, y, z))
	return out
