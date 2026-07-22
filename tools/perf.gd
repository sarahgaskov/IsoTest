extends SceneTree

# Game-start cost with lazy type building: an empty scene, a 1-tile scene (what
# level.tscn holds), and a mixed multi-type scene.

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://tiles.json"))
	var id := {}
	for i in data.tiles.size(): id[data.tiles[i].name] = i

	_time("empty scene", func(g): pass)
	_time("1 tile (level.tscn)", func(g): g.set_cell_item(Vector3i.ZERO, id.slab_5))
	_time("mixed 8-type scene", func(g):
		var names = ["slab_5", "slab_3", "slab_1", "stairs_n", "corner_stairs_n", "slope_n", "corner_slope_n", "slab_2"]
		for k in names.size(): g.set_cell_item(Vector3i(k, 0, 0), id[names[k]]))

func _time(label: String, place: Callable) -> void:
	var grid = IsoGrid.new()
	var lib = MeshLibrary.new()
	for i in 21: lib.create_item(i)
	grid.mesh_library = lib
	place.call(grid)
	var t0 = Time.get_ticks_msec()
	root.add_child(grid)  # _ready -> _setup -> lazy build only placed types
	var ms = Time.get_ticks_msec() - t0
	print("%s: start=%d ms, types built=%d" % [label, ms, grid._types.size()])
	grid.free()
