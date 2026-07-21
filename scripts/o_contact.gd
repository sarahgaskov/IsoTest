@tool
extends RefCounted
class_name OcclusionContact

# Detects where a placed cell touches its neighbors: which silhouette edges are
# pressed against. All-or-nothing — any neighbor whose on-screen direction
# aligns with a present edge, and which itself has the matching opposite edge,
# erases that edge in full. Pure geometry over the grid's cell data + baked
# tile types — no rendering, no state.
#
# Partial (per-length) contact was tried two ways — projecting mask edges, then
# projecting real mesh edges against each other — and both mis-measured shared
# edges as parallel, non-overlapping lines; a correct version needs clipping
# self's edge against the neighbor's full hull, not edge-vs-edge. Revisit then.

const FULL_SPAN = Vector2(0, 1)
const ALIGN = 0.6  # ~53 deg: a neighbor can press against more than one edge

# The 26 surrounding cell offsets (3x3x3 minus the center), built once.
static var _offsets: Array = []

# -> {neighbors: int (6-bit edge mask), spans: Array[Vector2] ([t0,t1] per edge)}.
static func resolve(grid: GridMap, cell: Vector3i, types: Dictionary) -> Dictionary:
	if _offsets.is_empty(): _offsets = _neighbor_offsets()
	var type = types[grid.get_cell_item(cell)]
	var spans = _zero_spans()
	var neighbors = 0
	var facing = Iso.facing()
	var basis = grid.global_transform.basis

	for off in _offsets:
		var nid = grid.get_cell_item(cell + off)
		if nid == GridMap.INVALID_CELL_ITEM: continue
		var ntype = types.get(nid)
		if ntype == null: continue

		var world = basis * (Vector3(off) * grid.cell_size)
		var screen = Vector2(world.dot(facing.x), -world.dot(facing.y))
		if screen.length_squared() < 1e-6: continue
		var dir = screen.normalized()

		# A single full-size neighbor spans two hexagon edges at once (the
		# pair bounding the shared cube face).
		for d in 6:
			if (type.present & (1 << d)) == 0: continue
			if (ntype.present & (1 << ((d + 3) % 6))) == 0: continue
			if dir.dot(type.out[d]) > ALIGN:
				neighbors |= 1 << d
				spans[d] = FULL_SPAN

	return {"neighbors": neighbors, "spans": spans}

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
