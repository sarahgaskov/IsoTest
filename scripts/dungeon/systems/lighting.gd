@tool
extends Node3D
class_name Lighting

const BAKE_PATH = "res://data/lightdata/%s_light.tres"

@onready var light_bake: VoxelGI = $LightBake

func bake(level: Level) -> void:
	var tiles = level.tiles
	if not _fit(tiles): return

	var stamp = _tile_stamp(tiles)
	if light_bake.data != null and light_bake.data.get_meta("tiles", 0) == stamp: return

	_light(level, stamp)

# Bake from scratch and save the result under the shared light data folder
func rebake(level: Level) -> void:
	var tiles = level.tiles
	if not _fit(tiles): return

	var scene = level.scene_file_path
	if scene.is_empty():
		push_error("Lighting: save the level scene before baking")
		return

	var path = BAKE_PATH % scene.get_file().get_basename()
	DirAccess.make_dir_recursive_absolute(BAKE_PATH.get_base_dir())

	_light(level, _tile_stamp(tiles))
	light_bake.data.take_over_path(path)
	ResourceSaver.save(light_bake.data, path)

# Sit the bake volume on the tiles. False when the level has no tiles to light.
func _fit(tiles: IsoGrid) -> bool:
	var bounds = tiles.bounds()
	if not bounds.has_volume(): return false

	light_bake.size = bounds.size
	light_bake.global_position = bounds.get_center()
	return true

# Light everything under the level, stamped with the tiles it was baked from.
func _light(level: Level, stamp: int) -> void:
	light_bake.bake(level, false)
	light_bake.data.set_meta("tiles", stamp)

# A fingerprint of every tile in the stack, so an edited level rebakes on load.
func _tile_stamp(tiles: IsoGrid) -> int:
	var cells = PackedInt32Array()

	for layer in tiles.layers():
		var used = layer.get_used_cells()
		used.sort()

		for cell in used:
			cells.append_array([cell.x, cell.y, cell.z,
				layer.get_cell_item(cell), layer.get_cell_item_orientation(cell)])

	return hash(cells)
