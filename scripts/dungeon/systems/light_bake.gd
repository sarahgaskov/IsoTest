@tool
extends Node3D
class_name LightBake

const BAKE_DIR = "res://data/lightdata/%s"
const MANIFEST = "bake.json"
const SLICE = "elev_%d.png"

# The two states a slice takes during a bake
const DRAWN = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
const SHADOW_ONLY = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY

## Render at this multiple of the art resolution, then box down. Softens shadow stair steps.
@export_range(1, 4) var supersample: int = 2
## Bake with this instead of the level's own environment.
@export var bake_environment: Environment
## Re-render whenever the tiles stop matching the bake on disk.
@export var auto_bake: bool = true

# The bake once loaded: one image per elevation, plus the projection that addresses them.
var slices: Dictionary = {}
var rect: Rect2
var stamp: int = 0

# === RUNTIME ===

# Pull the bake off disk. False when there is none, or it no longer matches the tiles.
func load_bake(level: Level) -> bool:
	var dir = BAKE_DIR % _name(level)
	var manifest = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [dir, MANIFEST]))
	if manifest == null: return false

	slices.clear()
	rect = Rect2(manifest.rect[0], manifest.rect[1], manifest.rect[2], manifest.rect[3])
	stamp = int(manifest.stamp)

	for elevation in manifest.slices:
		var tex = load("%s/%s" % [dir, manifest.slices[elevation]]) as Texture2D
		if tex == null: continue

		# Kept on the CPU as well as the GPU: the player is tinted by reading single pixels.
		var image = tex.get_image()
		if image.is_compressed(): image.decompress()
		slices[int(elevation)] = image

	return not slices.is_empty() and stamp == LightBakeTools.tile_stamp(level.tiles)

# The baked light landing on one spot (for anything the bake couldn't see)
func light_at(world: Vector3, elevation: int) -> Color:
	var image: Image = slices.get(elevation)
	if image == null: return Color.WHITE

	var px = LightBakeTools.to_pixel(world, rect)
	return image.get_pixelv(px.clamp(Vector2i.ZERO, image.get_size() - Vector2i.ONE))

# === BAKE ===

# Photograph every elevation and save the results
func bake(level: Level, force = false) -> void:
	var bounds = level.tiles.bounds()
	if not bounds.has_volume(): return

	if level.scene_file_path.is_empty():
		push_error("LightBake: save the level scene before baking")
		return

	var mark = LightBakeTools.tile_stamp(level.tiles)
	if not force and mark == stamp and not slices.is_empty(): return

	var meshes = LightBakeTools.slice_meshes(level.tiles.layers())
	if meshes.is_empty(): return

	var view = LightBakeTools.frame(bounds)
	var viewport = _viewport(view, level)
	for elevation in meshes: viewport.add_child(meshes[elevation])

	slices.clear()
	await RenderingServer.frame_post_draw # Let the fresh world settle before the first shot

	# Every elevation stays in the shadow map; only the one being shot is drawn. So a wall two
	# floors up still lays its shadow on this floor without appearing in this floor's picture.
	for elevation in meshes:
		for other in meshes:
			meshes[other].cast_shadow = DRAWN if other == elevation else SHADOW_ONLY
		slices[elevation] = await _shoot(viewport, view.px)

	viewport.queue_free()
	rect = view.rect
	stamp = mark
	_save(level)

# An offscreen copy of the level, lit the same way, sized so one texel is one art pixel.
func _viewport(view: Dictionary, level: Level) -> SubViewport:
	var lights = find_children("*", "Light3D", true, false)

	# A world of its own, set before anything is added so the slices never touch the real level.
	# It has to be assigned outright: use_own_world_3d parks it where the world_3d getter cannot see it.
	var world = World3D.new()
	world.environment = bake_environment if bake_environment != null \
		else LightBakeTools.environment(level)

	var viewport = SubViewport.new()
	viewport.size = view.px * supersample
	viewport.world_3d = world
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport, false, Node.INTERNAL_MODE_BACK)

	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = view.rect.size.y
	camera.near = view.near
	camera.far = view.far
	viewport.add_child(camera)
	camera.global_transform = Transform3D(IsoView.camera_basis(), view.origin)

	# Copies, so the bake can reach shadows across the whole level without touching the level's lights.
	for light in lights:
		var copy: Light3D = light.duplicate()
		viewport.add_child(copy)
		copy.global_transform = light.global_transform
		if copy is DirectionalLight3D:
			copy.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
			copy.directional_shadow_max_distance = view.far

	return viewport

# One frame of the bake camera, brought back down to art resolution.
func _shoot(viewport: SubViewport, px: Vector2i) -> Image:
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var image = viewport.get_texture().get_image()
	if image.get_size() != px: image.resize(px.x, px.y, Image.INTERPOLATE_LANCZOS)
	image.convert(Image.FORMAT_RGB8)
	return image

# One png per elevation, plus the projection that maps world space onto them.
func _save(level: Level) -> void:
	var dir = BAKE_DIR % _name(level)
	DirAccess.make_dir_recursive_absolute(dir)

	var names = {}

	for elevation in slices:
		names[elevation] = SLICE % elevation
		slices[elevation].save_png("%s/%s" % [dir, names[elevation]])

	var file = FileAccess.open("%s/%s" % [dir, MANIFEST], FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"stamp": stamp,
		"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
		"slices": names,
	}, "\t"))
	file.close()

	print("LightBake: %d elevations at %d x %d -> %s" % [slices.size(),
		rect.size.x / IsoView.WORLD_PER_PX, rect.size.y / IsoView.WORLD_PER_PX, dir])

	if Engine.is_editor_hint():
		Engine.get_singleton("EditorInterface").get_resource_filesystem().scan()

# A bake belongs to the scene it was shot from.
func _name(level: Level) -> String:
	return level.scene_file_path.get_file().get_basename()
