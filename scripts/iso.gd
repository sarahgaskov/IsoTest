@tool
class_name Iso

## 3D width / 2D width
const PIXEL_SCALE = sqrt(2)/2.0
# If tile is 24 x 24 x 24, then
# 3D width = 24sqrt(2); 2D width = 48 px
# 24sqrt(2)/48 = sqrt(2)/2.0

const UNIT = 24.0                 ## edge of a perfect block (3d units)
const TILE_PX = Vector2i(48, 24)  ## isometric footprint of one cell (px)

const LAYER_PX = 24.0  ## on-screen height of one stacked layer (px)

const RISE = cos(deg_to_rad(30)) ## world projected onto screen

const YAW = 45.0   ## camera turn around the up axis
const PITCH = 30.0 ## camera tilt from the horizon (gives the 2:1 diamond)

## GridMap cell size
static func cell() -> Vector3:
	return Vector3(UNIT, LAYER_PX * PIXEL_SCALE / RISE, UNIT)

## Rotation that squares and bakes a flat tile to the fixed iso camera
static func facing() -> Basis:
	return Basis(Vector3.UP, deg_to_rad(YAW)) * Basis(Vector3.RIGHT, deg_to_rad(-PITCH))

## Pixels of art -> 3D units, so 1 px of art == 1 px on screen
static func to_units(px: float) -> float:
	return px * PIXEL_SCALE

## Orthographic camera size that keeps the projection pixel-perfect
static func camera_size(viewport_height_px: float) -> float:
	return viewport_height_px * PIXEL_SCALE
