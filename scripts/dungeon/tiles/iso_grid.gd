@tool
extends GridMap
class_name IsoGrid

const LIB_PATH = "res://scenes/dungeon/tilesets/tile_mesh_lib_%d.tres"

const NORMAL_STEPS = 16.0 # Steps between a new facing is counted
var Tools = IsoGridTools

# One .obj serves all four cardinal facings; a tile picks one with "rotation"
const ROTATION = {"n": 0.0, "e": -PI / 2, "s": PI, "w": PI / 2}

## The tile catalogue: tilesheet regions paired with .obj meshes.
@export_file("*.json") var tile_config: String = "res://data/tiles/tiles.json"

## Extra GridMaps stacked on this one, in order. Each takes the next layer's tile library.
@export var overlays: Array[NodePath] = []:
	set(v):
		overlays = v
		if is_node_ready(): _apply_layers()

## Re-read tiles.json and regenerate every MeshLibrary. Editor only - it writes to disk.
@export_tool_button("Rebuild tiles") var _rebuild = rebuild

## Point the editor viewport at the level from the game's exact camera angle.
@export_tool_button("Isometric view") var _snap = Tools.snap_view

func _ready() -> void:
	_apply_layers()

# Give every grid in the stack the shared cell size and its own layer's library.
func _apply_layers(libs: Array = []) -> void:
	var size = IsoView.cell_size()
	
	for i in overlays.size() + 1:
		var g: GridMap = self if i == 0 else get_node_or_null(overlays[i - 1]) as GridMap
		if g == null: continue
		
		if not g.cell_size.is_equal_approx(size): g.cell_size = size
		var lib: MeshLibrary = libs[i] if i < libs.size() else Tools._load_lib(i)
		if lib != null and g.mesh_library != lib: g.mesh_library = lib

# Rewrite one MeshLibrary per layer from tiles.json, filing each tile in the layer its tilesheet names.
func rebuild() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(tile_config))
	
	if data == null:
		push_error("IsoGrid: could not parse %s" % tile_config)
		return
	
	var sheets: Array = data.tilesheets.map(func(e): return load(e.path) as Texture2D)
	var libs = Tools._fresh_libraries(data, overlays)
	
	# Tile ids stay global across layers; a layer's library just omits the rest.
	for id in data.tiles.size():
		var tile: Dictionary = data.tiles[id]
		tile["id"] = id
		
		var sheet = tile.get("sheet", 0)
		var lib: MeshLibrary = libs[int(data.tilesheets[sheet].get("layer", 0))]
		
		TileBuilder.build_tile(tile, sheets[sheet], lib)
		
	for i in libs.size():
		ResourceSaver.save(libs[i], LIB_PATH % i)
	_apply_layers(libs)

# === Getters ===

# Get all layers (including self)
func layers() -> Array:
	var layers: Array = [self]
	
	for overlay in overlays:
		var g = get_node_or_null(overlay) as GridMap
		if g == null: continue
		layers.append(g)
	
	return layers

# Get bounds of all tiles in scene
func bounds() -> AABB:
	var bounds = AABB()
	
	for layer in layers():
		for cell in layer.get_used_cells():
			var corner = layer.to_global(layer.map_to_local(cell)) - layer.cell_size * 0.5
			var box = AABB(corner, layer.cell_size)
			bounds = box if not bounds.has_volume() else bounds.merge(box)
			
	return bounds
