@tool
class_name IsoView

# The numbers that define the look. Same values as Imagima.
const BLOCK_SIZE = 24.0            # tile cube edge; every .obj fits a 24^3 box
const LAYER_PX = 24.0             # how much higher each stacked layer draws
const CAM_YAW = 45.0              # what turns the square grid into diamonds
const CAM_PITCH = 30.0            # what squashes those diamonds to exactly 2:1

const WORLD_PER_PX = sqrt(2) / 2.0
const SCRN_RISE = cos(deg_to_rad(CAM_PITCH))


# Size for GridMap.cell_size
static func cell_size() -> Vector3:
	return Vector3(BLOCK_SIZE, LAYER_PX * WORLD_PER_PX / SCRN_RISE, BLOCK_SIZE)

# Screen coords (x = right, y = up, z = to camera)
static func camera_basis() -> Basis:
	return Basis(Vector3.UP, deg_to_rad(CAM_YAW)) * Basis(Vector3.RIGHT, deg_to_rad(-CAM_PITCH))
