extends Node3D

const UnitDB = preload("res://scripts/unit_db.gd")

signal status_changed(text: String)
signal hold_changed(holding: bool)

const SNAP_DISTANCE := 1.3

class Piece:
	var id: String
	var position: Vector3
	var basis: Basis
	var parent: int
	var joint_pos: Vector3
	var joint_axis: Vector3
	var control_order := 0
	var pad_on := true
	var pad_mode := "out"


var db: UnitDB
var pieces: Array[Piece] = []
var blueprint_code := ""
var tool_mode := 0

var _camera: Camera3D
var _parts_root: Node3D
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _holding := ""
var _user_basis := Basis.IDENTITY
var _snapped := false
var _snap_parent := -1
var _snap_pos := Vector3.ZERO
var _snap_axis := Vector3.ZERO
var _mouse := Vector2(-1, -1)
var _mouse_inside := false
var _moving_index := -1
var _saved_pos := Vector3.ZERO
var _saved_basis := Basis.IDENTITY
var _saved_parent := -1
var _saved_joint_pos := Vector3.ZERO
var _saved_joint_axis := Vector3.UP
var _detached: Array[int] = []
var _orbit_yaw := 0.71
var _orbit_pitch := 0.47
var _orbit_dist := 6.2
var _focus := Vector3.ZERO


func setup(unit_db: UnitDB) -> void:
	db = unit_db
	_build_room()


func is_holding() -> bool:
	return _holding != ""


func held_id() -> String:
	return _holding


func hold(part_id: String) -> void:
	if _moving_index >= 0:
		_restore_move()
	_holding = part_id
	_user_basis = Basis.IDENTITY
	_snapped = false
	_rebuild_ghost()
	hold_changed.emit(true)
	_emit_status()


func cancel_hold() -> void:
	if _holding == "" and _moving_index < 0:
		return
	_restore_move()
	_holding = ""
	_snapped = false
	if _ghost != null:
		_ghost.visible = false
	_rebuild_visuals()
	hold_changed.emit(false)
	_emit_status()


func clear_pieces() -> void:
	_moving_index = -1
	_detached.clear()
	_holding = ""
	_snapped = false
	if _ghost != null:
		_ghost.visible = false
	pieces.clear()
	blueprint_code = ""
	_rebuild_visuals()
	hold_changed.emit(false)
	_emit_status()


func park_move() -> void:
	if _moving_index < 0:
		return
	_restore_move()
	_holding = ""
	_snapped = false
	if _ghost != null:
		_ghost.visible = false
	_rebuild_visuals()
	hold_changed.emit(false)
	_emit_status()


func blueprint_data() -> Dictionary:
	var list: Array = []
	for piece in pieces:
		var orient := piece.basis
		list.append({
			"id": piece.id,
			"position": [piece.position.x, piece.position.y, piece.position.z],
			"basis": [orient.x.x, orient.x.y, orient.x.z, orient.y.x, orient.y.y, orient.y.z, orient.z.x, orient.z.y, orient.z.z],
			"parent": piece.parent,
			"joint_pos": [piece.joint_pos.x, piece.joint_pos.y, piece.joint_pos.z],
			"joint_axis": [piece.joint_axis.x, piece.joint_axis.y, piece.joint_axis.z],
			"control_order": piece.control_order,
			"pad_on": piece.pad_on,
			"pad_mode": piece.pad_mode,
		})
	return {"kind": "unit_blueprint", "pieces": list, "code": blueprint_code}


func load_blueprint(data: Dictionary) -> String:
	if str(data.get("kind", "")) != "unit_blueprint":
		return "这个文件不是单位蓝图。"
	var raw = data.get("pieces", [])
	if not (raw is Array) or raw.is_empty():
		return "蓝图里没有零件。"
	var built: Array[Piece] = []
	var parents: Array[int] = []
	for item in raw:
		if not (item is Dictionary):
			return "蓝图里有坏掉的零件。"
		var row: Dictionary = item
		var part_id := str(row.get("id", ""))
		if not db.has_part(part_id):
			return "没有零件 %s。" % part_id
		var numbers = row.get("basis", [])
		if not (numbers is Array) or numbers.size() < 9:
			return "零件 %s 的朝向坏了。" % part_id
		var piece := Piece.new()
		piece.id = part_id
		piece.position = _read_vec3(row.get("position", []), Vector3.ZERO)
		piece.basis = Basis(
			Vector3(float(numbers[0]), float(numbers[1]), float(numbers[2])),
			Vector3(float(numbers[3]), float(numbers[4]), float(numbers[5])),
			Vector3(float(numbers[6]), float(numbers[7]), float(numbers[8]))
		).orthonormalized()
		piece.joint_pos = _read_vec3(row.get("joint_pos", []), Vector3.ZERO)
		piece.joint_axis = _read_vec3(row.get("joint_axis", []), Vector3.UP)
		piece.control_order = int(row.get("control_order", 0))
		piece.pad_on = bool(row.get("pad_on", true))
		var pad_mode := str(row.get("pad_mode", "out"))
		piece.pad_mode = pad_mode if pad_mode == "in" or pad_mode == "out" or pad_mode == "off" else "out"
		var parent := int(row.get("parent", -1))
		if parent < -1 or parent >= raw.size():
			return "零件 %s 的连接坏了。" % part_id
		piece.parent = parent
		parents.append(parent)
		built.append(piece)
	for i in parents.size():
		var seen := {}
		var cursor := parents[i]
		var guard := 0
		while cursor >= 0:
			if cursor == i or seen.has(cursor):
				return "蓝图里的连接绕成了圈。"
			seen[cursor] = true
			cursor = parents[cursor]
			guard += 1
			if guard > parents.size():
				return "蓝图里的连接绕成了圈。"
	_moving_index = -1
	_detached.clear()
	_holding = ""
	_snapped = false
	if _ghost != null:
		_ghost.visible = false
	var code = data.get("code", "")
	blueprint_code = code if code is String else ""
	pieces = built
	_compact_links()
	_rebuild_visuals()
	hold_changed.emit(false)
	return ""


func _read_vec3(value, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


func rotate_axis(axis: Vector3, turns: int) -> void:
	if _holding == "":
		return
	var step := Basis(axis.normalized(), deg_to_rad(90.0 * float(turns)))
	_user_basis = (step * _user_basis).orthonormalized()


func set_pointer(screen_pos: Vector2, inside: bool) -> void:
	_mouse = screen_pos
	_mouse_inside = inside


func set_tool_mode(mode: int) -> void:
	tool_mode = posmod(mode, 3)
	_rebuild_visuals()
	_emit_status()


func on_left_click() -> void:
	if not _mouse_inside:
		return
	if tool_mode != 0 and _holding == "":
		var linked := _ray_piece(_mouse)
		if linked < 0:
			return
		if tool_mode == 1:
			_cycle_pad(linked)
		else:
			_toggle_link(linked)
		_rebuild_visuals()
		return
	if _holding != "":
		try_place()
		return
	var hit := _ray_piece(_mouse)
	if hit >= 0:
		_begin_move(hit)


func try_place() -> void:
	if _holding == "" or not _mouse_inside:
		return
	_update_ghost()
	var alone := _other_count() == 0
	if alone:
		var free_pos := _rounded(_free_position())
		if _overlaps_any(free_pos, _user_basis, db.get_part(_holding).size, _moving_index):
			return
		_commit(free_pos, _user_basis, -1, Vector3.ZERO, Vector3.UP)
		return
	if not _snapped:
		return
	if _overlaps_any(_ghost.position, _ghost.basis, db.get_part(_holding).size, _moving_index):
		return
	_commit(_ghost.position, _ghost.basis, _snap_parent, _snap_pos, _snap_axis)


func try_remove() -> void:
	if _holding != "" or not _mouse_inside or _camera == null:
		return
	var hit := _ray_piece(_mouse)
	if hit < 0:
		return
	_remove_branch(hit)
	_rebuild_visuals()
	_emit_status()


func orbit(relative: Vector2) -> void:
	if _camera == null:
		return
	_orbit_yaw -= relative.x * 0.008
	_orbit_pitch = clampf(_orbit_pitch + relative.y * 0.008, -1.15, 1.15)
	_apply_camera()


func pan(relative: Vector2) -> void:
	if _camera == null:
		return
	var right := _camera.basis.x
	right.y = 0.0
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var forward := -_camera.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var speed := 0.012 * _orbit_dist
	_focus += right * relative.x * speed - forward * relative.y * speed
	_apply_camera()


func add_fov(amount: float) -> void:
	if _camera == null:
		return
	_camera.fov = clampf(_camera.fov + amount, 20.0, 110.0)


func _other_count() -> int:
	var count := 0
	for i in pieces.size():
		if i != _moving_index:
			count += 1
	return count


func _commit(pos: Vector3, part_basis: Basis, parent: int, joint_pos: Vector3, joint_axis: Vector3) -> void:
	if _moving_index >= 0:
		var moved: Piece = pieces[_moving_index]
		moved.position = pos
		moved.basis = part_basis
		moved.parent = parent
		moved.joint_pos = joint_pos
		moved.joint_axis = joint_axis
		_moving_index = -1
		_detached.clear()
	else:
		var placed := Piece.new()
		placed.id = _holding
		placed.position = pos
		placed.basis = part_basis
		placed.parent = parent
		placed.joint_pos = joint_pos
		placed.joint_axis = joint_axis
		pieces.append(placed)
	_holding = ""
	_snapped = false
	if _ghost != null:
		_ghost.visible = false
	_rebuild_visuals()
	hold_changed.emit(false)
	_emit_status()


func _begin_move(index: int) -> void:
	var piece: Piece = pieces[index]
	_moving_index = index
	_holding = piece.id
	_user_basis = piece.basis
	_saved_pos = piece.position
	_saved_basis = piece.basis
	_saved_parent = piece.parent
	_saved_joint_pos = piece.joint_pos
	_saved_joint_axis = piece.joint_axis
	_detached.clear()
	for i in pieces.size():
		if i != index and pieces[i].parent == index:
			_detached.append(i)
			pieces[i].parent = -1
	_snapped = false
	_rebuild_ghost()
	_rebuild_visuals()
	hold_changed.emit(true)
	_emit_status()


func _restore_move() -> void:
	if _moving_index < 0 or _moving_index >= pieces.size():
		_moving_index = -1
		_detached.clear()
		return
	var piece: Piece = pieces[_moving_index]
	piece.position = _saved_pos
	piece.basis = _saved_basis
	piece.parent = _saved_parent
	piece.joint_pos = _saved_joint_pos
	piece.joint_axis = _saved_joint_axis
	for child_index in _detached:
		if child_index >= 0 and child_index < pieces.size():
			pieces[child_index].parent = _moving_index
	_detached.clear()
	_moving_index = -1


func _apply_camera() -> void:
	if _camera == null:
		return
	var flat := cos(_orbit_pitch)
	var offset := Vector3(sin(_orbit_yaw) * flat, sin(_orbit_pitch), cos(_orbit_yaw) * flat) * _orbit_dist
	_camera.position = _focus + offset
	_camera.look_at_from_position(_camera.position, _focus)


func _process(_delta: float) -> void:
	if _holding == "":
		return
	_update_ghost()


func _build_room() -> void:
	var env := WorldEnvironment.new()
	var world_env := Environment.new()
	world_env.background_mode = Environment.BG_COLOR
	world_env.background_color = Color(0, 0, 0)
	world_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world_env.ambient_light_color = Color(0.72, 0.76, 0.82)
	world_env.ambient_light_energy = 0.6
	env.environment = world_env
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 32, 0)
	sun.light_energy = 1.35
	sun.shadow_enabled = false
	add_child(sun)

	_camera = Camera3D.new()
	_camera.fov = 42.0
	_camera.current = true
	add_child(_camera)
	_apply_camera()

	_add_grid()
	_add_gizmo()
	_parts_root = Node3D.new()
	_parts_root.name = "Parts"
	add_child(_parts_root)
	_ghost = MeshInstance3D.new()
	_ghost.visible = false
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)


func _add_grid() -> void:
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.22, 0.22, 0.22)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(-16, 17):
		var p := float(i) * 0.5
		mesh.surface_add_vertex(Vector3(p, 0, -8))
		mesh.surface_add_vertex(Vector3(p, 0, 8))
		mesh.surface_add_vertex(Vector3(-8, 0, p))
		mesh.surface_add_vertex(Vector3(8, 0, p))
	mesh.surface_end()
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)


func _add_gizmo() -> void:
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	mesh.surface_set_color(Color(0.9, 0.25, 0.22))
	mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_add_vertex(Vector3(0.9, 0, 0))
	mesh.surface_set_color(Color(0.3, 0.85, 0.35))
	mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_add_vertex(Vector3(0, 0.9, 0))
	mesh.surface_set_color(Color(0.3, 0.45, 0.95))
	mesh.surface_add_vertex(Vector3.ZERO)
	mesh.surface_add_vertex(Vector3(0, 0, 0.9))
	mesh.surface_end()
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)


func _rebuild_ghost() -> void:
	if _ghost == null or _holding == "":
		return
	var def := db.get_part(_holding)
	_ghost.mesh = db.make_mesh(def)
	_ghost_mat = db.make_material(def.color, 0.55)
	_ghost.material_override = _ghost_mat
	_ghost.visible = true
	_clear_children(_ghost)
	_add_sockets(_ghost, def)


func _rebuild_visuals() -> void:
	if _parts_root == null:
		return
	for child in _parts_root.get_children():
		child.free()
	for i in pieces.size():
		if i == _moving_index:
			continue
		var piece: Piece = pieces[i]
		var def := db.get_part(piece.id)
		var inst := MeshInstance3D.new()
		inst.mesh = db.make_mesh(def)
		if piece.id == "wireless_pad":
			inst.material_override = db.make_material(_pad_color(piece), 1.0)
		else:
			inst.material_override = db.make_material(def.color, 1.0)
		inst.position = piece.position
		inst.basis = piece.basis
		_parts_root.add_child(inst)
		_add_sockets(inst, def)
		var mark := _piece_mark(piece)
		if mark != "":
			var label := Label3D.new()
			label.text = mark
			label.font = _mark_font()
			label.font_size = 48
			label.pixel_size = 0.0012
			label.outline_size = 8
			label.modulate = Color(1.0, 0.92, 0.35)
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.position = piece.position + Vector3(0, def.size.y * 0.5 + 0.08, 0)
			_parts_root.add_child(label)


func _add_sockets(host: Node3D, def: UnitDB.PartDef) -> void:
	for sock in def.connections:
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.035
		sphere.height = 0.07
		marker.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.55, 0.16)
		marker.material_override = mat
		marker.position = sock.pos
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host.add_child(marker)


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		child.free()


func _update_ghost() -> void:
	if _ghost == null or _holding == "" or _camera == null:
		return
	var def := db.get_part(_holding)
	_snapped = false
	var free_pos := _free_position()
	var best_dist := SNAP_DISTANCE
	var best_pos := free_pos
	var best_basis := _user_basis
	var best_parent := -1
	var best_joint := Vector3.ZERO
	var best_axis := Vector3.UP
	for i in pieces.size():
		if i == _moving_index:
			continue
		var host: Piece = pieces[i]
		var host_def := db.get_part(host.id)
		for host_sock in host_def.connections:
			var host_pos: Vector3 = host.position + host.basis * host_sock.pos
			var host_n: Vector3 = (host.basis * host_sock.normal).normalized()
			for ghost_sock in def.connections:
				var ghost_n: Vector3 = (_user_basis * ghost_sock.normal).normalized()
				if ghost_n.dot(host_n) > -0.99:
					continue
				var origin: Vector3 = host_pos - _user_basis * ghost_sock.pos
				if _overlaps_any(origin, _user_basis, def.size, _moving_index):
					continue
				var dist := origin.distance_to(free_pos)
				if dist < best_dist:
					best_dist = dist
					best_pos = origin
					best_basis = _user_basis
					best_parent = i
					best_joint = host_pos
					best_axis = host_n
					_snapped = true
	if _snapped:
		_ghost.position = best_pos
		_ghost.basis = best_basis
		_snap_parent = best_parent
		_snap_pos = best_joint
		_snap_axis = best_axis
		_ghost_mat.albedo_color = Color(0.45, 0.95, 0.55, 0.62)
	else:
		_ghost.position = free_pos
		_ghost.basis = _user_basis
		_ghost_mat.albedo_color = Color(def.color.r, def.color.g, def.color.b, 0.5)
	_emit_status()


func _free_position() -> Vector3:
	if _camera == null or not _mouse_inside:
		return _ghost.position if _ghost != null else Vector3.ZERO
	var origin := _camera.project_ray_origin(_mouse)
	var dir := _camera.project_ray_normal(_mouse)
	var focus := _centroid()
	var plane_n := (-_camera.global_basis.z).normalized()
	var denom := plane_n.dot(dir)
	if absf(denom) < 0.0001:
		return focus
	var t := plane_n.dot(focus - origin) / denom
	if t < 0.0:
		return focus
	var hit := origin + dir * t
	var offset := hit - focus
	if offset.length() > 10.0:
		hit = focus + offset.normalized() * 10.0
	return hit


func _centroid() -> Vector3:
	if pieces.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for piece in pieces:
		sum += piece.position
	return sum / float(pieces.size())


func _rounded(v: Vector3) -> Vector3:
	return Vector3(round(v.x * 2.0) / 2.0, round(v.y * 2.0) / 2.0, round(v.z * 2.0) / 2.0)


func _overlaps_any(pos: Vector3, basis: Basis, size: Vector3, ignore: int) -> bool:
	var shrunk := size * 0.96
	for i in pieces.size():
		if i == ignore or i == _moving_index:
			continue
		var other: Piece = pieces[i]
		var other_size: Vector3 = db.get_part(other.id).size * 0.96
		if _obb_hit(pos, basis, shrunk, other.position, other.basis, other_size):
			return true
	return false


func _obb_hit(pa: Vector3, ba: Basis, sa: Vector3, pb: Vector3, bb: Basis, sb: Vector3) -> bool:
	var ax: Array[Vector3] = [ba.x.normalized(), ba.y.normalized(), ba.z.normalized()]
	var bx: Array[Vector3] = [bb.x.normalized(), bb.y.normalized(), bb.z.normalized()]
	var axes: Array[Vector3] = []
	for a in ax:
		axes.append(a)
	for b in bx:
		axes.append(b)
	for a in ax:
		for b in bx:
			var cross: Vector3 = a.cross(b)
			if cross.length_squared() > 0.000001:
				axes.append(cross.normalized())
	var ha := sa * 0.5
	var hb := sb * 0.5
	var delta := pb - pa
	for axis in axes:
		var ra := ha.x * absf(ax[0].dot(axis)) + ha.y * absf(ax[1].dot(axis)) + ha.z * absf(ax[2].dot(axis))
		var rb := hb.x * absf(bx[0].dot(axis)) + hb.y * absf(bx[1].dot(axis)) + hb.z * absf(bx[2].dot(axis))
		if absf(delta.dot(axis)) > ra + rb:
			return false
	return true


func _ray_piece(screen: Vector2) -> int:
	var origin := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	var best := -1
	var best_t := 100000.0
	for i in pieces.size():
		if i == _moving_index:
			continue
		var piece: Piece = pieces[i]
		var t := _ray_obb(origin, dir, piece.position, piece.basis, db.get_part(piece.id).size)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = i
	return best


func _ray_obb(origin: Vector3, dir: Vector3, pos: Vector3, basis: Basis, size: Vector3) -> float:
	var local_o: Vector3 = basis.inverse() * (origin - pos)
	var local_d: Vector3 = basis.inverse() * dir
	var half := size * 0.5
	var tmin := 0.0
	var tmax := 100000.0
	var o := PackedFloat32Array([local_o.x, local_o.y, local_o.z])
	var d := PackedFloat32Array([local_d.x, local_d.y, local_d.z])
	var h := PackedFloat32Array([half.x, half.y, half.z])
	for a in 3:
		if absf(d[a]) < 0.00001:
			if o[a] < -h[a] or o[a] > h[a]:
				return -1.0
			continue
		var t1: float = (-h[a] - o[a]) / d[a]
		var t2: float = (h[a] - o[a]) / d[a]
		if t1 > t2:
			var swap: float = t1
			t1 = t2
			t2 = swap
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0
	if tmax < 0.0:
		return -1.0
	if tmin >= 0.0:
		return tmin
	return tmax


func _remove_branch(index: int) -> void:
	var drop := {}
	drop[index] = true
	var changed := true
	while changed:
		changed = false
		for i in pieces.size():
			if drop.has(i):
				continue
			var parent := pieces[i].parent
			if parent >= 0 and drop.has(parent):
				drop[i] = true
				changed = true
	var kept: Array[Piece] = []
	var remap := {}
	for i in pieces.size():
		if drop.has(i):
			continue
		remap[i] = kept.size()
		kept.append(pieces[i])
	for piece in kept:
		if piece.parent >= 0:
			piece.parent = int(remap[piece.parent])
	pieces = kept
	_compact_links()


func _emit_status() -> void:
	if _holding == "":
		if tool_mode == 1:
			status_changed.emit("连电：点无线充电片切换 输出、输入、关闭。")
		elif tool_mode == 2:
			status_changed.emit("连控制：点轮子、螺旋桨或充电片编号。再点一次取消，后面的号会前移。")
		else:
			status_changed.emit("右侧点一次拿起零件。点道场里的方块可挪走。右键拖动转视角，滚轮调视野。")
		return
	var def := db.get_part(_holding)
	if _other_count() == 0:
		status_changed.emit("拿着%s。左键放下，WASD QE 旋转，Esc 取消。" % def.display_name)
	elif _snapped:
		status_changed.emit("已沿当前朝向吸上。左键放下%s。" % def.display_name)
	else:
		status_changed.emit("拿着%s。只吸附正对的连接点，不会自动转。" % def.display_name)


func _link_kind(part_id: String) -> String:
	if part_id == "wheel":
		return "wheel"
	if part_id == "propeller":
		return "propeller"
	if part_id == "wireless_pad":
		return "pad"
	return ""


func _compact_links() -> void:
	var ranked: Array[Piece] = []
	for piece in pieces:
		if piece.control_order > 0 and _link_kind(piece.id) != "":
			ranked.append(piece)
		else:
			piece.control_order = 0
	ranked.sort_custom(func(a: Piece, b: Piece): return a.control_order < b.control_order)
	for i in ranked.size():
		ranked[i].control_order = i + 1


func _toggle_link(index: int) -> void:
	var piece: Piece = pieces[index]
	if _link_kind(piece.id) == "":
		status_changed.emit("梁、电池和传感器不用连控制。")
		return
	if piece.control_order > 0:
		piece.control_order = 0
	else:
		var top := 0
		for other in pieces:
			top = maxi(top, other.control_order)
		piece.control_order = top + 1
	_compact_links()
	status_changed.emit("已连接 %d 个零件。" % _linked_count())


func _cycle_pad(index: int) -> void:
	var piece: Piece = pieces[index]
	if piece.id != "wireless_pad":
		status_changed.emit("连电只对无线充电片。")
		return
	if piece.pad_on and piece.pad_mode == "out":
		piece.pad_mode = "in"
		piece.pad_on = true
	elif piece.pad_on and piece.pad_mode == "in":
		piece.pad_mode = "off"
		piece.pad_on = false
	else:
		piece.pad_mode = "out"
		piece.pad_on = true
	status_changed.emit("充电片：%s" % _pad_word(piece))


func _linked_count() -> int:
	var count := 0
	for piece in pieces:
		if piece.control_order > 0:
			count += 1
	return count


func _piece_mark(piece: Piece) -> String:
	if tool_mode == 1 and piece.id == "wireless_pad":
		return _pad_word(piece)
	if tool_mode == 2:
		var kind := _link_kind(piece.id)
		if kind == "":
			return ""
		if piece.control_order <= 0:
			return "+"
		return _link_label(piece)
	return ""


func _link_label(piece: Piece) -> String:
	var kind := _link_kind(piece.id)
	var count := 0
	for other in pieces:
		if _link_kind(other.id) != kind or other.control_order <= 0:
			continue
		if other.control_order <= piece.control_order:
			count += 1
	var prefix := "wheel"
	if kind == "propeller":
		prefix = "propeller"
	elif kind == "pad":
		prefix = "pad"
	return "%s%d" % [prefix, count]


func _pad_word(piece: Piece) -> String:
	if not piece.pad_on or piece.pad_mode == "off":
		return "关闭"
	if piece.pad_mode == "in":
		return "输入"
	return "输出"


func _pad_color(piece: Piece) -> Color:
	if not piece.pad_on or piece.pad_mode == "off":
		return Color(0.22, 0.24, 0.28)
	if piece.pad_mode == "in":
		return Color(0.95, 0.62, 0.18)
	return Color(0.15, 0.78, 0.86)


func _mark_font() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Hiragino Sans GB", "Heiti SC"])
	return font
