@tool
extends RefCounted
class_name TileBuilder

static var _material: StandardMaterial3D

static func build_tile(tile: Dictionary, sheet: Texture2D, lib: MeshLibrary):
	var id = tile["id"]
	
	lib.create_item(id)
	lib.set_item_name(id, tile.name)
	lib.set_item_mesh(id, tile_mesh(tile))
	lib.set_item_preview(id, _preview(sheet, tile.sheet_region))

# Make squashed, rotated, and colored mesh for tile
static func tile_mesh(tile: Dictionary) -> ArrayMesh:
	var faces = (load(tile.mesh) as Mesh).get_faces()
	var basis = Basis(Vector3.UP, IsoGrid.ROTATION[tile.get("rotation", "n")])
	var y_scale = IsoView.cell_size().y / IsoView.BLOCK_SIZE
	
	# Scale and rotate tile faces
	for i in faces.size():
		var v = basis * faces[i]
		v.y *= y_scale
		faces[i] = v
	
	# Build tile via surface tool
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mesh_material())
	
	# Find normal to each triangle and color faces
	for i in range(0, faces.size(), 3):
		var normal = (faces[i + 1] - faces[i]).cross(faces[i + 2] - faces[i]).normalized()
		st.set_color(facing_color(normal))
		for j in 3: st.add_vertex(faces[i + j])
	
	return st.commit()

# The thumbnail for each tile
static func _preview(sheet: Texture2D, r: Array) -> AtlasTexture:
	var atlas = AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(r[0], r[1], r[2], r[3])
	return atlas

# One arbitrary colour per direction
static func facing_color(normal: Vector3) -> Color:
	var roll = hash(Vector3i((normal * IsoGrid.NORMAL_STEPS).round()))
	return Color.from_hsv(fmod(float(roll) * 0.61803399, 1.0), 0.8, 1.0 - 0.35 * float(roll % 2))

# Make material for tile
static func _mesh_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.vertex_color_use_as_albedo = true
	return _material
