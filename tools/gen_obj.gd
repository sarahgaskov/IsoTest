extends SceneTree

# Generates the dev tile meshes in assets/3d/. Everything lives on a 4-unit
# lattice measured off the dev sheets: slab_n is (n+1)*4 tall, stairs rise
# 4 per 4 of run (6 steps), corner stairs shrink square plates toward the
# apex. All meshes are authored facing "n" (ascending / apex toward -Z,-X)
# and rotated per tile via the "rot" field in tiles.json.

const S = 12.0
const STEP = 4.0

func _initialize() -> void:
	for n in range(1, 5):
		_write("slab_%d" % n, [_box(Vector3(-S, -S, -S), Vector3(S, -S + (n + 1) * STEP, S))])

	var stairs := []
	var corner := []
	for k in 6:
		var y0 = -S + k * STEP
		stairs.append(_box(Vector3(-S, y0, -S), Vector3(S, y0 + STEP, S - k * STEP)))
		corner.append(_box(Vector3(-S, y0, -S), Vector3(S - k * STEP, y0 + STEP, S - k * STEP)))
	_write("stairs", stairs)
	_write("corner_stairs", corner)

	_write_raw("floor", [Vector3(-S, -S, S), Vector3(S, -S, S), Vector3(S, -S, -S), Vector3(-S, -S, -S)], [[1, 2, 3, 4]])

	# Wedge rising to the -Z edge; base corners N,E,S,W then the top edge.
	_write_raw("slope", [
		Vector3(-S, -S, -S), Vector3(S, -S, -S), Vector3(S, -S, S), Vector3(-S, -S, S),
		Vector3(-S, S, -S), Vector3(S, S, -S),
	], [[1, 2, 3, 4], [1, 5, 6, 2], [5, 4, 3, 6], [1, 4, 5], [2, 6, 3]])

	# h = min(12-x, 12-z): apex over the -X,-Z corner, knife edges at +X/+Z.
	_write_raw("corner_slope", [
		Vector3(-S, -S, -S), Vector3(S, -S, -S), Vector3(S, -S, S), Vector3(-S, -S, S),
		Vector3(-S, S, -S),
	], [[1, 2, 3, 4], [1, 5, 2], [1, 4, 5], [5, 3, 2], [5, 4, 3]])
	quit()

# Vertex/quad layout mirrors the hand-made slab_5.obj (outward CCW winding).
func _box(lo: Vector3, hi: Vector3) -> Dictionary:
	var v = [
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z),
	]
	var f = [
		[1, 2, 4, 3], [3, 4, 6, 5], [5, 6, 8, 7],
		[7, 8, 2, 1], [2, 8, 6, 4], [7, 1, 3, 5],
	]
	return {"v": v, "f": f}

func _write(name: String, boxes: Array) -> void:
	var verts := []
	var faces := []
	for box in boxes:
		var base = verts.size()
		verts.append_array(box.v)
		for f in box.f:
			faces.append(f.map(func(i): return i + base))
	_write_raw(name, verts, faces)

func _write_raw(name: String, verts: Array, faces: Array) -> void:
	var lines := ["o %s" % name, ""]
	for v in verts:
		lines.append("v %s %s %s" % [_num(v.x), _num(v.y), _num(v.z)])
	lines.append("")
	for f in faces:
		lines.append("f " + " ".join(f.map(func(i): return str(i))))
	var file = FileAccess.open("res://assets/3d/%s.obj" % name, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	print("wrote %s.obj (%d verts, %d quads)" % [name, verts.size(), faces.size()])

func _num(x: float) -> String:
	return ("%d" % roundi(x)) if is_equal_approx(x, roundf(x)) else ("%f" % x)
