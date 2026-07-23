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

const SLOP_PX = 6.0      # px of outward probing for the neighbor's surface
const DEPTH_TOL = 1.23  # world-unit slack for "surfaces touch" — kept tight, so a
					   # neighbor whose surface recedes below this tile's (a slope
					   # dropping away behind a flat top) reads as a real edge, not
					   # a continuing plane, and keeps its silhouette outline

const GAP = 0.42       # merge contact runs separated by less than this
const MIN_SPAN = 0.51   # a run must outlast a corner-touch halo to be contact

# The very first/last probe of an edge sits exactly at a silhouette VERTEX
# (shared with the adjacent edge), where the outward search can miss the
# neighbour's coverage by a single rasterized pixel even when every other
# probe along the same edge matches perfectly (e.g. two identical cubes in a
# straight row: 25 of 26 probes read as tight CONTACT, but the very last one —
# the bottom corner pixel — reads EXPOSED, blocking the bridge to 1.0 and
# leaving a ~1%-of-edge sliver of outline behind at every such junction). This
# is corner-pixel jitter, not real silhouette, so the edge-end bridge below
# tolerates a keep-probe within CORNER_EPS of the contact zone's own end
# instead of requiring an exact match. Kept much smaller than any genuine
# exposure region seen in this pipeline (all comfortably >0.15 wide).
const CORNER_EPS = 0.05

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
			runs[d].append_array(contact[d])

	for d in 6:
		var span = _merge(runs[d])
		if span != null:
			spans[d] = span
			neighbors |= 1 << d

	return {"neighbors": neighbors, "spans": spans}

# Union of overlapping/near-touching runs along one edge, keeping the longest;
# null when even that is shorter than a corner halo.
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

# Per-direction contact runs of one type pair at one cell offset. Tiles are
# UNIT tall but cells are shorter, so layers overlap by the difference; a
# surface continuing across a layer boundary sits exactly that far off. For
# vertical offsets the pair is therefore evaluated at both the true placement
# and the overlap-corrected one. Depends only on the two types and the offset,
# so memoized until the next rebuild.
static func _contact(grid: GridMap, a_id: int, b_id: int, a: Dictionary, b: Dictionary, off: Vector3i) -> Array:
	var key = [a_id, b_id, off]
	if _cache.has(key):
		return _cache[key]
		
	var f = Iso.facing()
	var runs := []
	for d in 6:
		runs.append([])

	var worlds = [Vector3(off) * grid.cell_size]
	if off.y != 0:
		worlds.append(Vector3(off) * Vector3(grid.cell_size.x, Iso.UNIT, grid.cell_size.z))

	# A straight stairs/slope tile continuing into an identical one placed at
	# its own baked ramp_chain offset is a designed seamless join, not a
	# coincidental depth match — the per-step tread/riser jaggedness would
	# otherwise fail DEPTH_TOL almost everywhere along the edge (steps aren't
	# locally planar), leaving the whole seam outlined. See docs/occlusion.md.
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

# Contact span(s) along edge d of a, against b sitting `screen` pixels away and
# `shift` world units deeper. Each probe is a silhouette point of the edge with
# the [t_lo,t_hi] range of mask pixels that walk to it: the outward side must be
# covered by b (a surface merely ending at the line leaves the outline exposed),
# and it contacts when a's surface depth matches b's front OR back surface,
# within what the probe distance can explain by surface slope. A contacting
# probe erases its whole t range.
#
# Contact and keep (exposed/depth-mismatch) probes can interleave along one
# edge — e.g. a staircase against a smoothly-sloped neighbor, where each
# tread's depth briefly, coincidentally crosses the slope's depth once per
# step. Bounding ALL contact probes by a single min/max would fuse those
# pinpoint coincidences into one giant erased span, swallowing the real
# DEPTH_TOL-failing evidence sitting between them. So probes are sorted by t
# and walked in order: a run of contact extends across a probe-density gap
# (<= GAP) only when nothing was observed in that gap, and breaks the moment
# real keep evidence is seen — never merging across an observed non-contact.
static func _span(a: Dictionary, b: Dictionary, d: int, screen: Vector2, shift: float, off: Vector3i, ramp_bridge: bool = false) -> Array:
	if (a.present & (1 << d)) == 0:
		return []

	var out: Vector2 = a.out[d]
	var probes: PackedFloat32Array = a.probes[d]
	var to_b: Vector2 = b.origin - a.origin - screen

	var entries := []
	var keep_lo = INF
	var keep_hi = -INF

	for i in range(0, probes.size(), 5):
		var from = Vector2(probes[i + 2], probes[i + 3]) + to_b + out
		var sb = MeshDepth.first_covered(b.depth, b.region_size, from, out, SLOP_PX - 1)
		var t_lo = probes[i]
		var t_hi = probes[i + 1]

		if sb == null:
			keep_lo = minf(keep_lo, t_lo)
			keep_hi = maxf(keep_hi, t_hi)
			entries.append(Vector3(t_lo, t_hi, 0.0))
			continue

		var nb = MeshDepth.at(b.depth, b.region_size, sb)
		var wa = probes[i + 4]

		# Standard DEPTH_TOL check — skipped for a known ramp-chain join, where
		# the neighbor is understood to continue the same ramp regardless of
		# per-step depth jaggedness (touching is enough).
		if not ramp_bridge and absf(wa - (nb.x + shift)) > DEPTH_TOL and absf(wa - (nb.y + shift)) > DEPTH_TOL:
			keep_lo = minf(keep_lo, t_lo)
			keep_hi = maxf(keep_hi, t_hi)
			entries.append(Vector3(t_lo, t_hi, 0.0))
			continue

		entries.append(Vector3(t_lo, t_hi, 1.0))

	if entries.is_empty():
		return []
	entries.sort_custom(func(x, y): return x.x < y.x)

	var runs := []
	var cur: Vector2 = Vector2(INF, -INF)
	for e in entries:
		if e.z == 0.0:
			if cur.x <= cur.y: runs.append(cur)
			cur = Vector2(INF, -INF)
			continue
		if cur.x > cur.y:
			cur = Vector2(e.x, e.y)
		elif e.x <= cur.y + GAP:
			cur.y = maxf(cur.y, e.y)
		else:
			runs.append(cur)
			cur = Vector2(e.x, e.y)
	if cur.x <= cur.y: runs.append(cur)

	var out_runs := []
	for idx in runs.size():
		var r: Vector2 = runs[idx]
		if r.y - r.x < MIN_SPAN:
			continue
		var span_lo = 0.0 if idx == 0 and keep_lo >= r.x - CORNER_EPS else r.x
		var span_hi = 1.0 if idx == runs.size() - 1 and keep_hi <= r.y + CORNER_EPS else r.y

		# Force the outline to drop an extra pixel specifically for the W edge (5)
		# meeting a SW neighbor (x == 0, z == 1) during a partial occlusion.
		if d == 5 and off.x == 0 and off.z == 1 and span_lo > 0.0:
			span_lo = minf(span_lo + 0.04, span_hi)

		out_runs.append(Vector2(span_lo, span_hi))
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
