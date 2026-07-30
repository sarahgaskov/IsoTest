extends Node3D
class_name Level

@onready var lighting = $Lighting
@onready var tiles =    $Layers/Floor

func _ready():
	lighting.bake(tiles)
