@tool
extends GridMap
class_name IsoGrid

# The grid, the sprite layer, and the tile-type cache the occlusion and keyhole
# systems feed on. See docs/outline_occlusion.md and docs/player_transparency.md.

const LIB_PATH = "res://assets/mesh_lib/tiles.tres"
const OCC_SHADER = preload("res://assets/shaders/occlusion.gdshader")
const INFLATE = 1.02  # occlusion proxy scale, to close raster hairlines

## Tilesheet regions rigged to .obj files (may reference several tilesheets)
@export_file("*.json") var config = "res://tiles.json"

## Rebuild mesh library according to config
@export_tool_button("Rebuild tiles") var _rebuild = rebuild

## Re-scan every occlusion mask from scratch, ignoring the cache
@export_tool_button("Rebake occlusion") var _rebake = rebake

@export_group("Editor aids")
## Snap the editor camera to the orthogonal isometric view, centered on the origin [EDITOR ONLY]
@export_tool_button("Isometric view") var _iso_view = snap_editor_view

## Swap sprites for the raw 3D models, one color per face [EDITOR ONLY]
@export var show_3d = false:
	set(v):
		show_3d = v
		if is_node_ready(): rebuild()

## A white plane at height 0 to build on top of [EDITOR ONLY]
@export var show_floor = true:
	set(v):
		show_floor = v
		if is_node_ready(): _refresh_floor()

## Wireframe cell box on every placed tile for reading geometry [EDITOR ONLY]
@export var show_wireframe = true:
	set(v):
		show_wireframe = v
		if is_node_ready(): _refresh_wire()

var _wire_hash = 0
var _occ_hash = 0
var _zone_hash = 0
var _int_zones := []      # [{inv: Transform3D, ext: Vector3}] interior box zones
var _types := {}          # cell item id -> {mesh, mat, edges, out, present}
var _blank_mask: ImageTexture

# Keyhole fade groups, baked by OccluderGroups whenever the sprites refresh.
var _cell_group := {}     # Vector3i -> group index, -1 when ungrouped
var _cell_shell := {}     # Vector3i -> bool, false for a group's interior cells
var _group_count := 0
var _cell_lo := Vector3i.ZERO
var _cell_hi := Vector3i.ZERO

func _ready() -> void:
	cell_size = Iso.cell()
	set_process(Engine.is_editor_hint())
	_setup()
	_refresh_floor()
	_refresh_wire()

# Runtime-safe refresh: rebuilds the sprite layer without writing to disk.
func _setup() -> void:
	_types = {}
	OcclusionContact.clear()
	if not show_3d: _mute_library()
	_occ_hash = 0
	_refresh_sprites()

# Drop the placed-cell meshes (in memory only) so GridMap draws only collision.
func _mute_library() -> void:
	if mesh_library == null: return
	for id in mesh_library.get_item_list():
		mesh_library.set_item_mesh(id, null)
	var lib = mesh_library
	mesh_library = null
	mesh_library = lib

func _process(_delta: float) -> void:
	var h = get_used_cells().hash()
	if show_wireframe and h != _wire_hash:
		_refresh_wire()
	# Re-sprite when the cells change or an interior zone is moved/resized.
	if not show_3d and (h != _occ_hash or _zones_hash() != _zone_hash):
		_refresh_sprites()

func rebuild() -> void:
	cell_size = Iso.cell()

	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	if data == null:
		push_error("IsoGrid: could not parse %s" % config)
		return

	var paths: Array = data.get("tilesheets", [data.get("tilesheet")])
	var sheets: Array = paths.map(func(p): return load(p) as Texture2D)
	var lib = _fresh_library()

	# GridMap keeps collision + palette preview; placed cells carry a mesh only
	# in the 3D debug view.
	for id in data.tiles.size():
		var tile: Dictionary = data.tiles[id]
		lib.create_item(id)
		lib.set_item_name(id, tile.name)
		lib.set_item_mesh(id, _debug_mesh(tile) if show_3d else null)
		lib.set_item_shapes(id, [_collision(tile), Transform3D.IDENTITY])
		lib.set_item_preview(id, _slice(sheets[tile.get("sheet", 0)], _region(tile)))
	ResourceSaver.save(lib, LIB_PATH)
	mesh_library = lib

	_types = {}
	OcclusionContact.clear()
	_occ_hash = 0
	_refresh_sprites()

# Force a clean occlusion rebake, then rebuild.
func rebake() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	for p in data.get("tilesheets", [data.get("tilesheet")]):
		var cache = "%s/occlusion/%s_o.json" % [p.get_base_dir(), p.get_file().get_basename()]
		if FileAccess.file_exists(cache): DirAccess.remove_absolute(ProjectSettings.globalize_path(cache))
	rebuild()

# Build the render type for each requested tile id into _types, additively:
# rasterizing a mesh and walking its probes is the pipeline's one heavy step.
func _build_types(want: Array) -> void:
	if want.is_empty(): return
	var data = JSON.parse_string(FileAccess.get_file_as_string(config))
	if data == null: return
	var paths: Array = data.get("tilesheets", [data.get("tilesheet")])
	for si in paths.size():
		var ids := want.filter(func(id): return data.tiles[id].get("sheet", 0) == si)
		if ids.is_empty(): continue

		# ensure() validates a whole sheet at once, so hand it every region.
		var all := []
		var pos := {}
		for id in data.tiles.size():
			if data.tiles[id].get("sheet", 0) == si:
				pos[id] = all.size()
				all.append(data.tiles[id].region)
		var baked = OcclusionMaskBaker.ensure(paths[si], all)
		var sheet_img: Image = (load(paths[si]) as Texture2D).get_image()
		var mask_img = _load_mask(paths[si])
		var raw_img = OcclusionMaskBaker.raw_mask(paths[si])
		for id in ids:
			_types[id] = _make_type(
				data.tiles[id], sheet_img, mask_img, raw_img,
				baked[pos[id]] if pos[id] < baked.size() else {})

func _make_type(tile: Dictionary, sheet: Image, mask: Image, raw: Image, baked: Dictionary) -> Dictionary:
	var region = _region(tile)
	var size = Vector2i(region.size)
	var off: Array = tile.get("offset_px", [0, 0])
	var offset = Vector2(off[0], off[1])
	
	var occ_faces = _faces(tile)

	# The solid's cameraward corner, relative to the cell center. X and Z take the
	# bounding box, which the solid really does reach. Y instead takes the height
	# of the vertex nearest the camera: a ramp's bounding-box top floats in the
	# air above its low cameraward end, and testing against it makes the ramp fade
	# while an entity stands at its foot. A cube's nearest vertex is its
	# (max, max, max) corner, so cubes are unaffected. Keyhole input only.
	var view := Iso.facing().z
	var bounds := Vector3.ZERO
	var near_y := 0.0
	var near_depth := -INF
	for i in occ_faces.size():
		var v: Vector3 = occ_faces[i]
		bounds = v if i == 0 else bounds.max(v)
		var depth_v := v.dot(view)
		if depth_v > near_depth:
			near_depth = depth_v
			near_y = v.y
		occ_faces[i] = v * INFLATE  # widen the occlusion proxy a hair
	var near_offset := Vector3(bounds.x, near_y, bounds.z)

	var depth = MeshDepth.rasterize(occ_faces, size, offset)

	var edges: Array = baked.get("edges", _zeros(Vector4.ZERO)).duplicate()
	var out = baked.get("out", _zeros(Vector2.ZERO))
	var present = baked.get("present", 0)
	var region_px = OcclusionMaskBaker.region_pixels(raw if raw else mask, Rect2i(region))

	# One probe [t_lo, t_hi, s.x, s.y, front depth] per distinct silhouette point.
	var probes := []
	for d in 6:
		var e0 = Vector2(edges[d].x, edges[d].y)
		var ev = Vector2(edges[d].z, edges[d].w) - e0
		var groups := {}
		if (present & (1 << d)) != 0 and ev.length_squared() > 1e-6:
			var o: Vector2 = out[d]
			for p in region_px[d]:
				var c = p + Vector2(0.5, 0.5)
				var s = MeshDepth.first_covered(depth, size, c, -o, MeshDepth.MAX_WALK)
				if s == null: continue
				var t = clampf((c / Vector2(size) - e0).dot(ev) / ev.length_squared(), 0.0, 1.0)
				var key = Vector2i(s)
				if groups.has(key):
					groups[key].x = minf(groups[key].x, t)
					groups[key].y = maxf(groups[key].y, t)
				else:
					groups[key] = Vector2(t, t)
		var list = PackedFloat32Array()
		for key in groups:
			list.append_array([groups[key].x, groups[key].y, key.x + 0.5, key.y + 0.5,
				MeshDepth.at(depth, size, Vector2(key) + Vector2(0.5, 0.5)).x])
		probes.append(list)

	var mat = ShaderMaterial.new()
	mat.shader = OCC_SHADER
	mat.set_shader_parameter("albedo_tex", _crop(sheet, region))
	mat.set_shader_parameter("mask_tex", _crop(mask, region) if mask else _fallback_mask())
	mat.set_shader_parameter("edges", edges)

	return {
		"mesh": _quad(tile),
		"mat": mat,
		"edges": edges,
		"out": out,
		"present": present,
		"depth": depth,
		"region_size": size,
		"region_px": region_px,
		"origin": MeshDepth.origin(size, offset),
		"probes": probes,
		"ramp_chain": _ramp_chain(tile),
		"near_offset": near_offset,
	}

# For shader sampling: goes through the resource system, so exports work.
func _load_mask(sheet_path: String) -> Image:
	var p = "%s/occlusion/%s_o.png" % [sheet_path.get_base_dir(), sheet_path.get_file().get_basename()]
	if ResourceLoader.exists(p):
		return (load(p) as Texture2D).get_image()
	return null

func _crop(img: Image, region: Rect2) -> ImageTexture:
	return ImageTexture.create_from_image(img.get_region(Rect2i(region)))

func _fallback_mask() -> ImageTexture:
	if _blank_mask == null:
		var img = Image.create(1, 1, false, Image.FORMAT_RGB8)
		_blank_mask = ImageTexture.create_from_image(img)
	return _blank_mask

func _zeros(v: Variant) -> Array:
	var out := []
	for i in 6: out.append(v)
	return out

# One .obj serves all four cardinal facings: tiles pick one with "rot".
const ROT = {"n": 0.0, "e": -PI / 2, "s": PI, "w": PI / 2}

# Horizontal ascent direction (grid units) of a tile authored facing "n"
# (ascending toward -Z), rotated per "rot" the same way _faces() rotates the mesh.
const RAMP_DIR = {"n": Vector2i(0, -1), "e": Vector2i(1, 0), "s": Vector2i(0, 1), "w": Vector2i(-1, 0)}

# Offset to the cell that continues the same ramp: one along, one up. Corner
# pieces have no single ascent direction and are excluded.
func _ramp_chain(tile: Dictionary) -> Variant:
	var name: String = tile.name
	if not (name.begins_with("stairs_") or name.begins_with("slope_")):
		return null
	var dir: Vector2i = RAMP_DIR[tile.get("rot", "n")]
	return Vector3i(dir.x, 1, dir.y)

# The tile's mesh triangles in cell space, rotated to its facing.
func _faces(tile: Dictionary) -> PackedVector3Array:
	var faces = (load(tile.mesh) as Mesh).get_faces()
	var yaw: float = ROT[tile.get("rot", "n")]
	var basis = Basis(Vector3.UP, yaw) if yaw != 0.0 else Basis()
	var y_scale = Iso.cell().y / Iso.UNIT
	for i in faces.size():
		var v = basis * faces[i]
		v.y *= y_scale
		faces[i] = v
	return faces

# The raw .obj shaded with a flat color per face, for reading geometry.
func _debug_mesh(tile: Dictionary) -> ArrayMesh:
	var faces = _faces(tile)
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var colors := {}
	for i in range(0, faces.size(), 3):
		var normal = (faces[i + 1] - faces[i]).cross(faces[i + 2] - faces[i]).normalized()
		var key = normal.snapped(Vector3.ONE * 0.001)
		if not colors.has(key):
			colors[key] = Color.from_hsv(colors.size() * 0.61803, 0.65, 1.0)
		st.set_color(colors[key])
		for j in range(3):
			st.add_vertex(faces[i + j])
	st.set_material(_debug_material())
	return st.commit()

func _debug_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	return material

# The pixel-perfect billboard quad; its shading comes from the type's material.
func _quad(tile: Dictionary) -> QuadMesh:
	var quad = QuadMesh.new()
	quad.size = _region(tile).size * Iso.PIXEL_SCALE
	var off: Array = tile.get("offset_px", [0, 0])
	quad.center_offset = Vector3(off[0], off[1], 0) * Iso.PIXEL_SCALE
	return quad

# = OCCLUSION LAYER =

# One billboard per used cell, carrying its own contact/keyhole instance params.
func _refresh_sprites() -> void:
	if not is_inside_tree(): return
	var layer = _sprite_layer()
	if show_3d:
		layer.visible = false
		_occ_hash = 0
		return
	layer.visible = true

	var cells = get_used_cells()
	var wanted := {}
	for c in cells: wanted[c] = true
	var existing := {}
	for child in layer.get_children():
		var cell = child.get_meta("cell")
		if wanted.has(cell): existing[cell] = child
		else: child.free()

	# Build only the types actually on the map.
	var missing := {}
	for c in cells:
		var id = get_cell_item(c)
		if id != GridMap.INVALID_CELL_ITEM and not _types.has(id): missing[id] = true
	_build_types(missing.keys())

	_int_zones = InteriorZones.collect(get_tree())
	var occ = OccluderGroups.build(cells, self, OccluderGroups.collect_zones(get_tree()))
	_cell_group = occ.group
	_cell_shell = occ.shell
	_group_count = occ.count
	_cell_lo = occ.lo
	_cell_hi = occ.hi
	for c in cells:
		var type = _types.get(get_cell_item(c))
		if type == null: continue
		var mi: MeshInstance3D = existing.get(c)
		if mi == null:
			mi = MeshInstance3D.new()
			mi.set_meta("cell", c)
			layer.add_child(mi)
			mi.owner = null
		mi.mesh = type.mesh
		mi.material_override = type.mat
		mi.position = map_to_local(c)
		_apply_occlusion(mi, c, type)
	_occ_hash = cells.hash()
	_zone_hash = _zones_hash()

# Detect where the cell touches neighbors, then hand the result to the shader.
func _apply_occlusion(mi: MeshInstance3D, cell: Vector3i, type: Dictionary) -> void:
	var contact = OcclusionContact.resolve(self, cell, _types)
	var s: Array = contact.spans
	mi.set_instance_shader_parameter("neighbors", contact.neighbors)
	mi.set_instance_shader_parameter("range01", Vector4(s[0].x, s[0].y, s[1].x, s[1].y))
	mi.set_instance_shader_parameter("range23", Vector4(s[2].x, s[2].y, s[3].x, s[3].y))
	mi.set_instance_shader_parameter("range45", Vector4(s[4].x, s[4].y, s[5].x, s[5].y))
	# Keyhole input, in world space so it compares against the tracked entity.
	var center := to_global(map_to_local(cell))
	mi.set_instance_shader_parameter("tile_near", center + type.near_offset)
	mi.set_instance_shader_parameter("tile_layer", float(cell.y))
	mi.set_instance_shader_parameter("tile_zones", InteriorZones.mask_at(_int_zones, center))
	# Fade group, and whether this cell is the group's camera-facing shell.
	mi.set_instance_shader_parameter("tile_group", _cell_group.get(cell, -1))
	mi.set_instance_shader_parameter("tile_shell", 1.0 if _cell_shell.get(cell, true) else 0.0)

func _zones_hash() -> int:
	return InteriorZones.hash_of(get_tree())

# = KEYHOLE QUERY API (used by Level._process) =

func group_count() -> int:
	return _group_count

func cell_group(cell: Vector3i) -> int:
	return _cell_group.get(cell, -1)

# The render type of a placed cell, or null when the cell is empty.
func cell_type(cell: Vector3i) -> Variant:
	return _types.get(get_cell_item(cell))

# Inclusive cell-coordinate bounds of everything placed, to bound a ray walk.
func cell_span() -> Array:
	return [_cell_lo, _cell_hi]

func _sprite_layer() -> Node3D:
	var layer = get_node_or_null(^"SpriteLayer") as Node3D
	if layer == null:
		layer = Node3D.new()
		layer.name = "SpriteLayer"
		add_child(layer)
		layer.owner = null
	return layer

# Real collision from .obj, rotated to the tile's facing
func _collision(tile: Dictionary) -> Shape3D:
	var shape = ConcavePolygonShape3D.new()
	shape.set_faces(_faces(tile))
	return shape

# Reuse the resource already on disk so its UID stays stable across rebuilds
# (unless it no longer loads, e.g. it references since-deleted assets).
func _fresh_library() -> MeshLibrary:
	if not ResourceLoader.exists(LIB_PATH):
		return MeshLibrary.new()
	var lib = load(LIB_PATH) as MeshLibrary
	if lib == null:
		return MeshLibrary.new()
	for id in lib.get_item_list():
		lib.remove_item(id)
	return lib

func _slice(sheet: Texture2D, region: Rect2) -> AtlasTexture:
	var atlas = AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = region
	return atlas

func _region(tile: Dictionary) -> Rect2:
	var r: Array = tile.region
	return Rect2(r[0], r[1], r[2], r[3])

# = IN-EDITOR Helpers =

# Switch the editor viewport to orthogonal via its own view menu, then place
# its camera; in ortho the pivot is origin - basis.z * (far - near) / 2.
func snap_editor_view() -> void:
	if not Engine.is_editor_hint():
		return
	var ei = Engine.get_singleton("EditorInterface")
	var vp: SubViewport = ei.get_editor_viewport_3d(0)
	var host = vp.get_parent().get_parent()
	for menu in host.find_children("*", "MenuButton", true, false):
		var popup: PopupMenu = menu.get_popup()
		for i in popup.item_count:
			if popup.get_item_text(i) == "Orthogonal":
				popup.id_pressed.emit(popup.get_item_id(i))
	var cam := vp.get_camera_3d()
	var t = Transform3D(Iso.facing(), Vector3.ZERO)
	t.origin = t.basis.z * (cam.far - cam.near) * 0.5
	cam.global_transform = t

func _refresh_floor() -> void:
	if not Engine.is_editor_hint():
		return
		
	var ground = get_node_or_null(^"BuildFloor")
	
	if not show_floor:
		if ground: ground.free()
		return
	
	if ground:
		return
	
	var mesh = PlaneMesh.new()
	mesh.size = Vector2.ONE * Iso.UNIT * 64.0
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = material
	
	ground = MeshInstance3D.new()
	ground.name = "BuildFloor"
	ground.mesh = mesh
	ground.position.y = -Iso.UNIT * 0.5  # ground under the first layer of cells
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	add_child(ground)

func _refresh_wire() -> void:
	if not Engine.is_editor_hint():
		return
		
	var wire = get_node_or_null(^"WireOverlay") as MeshInstance3D
	if not show_wireframe:
		if wire: wire.free()
		return
	
	if wire == null:
		wire = MeshInstance3D.new()
		wire.name = "WireOverlay"
		add_child(wire)
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	st.set_material(_wire_material())
	
	var half = Iso.cell() * 0.5
	
	for cell in get_used_cells():
		_add_box(st, map_to_local(cell), half)
	
	wire.mesh = st.commit()
	_wire_hash = get_used_cells().hash()

func _wire_material() -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.35, 1.0, 0.55)
	return material

func _add_box(st: SurfaceTool, c: Vector3, h: Vector3) -> void:
	var corners: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				corners.append(c + Vector3(sx * h.x, sy * h.y, sz * h.z))

	# Index order matches the sx,sy,sz loop above (x outermost, z innermost).
	var edges := [
		[0, 1], [2, 3], [4, 5], [6, 7],  # along z
		[0, 2], [1, 3], [4, 6], [5, 7],  # along y
		[0, 4], [1, 5], [2, 6], [3, 7],  # along x
	]
	for e in edges:
		st.add_vertex(corners[e[0]])
		st.add_vertex(corners[e[1]])
