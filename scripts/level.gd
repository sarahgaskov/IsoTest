extends Node3D
class_name Level

# Keyhole director. Every frame it projects each tracked entity (the player,
# and anything else added to the "keyhole" group) to screen space, packs its
# screen position + iso depth into a tiny data texture, and hands that plus the
# tuning uniforms to the occlusion shader via global shader parameters. The
# shader (assets/shaders/occlusion.gdshader) then fades any tile that stands
# between the camera and an entity, out to keyhole_radius with a soft gradient.

const MAX_KEYHOLES = 8  # must match the loop bound the shader can afford

## Radius of the fully-revealed inner disc, in screen pixels.
@export var keyhole_radius: float = 46.0:
	set(v): keyhole_radius = v; _push_tuning()

## Width of the fade-out gradient past the radius, in screen pixels.
@export var keyhole_fade: float = 24.0:
	set(v): keyhole_fade = v; _push_tuning()

## Alpha an occluder keeps at the keyhole's center (0 = fully see-through,
## 0.3 = a faint ghost of the wall remains).
@export var keyhole_min_alpha: float = 0.0:
	set(v): keyhole_min_alpha = v; _push_tuning()

# Entities needing a keyhole. Collected from the "keyhole" group so the player
# (and later party members, NPCs, ...) register themselves just by joining it.
var _entities: Array[Node3D] = []

var _data_image: Image
var _data_texture: ImageTexture

func _ready() -> void:
	_data_image = Image.create(MAX_KEYHOLES, 1, false, Image.FORMAT_RGBAF)
	_data_texture = ImageTexture.create_from_image(_data_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_data", _data_texture)
	_push_tuning()
	refresh_entities()

# Re-scan the "keyhole" group. Call after spawning/despawning tracked entities.
func refresh_entities() -> void:
	_entities.clear()
	for n in get_tree().get_nodes_in_group(&"keyhole"):
		if n is Node3D:
			_entities.append(n)

func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var f_z: Vector3 = Iso.facing().z
	var count := 0

	for e in _entities:
		if not is_instance_valid(e):
			continue
		if count >= MAX_KEYHOLES:
			break
		# The entity's origin sits at its feet, so global_position is the foot
		# point: its screen position for the disc, its iso depth for the in-front
		# test, and its world Y for the "does the tile rise above me" test.
		var foot := e.global_position
		# unproject_position and the shader's FRAGCOORD share a top-left origin,
		# so the projected point maps straight through — no Y flip.
		var screen := camera.unproject_position(foot)
		var depth := foot.dot(f_z)  # greater = closer to camera
		_data_image.set_pixel(count, 0, Color(screen.x, screen.y, depth, foot.y))
		count += 1

	_data_texture.update(_data_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_data", _data_texture)
	RenderingServer.global_shader_parameter_set(&"keyhole_count", count)

func _push_tuning() -> void:
	RenderingServer.global_shader_parameter_set(&"keyhole_radius", keyhole_radius)
	RenderingServer.global_shader_parameter_set(&"keyhole_fade", keyhole_fade)
	RenderingServer.global_shader_parameter_set(&"keyhole_min_alpha", keyhole_min_alpha)
