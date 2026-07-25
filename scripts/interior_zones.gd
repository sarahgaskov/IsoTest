@tool
extends RefCounted
class_name InteriorZones

# Designer-drawn interior volumes: any node in the "interior" group carrying a
# BoxShape3D. See docs/player_transparency.md.

const MAX_ZONES = 24  # keeps the bitmask exact through an RGBAF texel

# -> [{inv: Transform3D, ext: Vector3}] one per zone, in bit order.
static func collect(tree: SceneTree) -> Array:
	var out := []
	if tree == null: return out
	for node in tree.get_nodes_in_group(&"interior"):
		if out.size() >= MAX_ZONES: break
		var cs := _box(node)
		if cs == null: continue
		out.append({
			"inv": cs.global_transform.affine_inverse(),
			"ext": (cs.shape as BoxShape3D).size * 0.5,
		})
	return out

# Bitmask of the zones (from collect()) that contain the point.
static func mask_at(zones: Array, p: Vector3) -> int:
	var mask := 0
	for i in zones.size():
		var z = zones[i]
		var lp: Vector3 = z.inv * p
		var e: Vector3 = z.ext
		if absf(lp.x) <= e.x and absf(lp.y) <= e.y and absf(lp.z) <= e.z:
			mask |= 1 << i
	return mask

# Hash of every zone's transform + size, so editor edits trigger a re-sprite.
static func hash_of(tree: SceneTree) -> int:
	if tree == null: return 0
	var acc := []
	for node in tree.get_nodes_in_group(&"interior"):
		var cs := _box(node)
		if cs == null: continue
		acc.append(cs.global_transform)
		acc.append((cs.shape as BoxShape3D).size)
	return acc.hash()

# The BoxShape3D CollisionShape3D of an interior node (itself or a child), or null.
static func _box(node: Node) -> CollisionShape3D:
	if node is CollisionShape3D and node.shape is BoxShape3D:
		return node
	for child in node.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			return child
	return null
