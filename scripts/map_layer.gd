extends Node2D
class_name MapLayer

var w_index = 0               # World-index - the layer's number in the world
var origin  = Vector2i.ZERO   # Origin (top-left) in world coordinates
var size    = Vector2i.ZERO   # Size in world coordinates

@export var is_interior = false
@export var editor_color = Color.TRANSPARENT

# If interior, draw chosen color in editor
# Assign w_index, origin, size, and visibility layer at runtime
# Camera only looks at certain visibility layer depending on player's
# world_z or w_index

# Dynamically hand out y-sory origin as the player is parsed
