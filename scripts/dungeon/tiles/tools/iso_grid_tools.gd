@tool
extends RefCounted
class_name IsoGridTools

# === EDITOR TOOLS ===

# Switch the editor viewport to orthogonal and park its camera at the game's isometric angle.
static func snap_view() -> void:
	if not Engine.is_editor_hint(): return
	var vp: SubViewport = Engine.get_singleton("EditorInterface").get_editor_viewport_3d(0)
	# There is no API for the projection mode, so find the menu item and fire it.
	for menu in vp.get_parent().get_parent().find_children("*", "MenuButton", true, false):
		var popup: PopupMenu = menu.get_popup()
		for i in popup.item_count:
			if popup.get_item_text(i) == "Orthogonal":
				popup.id_pressed.emit(popup.get_item_id(i))
	var cam = vp.get_camera_3d()
	var t = Transform3D(IsoView.camera_basis(), Vector3.ZERO)
	# Pull back along the view axis so the whole depth range is in front of us.
	t.origin = t.basis.z * (cam.far - cam.near) * 0.5
	cam.global_transform = t

# === LIBRARY TOOLS ===

static func _load_lib(layer: int) -> MeshLibrary:
	if not ResourceLoader.exists(IsoGrid.LIB_PATH % layer): return null
	return load(IsoGrid.LIB_PATH % layer) as MeshLibrary

# Reuse the .tres files already on disk so their UIDs survive and scenes keep working.
static func _fresh_libraries(data: Dictionary, overlays: Array) -> Array:
	var count = overlays.size() + 1
	
	for sheet in data.tilesheets:
		count = maxi(count, int(sheet.get("layer", 0)) + 1)
	
	var out = []
	
	for i in count:
		var lib = _load_lib(i)
		if lib == null: lib = MeshLibrary.new()
		for id in lib.get_item_list(): lib.remove_item(id)
		out.append(lib)
	return out
