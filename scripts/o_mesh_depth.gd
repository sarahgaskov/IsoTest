@tool
extends RefCounted
class_name MeshDepth

# A tile's mesh rasterized through the fixed iso projection into a per-pixel
# [front, back] depth span of the solid, in the sprite region's pixel space.
# Rasterizing once per type makes every contact query an O(1) lookup.

const EMPTY = Vector2(INF, -INF)  # uncovered pixel
const MAX_WALK = 24  # px, inward walk across the mask/mesh border

static func origin(size: Vector2i, offset_px: Vector2) -> Vector2:
	return Vector2(size) * 0.5 + Vector2(-offset_px.x, offset_px.y)

static func rasterize(mesh: Mesh, size: Vector2i, offset_px: Vector2) -> PackedVector2Array:
	var tile = PackedVector2Array()
	tile.resize(size.x * size.y)
	tile.fill(EMPTY)
	var f = Iso.facing()
	var o = origin(size, offset_px)
	var faces = mesh.get_faces()
	for i in range(0, faces.size(), 3):
		var tri := []
		for j in 3:
			var v: Vector3 = faces[i + j]
			var px = o + Vector2(v.dot(f.x), -v.dot(f.y)) / Iso.PIXEL_SCALE
			tri.append(Vector3(px.x, px.y, v.dot(-f.z)))
		_scan(tile, size, tri[0], tri[1], tri[2])
	return tile

static func _scan(tile: PackedVector2Array, size: Vector2i, a: Vector3, b: Vector3, c: Vector3) -> void:
	var det = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if absf(det) < 1e-6: return  # edge-on triangle, no footprint
	var x0 = clampi(floori(minf(a.x, minf(b.x, c.x))), 0, size.x - 1)
	var x1 = clampi(ceili(maxf(a.x, maxf(b.x, c.x))), 0, size.x - 1)
	var y0 = clampi(floori(minf(a.y, minf(b.y, c.y))), 0, size.y - 1)
	var y1 = clampi(ceili(maxf(a.y, maxf(b.y, c.y))), 0, size.y - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p = Vector2(x + 0.5, y + 0.5)
			var w0 = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / det
			var w1 = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / det
			var w2 = 1.0 - w0 - w1
			if w0 < 0.0 or w1 < 0.0 or w2 < 0.0: continue
			var depth = w0 * a.z + w1 * b.z + w2 * c.z
			var i = y * size.x + x
			tile[i] = Vector2(minf(tile[i].x, depth), maxf(tile[i].y, depth))

static func at(tile: PackedVector2Array, size: Vector2i, pos: Vector2) -> Vector2:
	var x = floori(pos.x)
	var y = floori(pos.y)
	if x < 0 or y < 0 or x >= size.x or y >= size.y: return EMPTY
	return tile[y * size.x + x]

static func covered(tile: PackedVector2Array, size: Vector2i, pos: Vector2) -> bool:
	return at(tile, size, pos).x != INF

# First covered position walking from `from` along `dir`, 1 px steps, or null.
static func first_covered(tile: PackedVector2Array, size: Vector2i, from: Vector2, dir: Vector2, steps: int) -> Variant:
	var p = from
	for i in steps + 1:
		if covered(tile, size, p): return p
		p += dir
	return null

# The real silhouette segment under one edge's mask wedge: every wedge pixel is
# walked inward to the mesh, and the two farthest-apart hits are its endpoints.
static func silhouette_edge(tile: PackedVector2Array, size: Vector2i, wedge: Array, outward: Vector2) -> Variant:
	var hits := []
	for p in wedge:
		var s = first_covered(tile, size, p + Vector2(0.5, 0.5), -outward, MAX_WALK)
		if s != null: hits.append(s)
	if hits.size() < 2: return null
	var best = -1.0
	var pair := [hits[0], hits[1]]
	for i in hits.size():
		for j in range(i + 1, hits.size()):
			var d2 = hits[i].distance_squared_to(hits[j])
			if d2 > best:
				best = d2
				pair = [hits[i], hits[j]]
	return Vector4(pair[0].x, pair[0].y, pair[1].x, pair[1].y)
