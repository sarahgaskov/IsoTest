@tool
extends RefCounted
class_name InteriorZones

# Designer-drawn box volumes collected from a named node group. The "interior"
# group drives roof removal; OccluderGroups reuses boxes() for the "occluder"
# group. See docs/player_transparency.md.

const MAX_ZONES = 24  # keeps the bitmask exact through an RGBAF texel

# Every BoxShape3D volume of a node group, in scene-tree order.
# -> [{inv: Transform3D, ext: Vector3}]
static func boxes(tree: SceneTree, group: StringName, limit: int) -> Array:
	var out := []
	if tree == null: return out
	for node in tree.get_nodes_in_group(group):
		if out.size() >= limit: break
		var cs := _box(node)
		if cs == null: continue
		out.append({
			"inv": cs.global_transform.affine_inverse(),
			"ext": (cs.shape as BoxShape3D).size * 0.5,
		})
	return out

# The interior zones, in bit order.
static func collect(tree: SceneTree) -> Array:
	return boxes(tree, &"interior", MAX_ZONES)

static func contains(zone: Dictionary, p: Vector3) -> bool:
	var lp: Vector3 = zone.inv * p
	var e: Vector3 = zone.ext
	return absf(lp.x) <= e.x and absf(lp.y) <= e.y and absf(lp.z) <= e.z

# Bitmask of the zones (from collect()) that contain the point.
static func mask_at(zones: Array, p: Vector3) -> int:
	var mask := 0
	for i in zones.size():
		if contains(zones[i], p):
			mask |= 1 << i
	return mask

# Hash of every box's transform + size across both groups, so editor edits
# trigger a re-sprite.
static func hash_of(tree: SceneTree) -> int:
	if tree == null: return 0
	var acc := []
	for group in [&"interior", &"occluder"]:
		for node in tree.get_nodes_in_group(group):
			var cs := _box(node)
			if cs == null: continue
			acc.append(cs.global_transform)
			acc.append((cs.shape as BoxShape3D).size)
	return acc.hash()

# The BoxShape3D CollisionShape3D of a marker node (itself or a child), or null.
static func _box(node: Node) -> CollisionShape3D:
	if node is CollisionShape3D and node.shape is BoxShape3D:
		return node
	for child in node.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			return child
	return null
