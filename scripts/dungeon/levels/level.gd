@tool
extends Node3D
class_name Level

## Re-photograph the level's lighting from every tile. Editor only - it writes to disk.
@export_tool_button("Bake lighting") var _bake = rebake_lighting

@onready var lighting = $LightBake
@onready var tiles =    $Layers/Floor

func _ready():
	# Missing, or older than the tiles: shoot a fresh one now. Whether it can be kept afterwards
	# is a separate question - only an editor build can write to res://.
	if not lighting.load_bake(self): await lighting.bake(self)

func rebake_lighting() -> void:
	await $LightBake.bake(self, true)
