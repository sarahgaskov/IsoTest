extends Camera3D
class_name IsoCamera

func _ready() -> void:

	# Resize the camera for pixel-perfect projection
	var viewport_height = get_viewport().get_visible_rect().size.y
	size = Iso.camera_size(viewport_height)
