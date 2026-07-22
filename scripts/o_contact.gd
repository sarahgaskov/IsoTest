@tool
extends RefCounted
class_name OcclusionContact

# Detects where a placed cell touches its neighbors, per silhouette edge, as a
# [t0,t1] contact span along that edge. The criterion is depth contact vs.
# exposure: an outline pixel is erased where a neighbor's surface touches it in
# 3D (any orientation — a wall base on a floor erases like a coplanar merge),
# and kept where its outward side is exposed — empty, or a surface far enough
# behind to read as a real step. The mesh decides how far contact runs along an
# edge; the mask decides which pixels are ever eligible. Pure geometry over the
# grid's cell data + baked tile types — no rendering, no state beyond the memo.

const SLOP_PX = 4       # px leeway between the mesh silhouette and the painted art
const DEPTH_TOL = 2.5   # world-unit slack for "surfaces touch"
const SNAP = 0.1        # spans this close to an edge end reach it exactly
const GAP_PX = 4        # merge contact runs separated by less than this
const MIN_SPAN_PX = 10  # a run must outlast a corner-touch halo to be contact

# The 26 surrounding cell offsets (3x3x3 minus the center), built once.
static var _offsets: Array = []
static var _cache := {}

static func clear() -> void:
	_cache.clear()

# -> {neighbors: int (6-bit edge mask), spans: Array[Vector2] ([t0,t1] per edge)}.
# Several neighbors can each touch part of the same edge; overlapping runs are
# unioned, and what remains must be longer than the halo a mere corner touch
# leaves around a vertex — a stub that short is a corner meeting, not contact.
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
			if contact[d] != null: runs[d].append(contact[d])

	for d in 6:
		var span = _merge(runs[d], type.edges[d], Vector2(type.region_size))
		if span != null:
			spans[d] = span
			neighbors |= 1 << d

	return {"neighbors": neighbors, "spans": spans}

# Union of overlapping/near-touching runs along one edge, keeping the longest;
# null when even that is shorter than a corner halo. Tolerances are physical
# (pixels), so convert them through the edge's on-screen length.
static func _merge(runs: Array, edge: Vector4, size: Vector2) -> Variant:
	if runs.is_empty(): return null
	var len_px = ((Vector2(edge.z, edge.w) - Vector2(edge.x, edge.y)) * size).length()
	if len_px < 1.0: return null
	runs.sort_custom(func(a, b): return a.x < b.x)

	var best = null
	var cur: Vector2 = runs[0]
	for i in range(1, runs.size() + 1):
		if i < runs.size() and runs[i].x <= cur.y + GAP_PX / len_px:
			cur.y = maxf(cur.y, runs[i].y)
			continue
		if best == null or cur.y - cur.x > best.y - best.x:
			best = cur
		if i < runs.size(): cur = runs[i]
	return best if (best.y - best.x) * len_px >= MIN_SPAN_PX else null

# Per-direction contact of one type pair at one cell offset. Depends only on
# the two types and the offset, so memoized until the next rebuild.
static func _contact(grid: GridMap, a_id: int, b_id: int, a: Dictionary, b: Dictionary, off: Vector3i) -> Array:
	var key = [a_id, b_id, off]
	if _cache.has(key): return _cache[key]

	var f = Iso.facing()
	var world = grid.global_transform.basis * (Vector3(off) * grid.cell_size)
	var screen = Vector2(world.dot(f.x), -world.dot(f.y)) / Iso.PIXEL_SCALE
	var shift = world.dot(-f.z)
	var spans := []
	for d in 6:
		spans.append(_span(a, b, d, screen, shift))
	_cache[key] = spans
	return spans

# Contact span along edge d of a, against b sitting `screen` pixels away and
# `shift` world units deeper. Every wedge pixel is walked inward to a's own
# silhouette, b's solid is sampled there, and the pixel counts as contact when
# a's surface depth is within DEPTH_TOL of b's front OR back surface.
static func _span(a: Dictionary, b: Dictionary, d: int, screen: Vector2, shift: float) -> Variant:
	if (a.present & (1 << d)) == 0: return null
	var out: Vector2 = a.out[d]
	if screen.length_squared() < 1e-6 or screen.normalized().dot(out) <= 0.0:
		return null  # an edge can only be hidden by a neighbor on its outward side

	var e: Vector4 = a.edges[d]
	var e0 = Vector2(e.x, e.y)
	var ev = Vector2(e.z, e.w) - e0
	if ev.length_squared() < 1e-6: return null

	var size: Vector2i = a.region_size
	var to_b: Vector2 = b.origin - a.origin - screen
	var lo = INF
	var hi = -INF
	for p in a.region_px[d]:
		var s = MeshDepth.first_covered(a.depth, size, p + Vector2(0.5, 0.5), -out, MeshDepth.MAX_WALK)
		if s == null: continue
		var sb = MeshDepth.first_covered(b.depth, b.region_size, s + to_b, out, SLOP_PX)
		if sb == null: continue  # outward side is exposed: keep the ink
		var wa = MeshDepth.at(a.depth, size, s).x
		var nb = MeshDepth.at(b.depth, b.region_size, sb)
		if absf(wa - (nb.x + shift)) > DEPTH_TOL and absf(wa - (nb.y + shift)) > DEPTH_TOL:
			continue
		var t = clampf(((p + Vector2(0.5, 0.5)) / Vector2(size) - e0).dot(ev) / ev.length_squared(), 0.0, 1.0)
		lo = minf(lo, t)
		hi = maxf(hi, t)

	if lo > hi: return null
	return Vector2(0.0 if lo < SNAP else lo, 1.0 if hi > 1.0 - SNAP else hi)

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
