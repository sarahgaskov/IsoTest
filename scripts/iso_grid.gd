@tool
extends GridMap
class_name IsoGrid

const LIB_PATH = "res://assets/mesh_lib/tiles.tres"
const OCC_SHADER = preload("res://assets/shaders/occlusion.gdshader")

## Tilesheet regions rigged to .obj files (may reference several tilesheets)
@export_file("*.json") var config = "res://tiles.json"

## Rebuild mesh library according to config
@export_tool_button("Rebuild tiles") var _rebuild = rebuild

## Re-scan every occlusion mask from scratch, ignoring the cache
@export_tool_button("Rebake occlusion") var _rebake = rebake

@export_group("Editor aids")
## Swap sprites for the raw 3D models, one color per face [EDITOR ONLY]
@export var show_3d = false:
	set(v):
		show_3d = v
		if is_node_ready(): rebuild()

## A white plane at height 0 to build on top of [EDITOR ONLY]
@export var show_floor = true:
	set(v):
		show_floor = v
		if is_node_ready(): _refresh_floor()

## Wireframe cell box on every placed tile for reading geometry [EDITOR ONLY]
@export var show_wireframe = true:
	set(v):
		show_wireframe = v
		if is_node_ready(): _refresh_wire()

var _wire_hash = 0
var _occ_hash = 0
var _types := {}          # cell item id -> {mesh, mat, edges, out, present}
var _blank_mask: ImageTexture

func _ready() -> void:
	cell_size = Iso.cell()
	set_process(Engine.is_editor_hint())
	_setup()
	_refresh_floor()
	_refresh_wire()

# Build the render types + sprite layer from config, without touching the
# saved mesh library (so it is safe at runtime, unlike rebuild()).
func _setup() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	if data == null: return
	var paths: Array = data.get("tilesheets", [data.get("tilesheet")])
	var sheets: Array = paths.map(func(p): return load(p) as Texture2D)
	_build_types(data, paths, sheets)
	if not show_3d: _mute_library()
	_occ_hash = 0
	_refresh_sprites()

# Drop the placed-cell meshes so GridMap draws only collision; the sprite layer
# owns the visuals. In-memory only, so the saved library is left untouched.
func _mute_library() -> void:
	if mesh_library == null: return
	for id in mesh_library.get_item_list():
		mesh_library.set_item_mesh(id, null)
	var lib = mesh_library
	mesh_library = null
	mesh_library = lib

func _process(_delta: float) -> void:
	var h = get_used_cells().hash()
	if show_wireframe and h != _wire_hash:
		_refresh_wire()
	if not show_3d and h != _occ_hash:
		_refresh_sprites()

func rebuild() -> void:
	cell_size = Iso.cell()

	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	if data == null:
		push_error("IsoGrid: could not parse %s" % config)
		return

	var paths: Array = data.get("tilesheets", [data.get("tilesheet")])
	var sheets: Array = paths.map(func(p): return load(p) as Texture2D)
	var lib = _fresh_library()

	# GridMap keeps the collision and the palette preview; the sprites
	# themselves are drawn by the occlusion layer (see _refresh_sprites),
	# so placed cells carry a mesh only in the 3D debug view.
	for id in data.tiles.size():
		var tile: Dictionary = data.tiles[id]
		lib.create_item(id)
		lib.set_item_name(id, tile.name)
		lib.set_item_mesh(id, _debug_mesh(tile) if show_3d else null)
		lib.set_item_shapes(id, [_collision(tile), Transform3D.IDENTITY])
		lib.set_item_preview(id, _slice(sheets[tile.get("sheet", 0)], _region(tile)))
	ResourceSaver.save(lib, LIB_PATH)
	mesh_library = lib

	_build_types(data, paths, sheets)
	_occ_hash = 0
	_refresh_sprites()

# Force a clean occlusion rebake, then rebuild.
func rebake() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	for p in data.get("tilesheets", [data.get("tilesheet")]):
		var cache = "%s/occlusion/%s_o.json" % [p.get_base_dir(), p.get_file().get_basename()]
		if FileAccess.file_exists(cache): DirAccess.remove_absolute(ProjectSettings.globalize_path(cache))
	rebuild()

# One shader material per tile type, fed the baked edges of its sheet's mask.
func _build_types(data: Dictionary, paths: Array, sheets: Array) -> void:
	_types = {}
	for si in paths.size():
		var ids := []
		var regions := []
		for id in data.tiles.size():
			if data.tiles[id].get("sheet", 0) == si:
				ids.append(id)
				regions.append(data.tiles[id].region)
		if ids.is_empty(): continue

		var baked = OcclusionMaskBaker.ensure(paths[si], regions)
		var sheet_img: Image = sheets[si].get_image()
		var mask_img = _load_mask(paths[si])
		for k in ids.size():
			_types[ids[k]] = _make_type(
				data.tiles[ids[k]], sheet_img, mask_img,
				baked[k] if k < baked.size() else {})

func _make_type(tile: Dictionary, sheet: Image, mask: Image, baked: Dictionary) -> Dictionary:
	var region = _region(tile)
	var edges = baked.get("edges", _zeros(Vector4.ZERO))
	var out = baked.get("out", _zeros(Vector2.ZERO))
	var present = baked.get("present", 0)

	var mat = ShaderMaterial.new()
	mat.shader = OCC_SHADER
	mat.set_shader_parameter("albedo_tex", _crop(sheet, region))
	mat.set_shader_parameter("mask_tex", _crop(mask, region) if mask else _fallback_mask())
	mat.set_shader_parameter("edges", edges)

	return {
		"mesh": _quad(tile),
		"mat": mat,
		"edges": edges,
		"out": out,
		"present": present,
	}

# For shader sampling (tolerant to import compression, works in exports too).
func _load_mask(sheet_path: String) -> Image:
	var p = "%s/occlusion/%s_o.png" % [sheet_path.get_base_dir(), sheet_path.get_file().get_basename()]
	if ResourceLoader.exists(p):
		return (load(p) as Texture2D).get_image()
	return null

func _crop(img: Image, region: Rect2) -> ImageTexture:
	return ImageTexture.create_from_image(img.get_region(Rect2i(region)))

func _fallback_mask() -> ImageTexture:
	if _blank_mask == null:
		var img = Image.create(1, 1, false, Image.FORMAT_RGB8)
		_blank_mask = ImageTexture.create_from_image(img)
	return _blank_mask

func _zeros(v: Variant) -> Array:
	var out := []
	for i in 6: out.append(v)
	return out

# The raw .obj shaded with a flat color per face, for reading geometry.
func _debug_mesh(tile: Dictionary) -> ArrayMesh:
	var faces = (load(tile.mesh) as Mesh).get_faces()
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var colors := {}
	for i in range(0, faces.size(), 3):
		var normal = (faces[i + 1] - faces[i]).cross(faces[i + 2] - faces[i]).normalized()
		var key = normal.snapped(Vector3.ONE * 0.001)
		if not colors.has(key):
			colors[key] = Color.from_hsv(colors.size() * 0.61803, 0.65, 1.0)
		st.set_color(colors[key])
		for j in range(3):
			st.add_vertex(faces[i + j])
	st.set_material(_debug_material())
	return st.commit()

func _debug_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	return material

# The pixel-perfect billboard quad; its shading comes from the type's material.
func _quad(tile: Dictionary) -> QuadMesh:
	var quad = QuadMesh.new()
	quad.size = _region(tile).size * Iso.PIXEL_SCALE
	var off: Array = tile.get("offset_px", [0, 0])
	quad.center_offset = Vector3(off[0], off[1], 0) * Iso.PIXEL_SCALE
	return quad

# = OCCLUSION LAYER =

# One billboard per used cell, reusing its type's shader material and carrying
# its own neighbor / contact data as instance parameters.
func _refresh_sprites() -> void:
	if not is_inside_tree(): return
	var layer = _sprite_layer()
	if show_3d:
		layer.visible = false
		_occ_hash = 0
		return
	layer.visible = true

	var cells = get_used_cells()
	var wanted := {}
	for c in cells: wanted[c] = true
	var existing := {}
	for child in layer.get_children():
		var cell = child.get_meta("cell")
		if wanted.has(cell): existing[cell] = child
		else: child.free()

	for c in cells:
		var type = _types.get(get_cell_item(c))
		if type == null: continue
		var mi: MeshInstance3D = existing.get(c)
		if mi == null:
			mi = MeshInstance3D.new()
			mi.set_meta("cell", c)
			layer.add_child(mi)
			mi.owner = null
		mi.mesh = type.mesh
		mi.material_override = type.mat
		mi.position = map_to_local(c)
		_apply_occlusion(mi, c)
	_occ_hash = cells.hash()

# Detect where the cell touches neighbors, then hand the result to the shader.
func _apply_occlusion(mi: MeshInstance3D, cell: Vector3i) -> void:
	var contact = OcclusionContact.resolve(self, cell, _types)
	var s: Array = contact.spans
	mi.set_instance_shader_parameter("neighbors", contact.neighbors)
	mi.set_instance_shader_parameter("range01", Vector4(s[0].x, s[0].y, s[1].x, s[1].y))
	mi.set_instance_shader_parameter("range23", Vector4(s[2].x, s[2].y, s[3].x, s[3].y))
	mi.set_instance_shader_parameter("range45", Vector4(s[4].x, s[4].y, s[5].x, s[5].y))

func _sprite_layer() -> Node3D:
	var layer = get_node_or_null(^"SpriteLayer") as Node3D
	if layer == null:
		layer = Node3D.new()
		layer.name = "SpriteLayer"
		add_child(layer)
		layer.owner = null
	return layer

# Real collision from .obj
func _collision(tile: Dictionary) -> Shape3D:
	return (load(tile.mesh) as Mesh).create_trimesh_shape()

# Reuse the resource already on disk so its UID stays stable across rebuilds.
func _fresh_library() -> MeshLibrary:
	if not ResourceLoader.exists(LIB_PATH):
		return MeshLibrary.new()
	var lib: MeshLibrary = load(LIB_PATH)
	for id in lib.get_item_list():
		lib.remove_item(id)
	return lib

func _slice(sheet: Texture2D, region: Rect2) -> AtlasTexture:
	var atlas = AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = region
	return atlas

func _region(tile: Dictionary) -> Rect2:
	var r: Array = tile.region
	return Rect2(r[0], r[1], r[2], r[3])

# = IN-EDITOR Helpers =

func _refresh_floor() -> void:
	if not Engine.is_editor_hint():
		return
		
	var ground = get_node_or_null(^"BuildFloor")
	
	if not show_floor:
		if ground: ground.free()
		return
	
	if ground:
		return
	
	var mesh = PlaneMesh.new()
	mesh.size = Vector2.ONE * Iso.UNIT * 64.0
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = material
	
	ground = MeshInstance3D.new()
	ground.name = "BuildFloor"
	ground.mesh = mesh
	ground.position.y = -Iso.UNIT * 0.5  # ground under the first layer of cells
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	add_child(ground)

func _refresh_wire() -> void:
	if not Engine.is_editor_hint():
		return
		
	var wire = get_node_or_null(^"WireOverlay") as MeshInstance3D
	if not show_wireframe:
		if wire: wire.free()
		return
	
	if wire == null:
		wire = MeshInstance3D.new()
		wire.name = "WireOverlay"
		add_child(wire)
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	st.set_material(_wire_material())
	
	var half = Iso.cell() * 0.5
	
	for cell in get_used_cells():
		_add_box(st, map_to_local(cell), half)
	
	wire.mesh = st.commit()
	_wire_hash = get_used_cells().hash()

func _wire_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.35, 1.0, 0.55)
	return material

func _add_box(st: SurfaceTool, c: Vector3, h: Vector3) -> void:
	var corners: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				corners.append(c + Vector3(sx * h.x, sy * h.y, sz * h.z))

	# Index order matches the sx,sy,sz loop above (x outermost, z innermost).
	var edges := [
		[0, 1], [2, 3], [4, 5], [6, 7],  # along z
		[0, 2], [1, 3], [4, 6], [5, 7],  # along y
		[0, 4], [1, 5], [2, 6], [3, 7],  # along x
	]
	for e in edges:
		st.add_vertex(corners[e[0]])
		st.add_vertex(corners[e[1]])
