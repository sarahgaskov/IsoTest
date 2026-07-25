extends Node3D
class_name Level

# Keyhole director for the player-transparency effect. See
# docs/player_transparency.md for the full pipeline.

const MAX_KEYHOLES = 8  # texture width, and the shader's loop budget

## Radius of the fully-revealed inner disc, in screen pixels.
@export var keyhole_radius: float = 46.0:
	set(v): keyhole_radius = v; _push_tuning()

## Width of the fade-out gradient past the radius, in screen pixels.
@export var keyhole_fade: float = 24.0:
	set(v): keyhole_fade = v; _push_tuning()

## Alpha an occluder keeps at the keyhole's center (0 = fully see-through).
@export var keyhole_min_alpha: float = 0.0:
	set(v): keyhole_min_alpha = v; _push_tuning()

## Extra fade reach (px) for tiles above the entity's head, so they clear
## sooner than a wall at the entity's own level.
@export var keyhole_above_reach: float = 40.0:
	set(v): keyhole_above_reach = v; _push_tuning()

## Half-width (world units) of the body volume tiles are tested against. Keep
## it under the collision radius so a wall the entity is pressed against from
## the visible side stays solid.
@export var keyhole_body_radius: float = 4.0

## Body height in grid layers. The disc centers half this far above the feet.
@export var keyhole_body_layers: float = 1.8

var _entities: Array[Node3D] = []
var _zones: Array = []
var _data_image: Image
var _data_texture: ImageTexture

@onready var _grid: GridMap = get_node_or_null(^"GridMap")

func _ready() -> void:
	# Row 0 = screen pos + floor layer + zone mask, row 1 = the body's far corner.
	_data_image = Image.create(MAX_KEYHOLES, 2, false, Image.FORMAT_RGBAF)
	_data_texture = ImageTexture.create_from_image(_data_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_data", _data_texture)
	_push_tuning()
	refresh()

## Re-scan the "keyhole" group and the interior zones. Call after spawning or
## despawning a tracked entity, or after moving a zone at runtime.
func refresh() -> void:
	_entities.assign(get_tree().get_nodes_in_group(&"keyhole").filter(
		func(n): return n is Node3D))
	_zones = InteriorZones.collect(get_tree())

func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var mid := Vector3(0.0, keyhole_body_layers * Iso.cell().y * 0.5, 0.0)
	var count := 0
	for e in _entities:
		if count >= MAX_KEYHOLES:
			break
		if not is_instance_valid(e):
			continue
		# The origin sits at the feet; the disc centers on the body's midpoint,
		# while the far corner (west, north, feet height) is what tiles are
		# depth-tested against.
		var foot := e.global_position
		var screen := camera.unproject_position(foot + mid)
		var far := foot - Vector3(keyhole_body_radius, 0.0, keyhole_body_radius)
		_data_image.set_pixel(count, 0, Color(screen.x, screen.y,
			_floor_layer(foot), float(InteriorZones.mask_at(_zones, foot))))
		_data_image.set_pixel(count, 1, Color(far.x, far.y, far.z, 0.0))
		count += 1

	if count > 0:
		_data_texture.update(_data_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_count", count)

# Grid layer of the tile the entity stands on; sampling just below the feet
# lands inside the floor cell whether it is a full block or a shallow slab.
func _floor_layer(foot: Vector3) -> float:
	if _grid == null:
		return 0.0
	return float(_grid.local_to_map(_grid.to_local(foot - Vector3(0.0, 0.5, 0.0))).y)

func _push_tuning() -> void:
	RenderingServer.global_shader_parameter_set(&"keyhole_radius", keyhole_radius)
	RenderingServer.global_shader_parameter_set(&"keyhole_fade", keyhole_fade)
	RenderingServer.global_shader_parameter_set(&"keyhole_min_alpha", keyhole_min_alpha)
	RenderingServer.global_shader_parameter_set(&"keyhole_above_reach", keyhole_above_reach)
