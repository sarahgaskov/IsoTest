@tool
extends Node3D
class_name Level

## Rebake the level's lighting from every tile. Editor only - it writes to disk.
@export_tool_button("Bake lighting") var _bake = rebake_lighting

@onready var lighting = $Lighting
@onready var tiles =    $Layers/Floor

func _ready():
	if Engine.is_editor_hint(): return
	lighting.bake(self)

func rebake_lighting() -> void:
	$Lighting.rebake(self)
