@tool
extends RefCounted
class_name OcclusionMaskBaker

# Bakes painted occlusion masks into edge segments. See docs/outline_occlusion.md.

# Direction colors on the mask, clockwise from top-left: NW NE E SE SW W.
const DIR_COLORS = [
	Color(1, 0, 0), Color(0, 1, 0), Color(0, 1, 1),
	Color(0, 0, 1), Color(1, 1, 0), Color(1, 0, 1),
]

# {edges, out, present} per region, rebaked only when the mask changed.
static func ensure(sheet_path: String, regions: Array) -> Array:
	var mask_path = _sibling(sheet_path, "_o.png")
	if not FileAccess.file_exists(mask_path):
		return []

	var cache_path = _sibling(sheet_path, "_o.json")
	var hash = FileAccess.get_md5(mask_path)
	if FileAccess.file_exists(cache_path):
		var cache = JSON.parse_string(FileAccess.get_file_as_string(cache_path))
		if cache and cache.get("hash", "") == hash and cache.tiles.size() == regions.size():
			return _decode_all(cache.tiles)

	var tiles = _bake(mask_path, regions)
	var file = FileAccess.open(cache_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"hash": hash, "tiles": tiles}, "\t"))
	return _decode_all(tiles)

static func _decode_all(tiles: Array) -> Array:
	var out = []
	for t in tiles:
		out.append(_decode(t))
	return out

static func _bake(mask_path: String, regions: Array) -> Array:
	var img = Image.load_from_file(ProjectSettings.globalize_path(mask_path))
	var tiles = []
	for r in regions:
		var rect = Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
		var bands = region_pixels(img, rect)
		var edges = {}
		for d in DIR_COLORS.size():
			if bands[d].size() >= 2:
				var seg = _farthest_pair(bands[d])
				edges[str(d)] = [seg[0].x, seg[0].y, seg[1].x, seg[1].y]
		tiles.append({"region": [rect.size.x, rect.size.y], "edges": edges})
	return tiles

# The mask as painted on disk, for pixel-exact analysis (bake/rebuild time).
static func raw_mask(sheet_path: String) -> Image:
	var p = _sibling(sheet_path, "_o.png")
	if not FileAccess.file_exists(p): return null
	return Image.load_from_file(ProjectSettings.globalize_path(p))

# One tile region's mask pixels grouped by direction, in region-local coords.
static func region_pixels(img: Image, region: Rect2i) -> Array:
	var out := []
	for d in DIR_COLORS.size(): out.append([])
	if img == null: return out
	var sub = img.get_region(region)
	for y in sub.get_height():
		for x in sub.get_width():
			var c = sub.get_pixel(x, y)
			if c.r + c.g + c.b < 0.5: continue  # unpainted, the common case
			for d in DIR_COLORS.size():
				if c.is_equal_approx(DIR_COLORS[d]):
					out[d].append(Vector2(x, y))
					break
	return out

# Endpoints of a band = the two pixels farthest apart within it.
static func _farthest_pair(pts: Array) -> Array:
	var best = 0.0
	var pair = [pts[0], pts[1]]
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			var d = pts[i].distance_squared_to(pts[j])
			if d > best:
				best = d
				pair = [pts[i], pts[j]]
	return pair

# Cache form -> runtime form: edges in UV, outward screen normals, presence mask.
static func _decode(tile: Dictionary) -> Dictionary:
	var size = Vector2(tile.region[0], tile.region[1])
	var edges = []
	var outward = []
	for i in DIR_COLORS.size():
		edges.append(Vector4.ZERO)
		outward.append(Vector2.ZERO)
	var present = 0
	for k in tile.edges:
		var d = int(k)
		var e = tile.edges[k]
		var a = Vector2(e[0], e[1]) / size
		var b = Vector2(e[2], e[3]) / size
		edges[d] = Vector4(a.x, a.y, b.x, b.y)
		outward[d] = ((a + b) * 0.5 - Vector2(0.5, 0.5)).normalized()
		present |= 1 << d
	return {"edges": edges, "out": outward, "present": present}

static func _sibling(sheet_path: String, suffix: String) -> String:
	return "%s/occlusion/%s%s" % [
		sheet_path.get_base_dir(), sheet_path.get_file().get_basename(), suffix]
