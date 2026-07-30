extends SceneTree

# The "Rebuild tiles" button without the editor - see docs/dungeon-tiles.md.

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var scene = load(ProjectSettings.get_setting("application/run/main_scene")).instantiate()
	root.add_child(scene)
	var grid: IsoGrid = scene.find_children("*", "IsoGrid", true, false)[0]
	grid.rebuild()
	for path in [^"."] + grid.overlays:
		var g: GridMap = grid.get_node(path)
		print("%s: %s" % [g.name, g.mesh_library.get_item_list()])
	quit()
