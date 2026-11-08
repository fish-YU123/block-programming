extends Window

## 每种图鉴结构：勾选 3×3×3 点 → 凸包即平滑网格

signal saved

const HullStore = preload("res://scripts/structure_hull_store.gd")
const Hull3D = preload("res://scripts/convex_hull_3d.gd")

var terrain = null
var store: HullStore = HullStore.new()
var _idx := 0
var _selected := {} # Vector3i -> bool
var _title: Label
var _info: Label
var _layer_box: VBoxContainer
var _toggles: Dictionary = {} # Vector3i -> CheckBox
var _preview: MeshInstance3D
var _wire: MeshInstance3D
var _points_mesh: MeshInstance3D
var _pivot: Node3D
var _status: Label
var _built := false
var _orbit_yaw := 0.7
var _orbit_pitch := 0.45
var _dragging := false
var _last_mouse := Vector2.ZERO
var _vp_box: SubViewportContainer


func setup(t) -> void:
	terrain = t
	store.load_all()
	title = "结构平滑（勾选点 → 中心石头凸包）"
	size = Vector2i(780, 660)
	unresizable = false
	if not close_requested.is_connected(hide):
		close_requested.connect(hide)
	if not _built:
		_build_ui()
		_built = true
	_load_index(_idx)


func _build_ui() -> void:
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 10)
	root.add_theme_constant_override("margin_right", 10)
	root.add_theme_constant_override("margin_top", 10)
	root.add_theme_constant_override("margin_bottom", 10)
	add_child(root)
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 12)
	root.add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	split.add_child(left)

	_title = Label.new()
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_title)
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", 12)
	left.add_child(_info)

	var nav := HBoxContainer.new()
	var prev := Button.new()
	prev.text = "上一个"
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(func() -> void: _load_index(_idx - 1))
	var next := Button.new()
	next.text = "下一个"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(func() -> void: _load_index(_idx + 1))
	nav.add_child(prev)
	nav.add_child(next)
	left.add_child(nav)

	var actions := HBoxContainer.new()
	var fill_occ := Button.new()
	fill_occ.text = "勾占用格"
	fill_occ.focus_mode = Control.FOCUS_NONE
	fill_occ.pressed.connect(_select_occupied)
	var clear_btn := Button.new()
	clear_btn.text = "清空"
	clear_btn.focus_mode = Control.FOCUS_NONE
	clear_btn.pressed.connect(_clear_all)
	var save_btn := Button.new()
	save_btn.text = "保存凸包"
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.pressed.connect(_save_current)
	actions.add_child(fill_occ)
	actions.add_child(clear_btn)
	actions.add_child(save_btn)
	left.add_child(actions)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)
	_layer_box = VBoxContainer.new()
	_layer_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layer_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_layer_box)
	_build_toggles()

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var hint := Label.new()
	hint.text = "点落在中心石头上（0/2=面，1=中心）；右侧同图鉴，可拖转"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(hint)
	_vp_box = SubViewportContainer.new()
	_vp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_box.stretch = true
	_vp_box.custom_minimum_size = Vector2(400, 400)
	_vp_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_box.gui_input.connect(_on_preview_input)
	right.add_child(_vp_box)
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(400, 400)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp_box.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 28, 0)
	light.shadow_enabled = false
	world.add_child(light)
	var cam := Camera3D.new()
	cam.name = "Cam"
	world.add_child(cam)
	_pivot = Node3D.new()
	_pivot.position = Vector3(0.75, 0.75, 0.75)
	world.add_child(_pivot)
	var content := Node3D.new()
	content.name = "Content"
	content.position = Vector3(-0.75, -0.75, -0.75)
	_pivot.add_child(content)
	_preview = MeshInstance3D.new()
	content.add_child(_preview)
	_wire = MeshInstance3D.new()
	content.add_child(_wire)
	_points_mesh = MeshInstance3D.new()
	content.add_child(_points_mesh)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.04, 0.04, 0.04)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.82, 0.86)
	e.ambient_light_energy = 0.7
	env.environment = e
	world.add_child(env)
	_update_camera()


func _build_toggles() -> void:
	for y in 3:
		var layer := VBoxContainer.new()
		var lab := Label.new()
		lab.text = "Y = %d（下→上）" % y
		layer.add_child(lab)
		for z in range(2, -1, -1):
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			for x in 3:
				var cell := Vector3i(x, y, z)
				var box := CheckBox.new()
				if cell == Vector3i(1, 1, 1):
					box.text = "石心"
				else:
					box.text = "%d,%d,%d" % [x, y, z]
				box.focus_mode = Control.FOCUS_NONE
				box.toggled.connect(_on_toggle.bind(cell))
				row.add_child(box)
				_toggles[cell] = box
			layer.add_child(row)
		_layer_box.add_child(layer)


func _on_toggle(on: bool, cell: Vector3i) -> void:
	if on:
		_selected[cell] = true
	else:
		_selected.erase(cell)
	_refresh_preview()


func _mask() -> int:
	if terrain == null or terrain._catalog_n <= 0:
		return 0
	return terrain.catalog_mask(clampi(_idx, 0, terrain._catalog_n - 1))


func _load_index(i: int) -> void:
	if terrain == null or terrain._catalog_n <= 0:
		_title.text = "无图鉴"
		return
	_idx = clampi(i, 0, terrain._catalog_n - 1)
	var mask := _mask()
	_title.text = "结构 %d / %d　mask=%d" % [_idx + 1, terrain._catalog_n, mask]
	_info.text = _describe_mask(mask)
	_selected.clear()
	for p in store.get_points(mask):
		if p is Array and p.size() >= 3:
			_selected[Vector3i(int(p[0]), int(p[1]), int(p[2]))] = true
	for cell in _toggles.keys():
		var box: CheckBox = _toggles[cell]
		box.set_pressed_no_signal(_selected.has(cell))
		# 占用格用提示色
		var occ := _is_occupied(mask, cell)
		box.modulate = Color(1.0, 0.85, 0.4) if occ else Color.WHITE
	_refresh_preview()
	_status.text = "已加载；勾选后点「保存凸包」"


func _describe_mask(mask: int) -> String:
	var bits: Array[String] = []
	if terrain == null:
		return ""
	for i in terrain._struct_pos.size():
		if (mask >> i) & 1:
			var p: Vector3i = terrain._struct_pos[i]
			bits.append("结构(%d,%d,%d)" % [p.x, p.y, p.z])
	bits.append("中心石头(1,1,1)←凸包作用对象")
	return "占用：" + ", ".join(bits)


func _is_occupied(mask: int, cell: Vector3i) -> bool:
	if cell == Vector3i(1, 1, 1):
		return true
	if terrain == null:
		return false
	for i in terrain._struct_pos.size():
		var p: Vector3i = terrain._struct_pos[i]
		if p == cell:
			return ((mask >> i) & 1) != 0
	return false


func _select_occupied() -> void:
	var mask := _mask()
	_selected.clear()
	for y in 3:
		for z in 3:
			for x in 3:
				var cell := Vector3i(x, y, z)
				if _is_occupied(mask, cell):
					_selected[cell] = true
	for cell in _toggles.keys():
		(_toggles[cell] as CheckBox).set_pressed_no_signal(_selected.has(cell))
	_refresh_preview()


func _clear_all() -> void:
	_selected.clear()
	for cell in _toggles.keys():
		(_toggles[cell] as CheckBox).set_pressed_no_signal(false)
	_refresh_preview()


func _save_current() -> void:
	var mask := _mask()
	var pts: Array = []
	for cell in _selected.keys():
		var c: Vector3i = cell
		pts.append([c.x, c.y, c.z])
	store.set_points(mask, pts)
	store.save_all()
	if terrain != null and terrain.has_method("reload_structure_hulls"):
		terrain.reload_structure_hulls()
	_status.text = "已保存 mask=%d，共 %d 点" % [mask, pts.size()]
	_refresh_preview()
	saved.emit()


func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_last_mouse = mb.position
			_vp_box.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var d: Vector2 = mm.position - _last_mouse
		_last_mouse = mm.position
		_orbit_yaw -= d.x * 0.01
		_orbit_pitch = clampf(_orbit_pitch - d.y * 0.01, -1.2, 1.2)
		_update_camera()
		_vp_box.accept_event()


func _update_camera() -> void:
	if _pivot == null:
		return
	var world: Node = _pivot.get_parent()
	var cam: Camera3D = world.get_node_or_null("Cam") as Camera3D
	if cam == null:
		return
	var dist := 1.8
	var cp := cos(_orbit_pitch)
	cam.position = _pivot.position + Vector3(
		sin(_orbit_yaw) * cp * dist,
		sin(_orbit_pitch) * dist,
		cos(_orbit_yaw) * cp * dist
	)
	cam.look_at(_pivot.position)


func _stone_cell_center() -> Vector3:
	# 中心石头格 (1,1,1) 的体心，局部坐标
	return Vector3(0.75, 0.75, 0.75)


func _hull_point(cell: Vector3i) -> Vector3:
	# 3×3×3 落在中心石头表面上：0/1/2 → 石块 min/中/max 面（半格 0.5 的角点与面心）
	return Vector3(0.5 + float(cell.x) * 0.25, 0.5 + float(cell.y) * 0.25, 0.5 + float(cell.z) * 0.25)


func _struct_cell_center(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * 0.5, (float(cell.y) + 0.5) * 0.5, (float(cell.z) + 0.5) * 0.5)


func _get_stone_top_side() -> Array:
	var top := Color(0.52, 0.52, 0.53)
	var side := top
	if terrain != null and terrain.db != null:
		var def = terrain.db.get_def(terrain.stone_id)
		top = def.color_top
		side = def.color_side
	return [top, side]


func _refresh_preview() -> void:
	if _preview == null:
		return
	var pts := PackedVector3Array()
	for cell in _selected.keys():
		pts.append(_hull_point(cell))
	var tris: PackedVector3Array = Hull3D.build(pts)
	_preview.mesh = _make_stone_or_hull_mesh(tris)
	_wire.mesh = _make_structure_wires(_mask())
	_points_mesh.mesh = _make_point_markers()
	_status.text = "中心石头凸包：已选 %d 点，三角 %d" % [_selected.size(), tris.size() / 3]


func _make_stone_or_hull_mesh(tris: PackedVector3Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var colors := _get_stone_top_side()
	var top: Color = colors[0]
	var side: Color = colors[1]
	if tris.size() >= 3:
		for i in range(0, tris.size(), 3):
			var a: Vector3 = tris[i]
			var b: Vector3 = tris[i + 1]
			var c: Vector3 = tris[i + 2]
			var n: Vector3 = (b - a).cross(c - a)
			if n.length_squared() < 1e-12:
				continue
			n = n.normalized()
			var up := clampf(n.y, 0.0, 1.0)
			var col: Color = side.lerp(top, smoothstep(0.2, 0.85, up))
			verts.append(a)
			verts.append(b)
			verts.append(c)
			for _k in 3:
				norms.append(n)
				cols.append(col)
	else:
		# 未成凸包时画中间石头方块，与图鉴一致
		_append_solid_cube(verts, norms, cols, _stone_cell_center(), 0.25, top, side)
	if verts.is_empty():
		return mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mesh.surface_set_material(0, mat)
	return mesh


func _append_solid_cube(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, c: Vector3, s: float, top: Color, side: Color) -> void:
	var faces := [
		[Vector3(0, 1, 0), top, Vector3(-s, s, -s), Vector3(s, s, -s), Vector3(s, s, s), Vector3(-s, s, s)],
		[Vector3(0, -1, 0), side, Vector3(-s, -s, s), Vector3(s, -s, s), Vector3(s, -s, -s), Vector3(-s, -s, -s)],
		[Vector3(0, 0, 1), side, Vector3(-s, -s, s), Vector3(-s, s, s), Vector3(s, s, s), Vector3(s, -s, s)],
		[Vector3(0, 0, -1), side, Vector3(s, -s, -s), Vector3(s, s, -s), Vector3(-s, s, -s), Vector3(-s, -s, -s)],
		[Vector3(1, 0, 0), side, Vector3(s, -s, s), Vector3(s, s, s), Vector3(s, s, -s), Vector3(s, -s, -s)],
		[Vector3(-1, 0, 0), side, Vector3(-s, -s, -s), Vector3(-s, s, -s), Vector3(-s, s, s), Vector3(-s, -s, s)],
	]
	for face in faces:
		var n: Vector3 = face[0]
		var col: Color = face[1]
		var a: Vector3 = c + face[2]
		var b: Vector3 = c + face[3]
		var d: Vector3 = c + face[4]
		var e: Vector3 = c + face[5]
		for tri in [[a, b, d], [a, d, e]]:
			verts.append(tri[0])
			verts.append(tri[1])
			verts.append(tri[2])
			for _k in 3:
				norms.append(n)
				cols.append(col)


func _make_structure_wires(mask: int) -> Mesh:
	# 只画结构块线框（不含中心石头），与游戏图鉴一致
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.82, 0.84, 0.92)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var cells: Array[Vector3i] = []
	if terrain != null:
		for i in terrain._struct_pos.size():
			if (mask >> i) & 1:
				cells.append(terrain._struct_pos[i])
	for cell in cells:
		var c := _struct_cell_center(cell)
		var s := 0.25
		var p := [
			c + Vector3(-s, -s, -s), c + Vector3(s, -s, -s), c + Vector3(s, s, -s), c + Vector3(-s, s, -s),
			c + Vector3(-s, -s, s), c + Vector3(s, -s, s), c + Vector3(s, s, s), c + Vector3(-s, s, s),
		]
		var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
		for e in range(0, edges.size(), 2):
			im.surface_add_vertex(p[edges[e]])
			im.surface_add_vertex(p[edges[e + 1]])
	im.surface_end()
	return im


func _make_point_markers() -> Mesh:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.16)
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	for cell in _selected.keys():
		_add_marker_octa(im, _hull_point(cell), 0.022)
	im.surface_end()
	return im


func _add_marker_octa(im: ImmediateMesh, c: Vector3, r: float) -> void:
	var px := c + Vector3(r, 0, 0)
	var nx := c + Vector3(-r, 0, 0)
	var py := c + Vector3(0, r, 0)
	var ny := c + Vector3(0, -r, 0)
	var pz := c + Vector3(0, 0, r)
	var nz := c + Vector3(0, 0, -r)
	var faces := [
		[py, pz, px], [py, px, nz], [py, nz, nx], [py, nx, pz],
		[ny, px, pz], [ny, nz, px], [ny, nx, nz], [ny, pz, nx],
	]
	for f in faces:
		im.surface_add_vertex(f[0])
		im.surface_add_vertex(f[1])
		im.surface_add_vertex(f[2])
