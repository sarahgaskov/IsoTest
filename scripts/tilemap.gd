extends TileMapLayer
class_name Tilemap

var _height_range_local = Vector2i.ZERO   # Min/max local height
var height_range        = Vector2i.ZERO   # Min/max global height

@export var is_floor = false

func _ready():
	if is_floor

# If floor, then height_range is 0 to 0
# If tile, then 0 to 24 (from level static const)

# if player foot > min height, foot < max_height, apply transparency affect
