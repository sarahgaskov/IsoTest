extends Node3D
class_name Lighting

@onready var light_bake = $LightBake

func bake(tiles: IsoGrid):
	var bounds = tiles.bounds()
	if not bounds.has_volume(): return
	
	light_bake.size = bounds.size
	light_bake.global_position = bounds.get_center()
