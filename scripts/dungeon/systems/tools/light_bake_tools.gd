@tool
extends RefCounted
class_name LightBakeTools

const PAD_PX = 8.0 # Slack around the level so edge shadows are not clipped
const DEPTH_PAD = 24.0 # How far in front of the nearest tile the bake camera sits

static var _material: StandardMaterial3D

# === PROJECTION ===

# Where the level lands on screen: its footprint in camera space, and that footprint in art pixels.
static func frame(bounds: AABB) -> Dictionary:
	var basis = IsoView.camera_basis()
	var to_view = basis.inverse()
	var low = Vector3.INF
	var high = -Vector3.INF

	for i in 8:
		var corner = to_view * bounds.get_endpoint(i)
		low = low.min(corner)
		high = high.max(corner)

	# Land the corner on a whole art pixel, so the bake lines up with pixel snapped sprites.
	var origin = (Vector2(low.x, low.y) / IsoView.WORLD_PER_PX - Vector2.ONE * PAD_PX).floor()
	var px = (Vector2(high.x, high.y) / IsoView.WORLD_PER_PX + Vector2.ONE * PAD_PX - origin).ceil()
	var rect = Rect2(origin * IsoView.WORLD_PER_PX, px * IsoView.WORLD_PER_PX)

	# Sit the camera past the nearest corner and reach just past the furthest one.
	var center = rect.get_center()
	return {
		"rect": rect,
		"px": Vector2i(px),
		"near": DEPTH_PAD,
		"far": (high.z - low.z) + DEPTH_PAD * 2.0,
		"origin": basis * Vector3(center.x, center.y, high.z + DEPTH_PAD),
	}

# The texel a world point lands on: the bake camera again, minus the depth. Rows run top down.
static func to_pixel(world: Vector3, rect: Rect2) -> Vector2i:
	var view = IsoView.camera_basis().inverse() * world
	return Vector2i(
		floori((view.x - rect.position.x) / IsoView.WORLD_PER_PX),
		floori((rect.end.y - view.y) / IsoView.WORLD_PER_PX))

# === GEOMETRY ===

# One white mesh per elevation, every layer merged into it, placed in world space.
static func slice_meshes(layers: Array) -> Dictionary:
	var tools = {}

	for layer in layers:
		var lib: MeshLibrary = layer.mesh_library
		if lib == null: continue

		for cell in layer.get_used_cells():
			var id = layer.get_cell_item(cell)
			var mesh = lib.get_item_mesh(id)
			if mesh == null: continue

			if not tools.has(cell.y):
				tools[cell.y] = SurfaceTool.new()
				tools[cell.y].begin(Mesh.PRIMITIVE_TRIANGLES)
				tools[cell.y].set_material(_white())

			var cell_xf = Transform3D(layer.get_cell_item_basis(cell), layer.map_to_local(cell))
			var xf = layer.global_transform * cell_xf * lib.get_item_mesh_transform(id)
			for surface in mesh.get_surface_count():
				tools[cell.y].append_from(mesh, surface, xf)

	var out = {}

	for elevation in tools:
		var slice = MeshInstance3D.new()
		slice.name = "Elevation%d" % elevation
		slice.mesh = tools[elevation].commit()
		out[elevation] = slice

	return out

# Plain white and purely diffuse, so what the render captures is the light itself, not the tiles.
static func _white() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.albedo_color = Color.WHITE
		_material.roughness = 1.0
		_material.metallic = 0.0
		_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _material

# Fall back to the level's own environment, so a bake with nothing configured still matches the game.
static func environment(level: Node) -> Environment:
	var found = level.find_children("*", "WorldEnvironment", true, false)
	return found[0].environment if not found.is_empty() else null

# === STAMP ===

# A fingerprint of every tile in the stack, so an edited level rebakes on load.
static func tile_stamp(tiles: IsoGrid) -> int:
	var cells = PackedInt32Array()

	for layer in tiles.layers():
		var used = layer.get_used_cells()
		used.sort()

		for cell in used:
			cells.append_array([cell.x, cell.y, cell.z,
				layer.get_cell_item(cell), layer.get_cell_item_orientation(cell)])

	return hash(cells)
