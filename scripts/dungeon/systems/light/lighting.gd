extends Node3D
class_name Lighting

## The grid the stand-ins are built from.
@export var tiles: IsoGrid

## Show the light pass instead of the level.
@export var debug: bool = false

var texture: ViewportTexture

var _view: SubViewport
var _camera: Camera3D

func _ready() -> void:
	var lights = find_children("*", "Light3D", true, false)

	# A world of its own. Two cameras on one world share one light instance, and each frame's
	# two renders then overwrite each other's shadow setup. Same environment, so the same ambient.
	var world = World3D.new()
	world.environment = get_viewport().find_world_3d().environment

	_view = SubViewport.new()
	_view.world_3d = world
	_view.size = _screen()
	_view.transparent_bg = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_view)

	_camera = Camera3D.new()
	_view.add_child(_camera)
	_view.add_child(_proxy())

	# Copies, since the level's own lights belong to the level's world.
	for light in lights:
		var copy: Light3D = light.duplicate()
		_view.add_child(copy)
		copy.global_transform = light.global_transform

	texture = _view.get_texture()
	if debug: _show_pass()

# Sprites read the pass at their own SCREEN_UV, so it has to be shot from the game's exact camera.
func _process(_delta: float) -> void:
	var camera = get_viewport().get_camera_3d()
	if camera == null: return

	if _view.size != _screen(): _view.size = _screen()
	_camera.global_transform = camera.global_transform
	_camera.projection = camera.projection
	_camera.size = camera.size
	_camera.near = camera.near
	_camera.far = camera.far

# Every tile in the stack merged into one white mesh.
func _proxy() -> MeshInstance3D:
	var surface = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_white())

	for layer in tiles.layers():
		var lib: MeshLibrary = layer.mesh_library
		if lib == null: continue

		for cell in layer.get_used_cells():
			var id = layer.get_cell_item(cell)
			var mesh = lib.get_item_mesh(id)
			if mesh == null: continue

			var placed = Transform3D(layer.get_cell_item_basis(cell), layer.map_to_local(cell))
			var xf = layer.global_transform * placed * lib.get_item_mesh_transform(id)
			for i in mesh.get_surface_count():
				surface.append_from(mesh, i, xf)

	var proxy = MeshInstance3D.new()
	proxy.mesh = surface.commit()
	return proxy

# Plain white and matte, so the pass carries the light and nothing of the tiles.
func _white() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material

# What the game renders at, which is not Window.size - that one is the window itself.
func _screen() -> Vector2i:
	return Vector2i(get_viewport().get_visible_rect().size)

func _show_pass() -> void:
	var rect = TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE # Or the texture sets a minimum size and overflows
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var overlay = CanvasLayer.new()
	overlay.add_child(rect)
	add_child(overlay)
