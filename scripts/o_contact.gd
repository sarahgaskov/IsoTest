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
# projecting real mesh depth against each other — and both added a lot of
# machinery (mesh rasterization, per-pixel probes, contact-span merging) for
# results that still mismeasured shared edges or fought their own tolerances.
# Reverted to all-or-nothing.

const ALIGN = 0.6  # ~53 deg: a neighbor can press against more than one edge.
				   # Tightening this globally to reject corner-only-touching
				   # diagonal neighbors (tried and reverted) doesn't work: a
				   # genuine cardinal neighbor's alignment drops well below any
				   # such threshold for shorter/asymmetric tiles (measured as
				   # low as ~0.65 for slopes), while a checkerboard-diagonal
				   # neighbor's alignment with NW/NE/SE/SW can hit ~0.83 for a
				   # tall cube — the two ranges overlap, so no single ALIGN
				   # value can separate them. See the per-direction exclusion
				   # in resolve() instead.

# The 26 surrounding cell offsets (3x3x3 minus the center), built once.
static var _offsets: Array = []

# -> 6-bit mask of which silhouette edges are erased in full.
static func resolve(grid: GridMap, cell: Vector3i, types: Dictionary) -> int:
	if _offsets.is_empty(): _offsets = _neighbor_offsets()
	var type: Dictionary = types[grid.get_cell_item(cell)]
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

		# A checkerboard-diagonal neighbor (both X and Z offset) shares only a
		# single corner point with this cell in 3D — never a real edge — for
		# the four "diamond" directions (NW/NE/SE/SW): its screen alignment
		# with them is real (it's not excluded by ALIGN, which has to stay
		# loose enough for short/asymmetric tiles) but geometrically spurious.
		# E/W are the exception: a diagonal neighbor sits exactly between them
		# and a cardinal one, and legitimately presses against them either way.
		var diagonal = off.x != 0 and off.z != 0

		# A single full-size neighbor spans two hexagon edges at once (the
		# pair bounding the shared cube face).
		for d in 6:
			if (type.present & (1 << d)) == 0: continue
			if (ntype.present & (1 << ((d + 3) % 6))) == 0: continue
			if diagonal and d != 2 and d != 5: continue
			if dir.dot(type.out[d]) > ALIGN:
				neighbors |= 1 << d

	return neighbors

static func _neighbor_offsets() -> Array:
	var out := []
	for x in [-1, 0, 1]:
		for y in [-1, 0, 1]:
			for z in [-1, 0, 1]:
				if x != 0 or y != 0 or z != 0:
					out.append(Vector3i(x, y, z))
	return out
