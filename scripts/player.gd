extends CharacterBody3D
class_name Player

# A minimal isometric walker. Input maps to the four on-screen diagonals (the
# world's grid axes as seen through the fixed iso camera), so pressing "up"
# walks the character away from the camera along a grid diagonal, etc.
#
# Collision is handled by move_and_slide (slopes are walkable under floor_max_angle);
# short vertical steps — stair risers, a slab_1 lip — are climbed by a small
# step-up assist. Anything taller than max_step_px reads as a wall and blocks.

## Ground speed in world units per second.
@export var speed: float = 42.0

## Downward acceleration in world units per second².
@export var gravity: float = 240.0

## Tallest step the player can climb, in art pixels. slab_1 is ~4 px tall, so 5
## gives it "slab_1 with some leeway". Converted to world units via the same
## vertical scale the tiles use (Iso.cell().y / Iso.UNIT).
@export var max_step_px: float = 5.0

var _max_step: float  # max_step_px in world units, resolved in _ready

func _ready() -> void:
	_max_step = max_step_px * (Iso.cell().y / Iso.UNIT)
	# Walk up slopes (~39°) but treat near-vertical faces as walls.
	floor_max_angle = deg_to_rad(48.0)
	# Stay glued to the ground when cresting/descending steps up to _max_step.
	floor_snap_length = _max_step + 0.5

func _physics_process(delta: float) -> void:
	var dir := _input_dir()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	_step_up_assist(delta)
	move_and_slide()

# On-screen input (WASD / arrows) mapped to ground movement along the camera's
# projected axes. Screen-right and screen-up (into the screen) are perpendicular
# world diagonals here, so the result runs along the isometric grid.
func _input_dir() -> Vector3:
	var iv := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): iv.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): iv.y += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): iv.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): iv.x += 1.0
	if iv == Vector2.ZERO:
		return Vector3.ZERO
	iv = iv.normalized()

	var b := Iso.facing()
	var right := Vector3(b.x.x, 0.0, b.x.z).normalized()   # screen +X on the ground
	var fwd := Vector3(-b.z.x, 0.0, -b.z.z).normalized()   # into the screen
	return (right * iv.x - fwd * iv.y).normalized()

# If the horizontal path is blocked but would be clear one step higher, lift the
# body by max_step before move_and_slide; floor snapping then re-grounds it on
# the step top. A too-tall obstacle is still blocked when raised, so it stays a wall.
func _step_up_assist(delta: float) -> void:
	if not is_on_floor():
		return
	var h := Vector3(velocity.x, 0.0, velocity.z)
	if h.length() < 0.001:
		return
	var motion := h * delta
	if not test_move(global_transform, motion):
		return  # path is clear, no step needed
	var raised := global_transform.translated(Vector3.UP * _max_step)
	if test_move(raised, motion):
		return  # still blocked a step up → real wall
	global_position.y += _max_step
