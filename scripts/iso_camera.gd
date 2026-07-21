extends Camera3D
class_name IsoCamera

## 3D width / 2D width
const PIXEL_SCALE = sqrt(2)/2.0   
# If tile is 24 x 24 x 24, then
# 3D width = 24sqrt(2); 2D width = 48 px
# 24sqrt(2)/48 = sqrt(2)/2.0

func _ready() -> void:
	
	# Resize the camera for pixel-perfect projection
	var viewport_height = get_viewport().get_visible_rect().size.y
	size = viewport_height * PIXEL_SCALE
