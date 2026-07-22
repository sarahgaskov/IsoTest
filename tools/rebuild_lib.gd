extends SceneTree

# Rebuilds assets/mesh_lib/tiles.tres from tiles.json without opening the
# editor (same as the "Rebuild tiles" button).

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var grid = IsoGrid.new()
	root.add_child(grid)
	grid.rebuild()
	print("library items: ", grid.mesh_library.get_item_list())
	quit()
