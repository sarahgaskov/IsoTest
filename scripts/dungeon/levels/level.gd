@tool
extends Node3D
class_name Level

## Re-photograph the level's lighting from every tile. Editor only - it writes to disk.
@export_tool_button("Bake lighting") var _bake = rebake_lighting

@onready var lighting = $LightBake
@onready var tiles =    $Layers/Floor

func _ready():
	if lighting.load_bake(self): return

	# Only the editor can write the bake back out; in game a stale one is all there is.
	if Engine.is_editor_hint() and lighting.auto_bake: await lighting.bake(self)
	else: push_warning("Level: lighting bake is missing or older than the tiles")

func rebake_lighting() -> void:
	await $LightBake.bake(self, true)
