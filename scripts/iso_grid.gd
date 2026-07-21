@tool
extends GridMap
class_name IsoGrid

const LIB_PATH = "res://assets/mesh_lib/tiles.tres"

#TODO: Allow storing multiple tile sheets in an array

## Tilesheet region rigged to .obj files
@export_file("*.json") var config = "res://tiles.json"

## Rebuild mesh library according to config
@export_tool_button("Rebuild tiles") var _rebuild = rebuild

@export_group("Editor aids")
## A white plane at height 0 to build on top of [EDITOR ONLY]
@export var show_floor = true:
	set(v):
		show_floor = v
		if is_node_ready(): _refresh_floor()

# TODO: Render models with different colored faces, hide sprites

## Wireframe cell box on every placed tile for reading geometry [EDITOR ONLY]
@export var show_wireframe = true:
	set(v):
		show_wireframe = v
		if is_node_ready(): _refresh_wire()

var _wire_hash = 0

func _ready() -> void:
	cell_size = Iso.cell()
	set_process(Engine.is_editor_hint())
	_refresh_floor()
	_refresh_wire()

# Rebuild wire boxes only when cells change
func _process(_delta: float) -> void:
	if not show_wireframe:
		return
	var h = get_used_cells().hash()
	if h != _wire_hash:
		_refresh_wire()

func rebuild() -> void:
	cell_size = Iso.cell()
	
	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	
	if data == null:
		push_error("IsoGrid: could not parse %s" % config)
		return
	
	var sheet: Texture2D = load(data.tilesheet)
	
	var lib = _fresh_library()
	
	# Dynamically build library
	for id in data.tiles.size():
		var tile: Dictionary = data.tiles[id]
		lib.create_item(id)
		lib.set_item_name(id, tile.name)
		lib.set_item_mesh(id, _tile_art(sheet, tile))
		lib.set_item_shapes(id, [_collision(tile), Transform3D.IDENTITY])
		lib.set_item_preview(id, _slice(sheet, _region(tile)))
	ResourceSaver.save(lib, LIB_PATH)
	mesh_library = lib

# The visible tile, a pixel perfect billboarding quad mesh
func _tile_art(sheet: Texture2D, tile: Dictionary) -> QuadMesh:
	var region = _region(tile)
	var material = StandardMaterial3D.new()
	
	material.albedo_texture = _slice(sheet, region)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	
	var quad = QuadMesh.new()
	quad.size = region.size * Iso.PIXEL_SCALE
	
	var off: Array = tile.get("offset_px", [0, 0])
	quad.center_offset = Vector3(off[0], off[1], 0) * Iso.PIXEL_SCALE

	quad.material = material
	
	return quad

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
