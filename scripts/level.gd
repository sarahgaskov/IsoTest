extends Node3D
class_name Level

# Keyhole director. See docs/player_transparency.md for the full pipeline.

const MAX_KEYHOLES = 8  # texture width, and the shader's loop budget
const WALK_LIMIT = 64   # hard cap on diagonal steps per screen column
const SAMPLE_HEIGHTS = [0.15, 0.5, 0.85]  # fractions of body height

# Screen columns searched around the body's: far vertically, barely horizontally.
const COLUMN_SPREAD = 3
const COLUMN_SIDESTEP = 1

## Radius of the fully-revealed inner disc, in screen pixels.
@export var keyhole_radius: float = 46.0:
	set(v): keyhole_radius = v; _push_tuning()

## Width of the fade-out gradient past the radius, in screen pixels.
@export var keyhole_fade: float = 24.0:
	set(v): keyhole_fade = v; _push_tuning()

## Alpha an occluder keeps at the keyhole's center (0 = fully see-through).
@export var keyhole_min_alpha: float = 0.0:
	set(v): keyhole_min_alpha = v; _push_tuning()

## Extra fade reach (px) for tiles above the entity's head.
@export var keyhole_above_reach: float = 40.0:
	set(v): keyhole_above_reach = v; _push_tuning()

## Half-width (world units) of the body volume tiles are tested against; keep it under the collision radius.
@export var keyhole_body_radius: float = 4.0

## Body height in grid layers. The disc centers half this far above the feet.
@export var keyhole_body_layers: float = 1.8

@export_group("Occlusion gate")

## Fade a wall only while it really covers an entity. Off reproduces the ungated behaviour exactly.
@export var keyhole_require_occlusion: bool = true:
	set(v): keyhole_require_occlusion = v; _push_tuning()

## How completely a group's interior cells clear ahead of its shell (0 disables the cut).
@export_range(0.0, 1.0) var keyhole_shell_cut: float = 1.0:
	set(v): keyhole_shell_cut = v; _push_tuning()

## Gate rise rate, in units per second (1.0 / this = seconds to fade in).
@export var keyhole_fade_in_rate: float = 6.0

## Gate fall rate, in units per second; slower than the rise, so walls close lazily.
@export var keyhole_fade_out_rate: float = 3.0

## Screen coverage fraction that latches a group on.
@export_range(0.0, 1.0) var keyhole_cover_on: float = 0.15

## Coverage fraction it must drop below before the group may latch off again.
@export_range(0.0, 1.0) var keyhole_cover_off: float = 0.05

## Seconds a group stays latched on after it stops covering, to stop strobing.
@export var keyhole_hold: float = 0.15

var _entities: Array[Node3D] = []
var _zones: Array = []
var _data_image: Image
var _data_texture: ImageTexture

var _gate_image: Image
var _gate_texture: ImageTexture
var _gate := PackedFloat32Array()  # smoothed 0..1 fade per group
var _on := PackedByteArray()       # latched target per group
var _hold := PackedFloat32Array()  # remaining hold seconds per group
var _live := {}                    # group ids still needing per-frame work

@onready var _grid: GridMap = get_node_or_null(^"GridMap")
@onready var _iso: IsoGrid = _grid as IsoGrid

func _ready() -> void:
	# Row 0 = screen pos + floor layer + zone mask, row 1 = the body's far corner.
	_data_image = Image.create(MAX_KEYHOLES, 2, false, Image.FORMAT_RGBAF)
	_data_texture = ImageTexture.create_from_image(_data_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_data", _data_texture)

	_gate_image = Image.create(OccluderGroups.MAX_GROUPS, 1, false, Image.FORMAT_RF)
	_gate_texture = ImageTexture.create_from_image(_gate_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_groups", _gate_texture)

	if _iso != null and not OccluderGroups.diagonal_is_exact():
		push_warning("Level: the view diagonal is no longer (1,1,1); " +
			"the occlusion gate needs a general grid walk. Disabling it.")
		keyhole_require_occlusion = false

	_push_tuning()
	refresh()

## Re-scan the tracked entities, the interior zones and the grid's fade groups.
func refresh() -> void:
	_entities.assign(get_tree().get_nodes_in_group(&"keyhole").filter(
		func(n): return n is Node3D))
	_zones = InteriorZones.collect(get_tree())

	# Packed arrays are value types, so these cannot be looped over as a set.
	var groups := _iso.group_count() if _iso != null else 0
	_gate.resize(groups)
	_on.resize(groups)
	_hold.resize(groups)
	_gate.fill(0.0)
	_on.fill(0)
	_hold.fill(0.0)
	_live.clear()
	_gate_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_gate_texture.update(_gate_image)

func _process(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var mid := Vector3(0.0, keyhole_body_layers * Iso.cell().y * 0.5, 0.0)
	var gated := keyhole_require_occlusion and _iso != null and not _gate.is_empty()
	var hits := {}
	var count := 0

	for e in _entities:
		if count >= MAX_KEYHOLES:
			break
		if not is_instance_valid(e):
			continue
		# The origin sits at the feet; the disc centers on the body's midpoint.
		var foot := e.global_position
		var screen := camera.unproject_position(foot + mid)
		var layer := 0.0
		var footing := foot.y
		if _grid != null:
			layer = float(_floor_cell(foot).y)
			footing = _footing_y(foot)
		var far := Vector3(foot.x - keyhole_body_radius, footing,
			foot.z - keyhole_body_radius)
		_data_image.set_pixel(count, 0, Color(screen.x, screen.y,
			layer, float(InteriorZones.mask_at(_zones, foot))))
		_data_image.set_pixel(count, 1, Color(far.x, far.y, far.z, 0.0))
		if gated:
			_gather_occluders(camera, foot, mid.y * 2.0, hits)
		count += 1

	if count > 0:
		_data_texture.update(_data_image)
	RenderingServer.global_shader_parameter_set(&"keyhole_count", count)
	if gated:
		_advance_gates(hits, delta)

# Body silhouette samples. The side offsets project to pure screen-horizontal.
func _body_samples(camera: Camera3D, foot: Vector3, height: float) -> PackedVector2Array:
	var side := keyhole_body_radius / sqrt(2.0)
	var samples := PackedVector2Array()
	for f in SAMPLE_HEIGHTS:
		var h := Vector3(0.0, height * f, 0.0)
		samples.append(camera.unproject_position(foot + h))
		samples.append(camera.unproject_position(foot + h + Vector3(side, 0.0, -side)))
		samples.append(camera.unproject_position(foot + h + Vector3(-side, 0.0, side)))
	return samples

# Score how much of the body each tile in reach really covers, best per group.
func _gather_occluders(camera: Camera3D, foot: Vector3, height: float, hits: Dictionary) -> void:
	var hi: Vector3i = _iso.cell_span()[1]
	var samples := _body_samples(camera, foot, height)
	var view := Iso.facing().z
	var floor_depth := foot.dot(view)
	var base := _grid.local_to_map(_grid.to_local(foot))
	var floor_layer := _floor_cell(foot).y
	var step := _grid.global_transform.basis * _grid.cell_size

	for dx in range(-COLUMN_SPREAD, COLUMN_SPREAD + 1):
		for dz in range(-COLUMN_SPREAD, COLUMN_SPREAD + 1):
			if absi(dx - dz) > COLUMN_SIDESTEP:
				continue
			# Start behind the body; the depth test discards what is behind it.
			var c: Vector3i = base + Vector3i(dx, 0, dz) \
				- OccluderGroups.VIEW_STEP * COLUMN_SPREAD
			var center := _grid.to_global(_grid.map_to_local(c))
			# A whole column projects to one point, so this is computed once.
			var column := camera.unproject_position(center)
			for _i in WALK_LIMIT:
				if c.x > hi.x or c.y > hi.y or c.z > hi.z:
					break
				var group := _iso.cell_group(c)
				if group >= 0 and group < _gate.size():
					var type = _iso.cell_type(c)
					if type != null and not is_steppable(type, c, floor_layer) \
							and (center + type.near_offset).dot(view) > floor_depth:
						var cover := _coverage(type, column, samples)
						if cover > float(hits.get(group, 0.0)):
							hits[group] = cover
				c += OccluderGroups.VIEW_STEP
				center += step

# Fraction of the body samples this tile covers; region and screen px are 1:1.
func _coverage(type: Dictionary, column: Vector2, samples: PackedVector2Array) -> float:
	var size: Vector2i = type.region_size
	var depth: PackedVector2Array = type.depth
	var origin: Vector2 = type.origin
	var covered := 0
	for s in samples:
		if MeshDepth.covered(depth, size, origin + (s - column)):
			covered += 1
	return float(covered) / float(samples.size())

# Latch each touched group with hysteresis, then rate-limit its gate toward it.
func _advance_gates(hits: Dictionary, delta: float) -> void:
	for g in hits:
		_live[g] = true

	var settled := []
	var dirty := false
	for g in _live:
		var i: int = g
		var cover: float = hits.get(i, 0.0)
		if cover >= keyhole_cover_on:
			_on[i] = 1
			_hold[i] = keyhole_hold
		elif cover <= keyhole_cover_off:
			if _hold[i] > 0.0:
				_hold[i] = maxf(_hold[i] - delta, 0.0)
			else:
				_on[i] = 0

		var target := float(_on[i])
		var rate := keyhole_fade_in_rate if target > _gate[i] else keyhole_fade_out_rate
		var next := move_toward(_gate[i], target, rate * delta)
		if next != _gate[i]:
			_gate[i] = next
			_gate_image.set_pixel(i, 0, Color(next, 0.0, 0.0, 1.0))
			dirty = true
		if next == 0.0 and _on[i] == 0:
			settled.append(i)

	for g in settled:
		_live.erase(g)
	if dirty:
		_gate_texture.update(_gate_image)

## A ramp the entity can step onto: at most a layer tall, so it never hides it.
func is_steppable(type: Dictionary, cell: Vector3i, floor_layer: int) -> bool:
	return type.ramp and cell.y <= floor_layer + 1

# Cell the entity stands in; sampling below the feet lands inside a slab as well.
func _floor_cell(foot: Vector3) -> Vector3i:
	return _grid.local_to_map(_grid.to_local(foot - Vector3(0.0, 0.5, 0.0)))

# Footing height: a ramp's whole cell is underfoot, a flat floor's is not.
func _footing_y(foot: Vector3) -> float:
	var here := _grid.local_to_map(_grid.to_local(foot))
	if _grid.get_cell_item(here) == GridMap.INVALID_CELL_ITEM:
		return foot.y
	return maxf(foot.y, _grid.to_global(_grid.map_to_local(here)).y + _grid.cell_size.y * 0.5)

func _push_tuning() -> void:
	RenderingServer.global_shader_parameter_set(&"keyhole_radius", keyhole_radius)
	RenderingServer.global_shader_parameter_set(&"keyhole_fade", keyhole_fade)
	RenderingServer.global_shader_parameter_set(&"keyhole_min_alpha", keyhole_min_alpha)
	RenderingServer.global_shader_parameter_set(&"keyhole_above_reach", keyhole_above_reach)
	RenderingServer.global_shader_parameter_set(&"keyhole_shell_cut", keyhole_shell_cut)
	RenderingServer.global_shader_parameter_set(&"keyhole_gate_enable",
		1.0 if keyhole_require_occlusion else 0.0)
