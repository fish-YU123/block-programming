extends RefCounted

const UnitDB = preload("res://scripts/unit_db.gd")
const Yard = preload("res://scripts/assembly_yard.gd")
const Deployed = preload("res://scripts/deployed_unit.gd")


static func spawn(host: Node, terrain, player: Node3D, yard: Yard, db: UnitDB, outline: Material) -> Deployed:
	if yard.pieces.is_empty():
		return null
	var root := Deployed.new()
	root.name = "单位"
	root.add_to_group("deployed_unit")
	host.add_child(root)

	var centroid := Vector3.ZERO
	var min_bottom := 100000.0
	for piece in yard.pieces:
		centroid += piece.position
		var def := db.get_part(piece.id)
		var half: Vector3 = def.size * 0.5
		var extent_y := absf(piece.basis.x.y) * half.x + absf(piece.basis.y.y) * half.y + absf(piece.basis.z.y) * half.z
		min_bottom = minf(min_bottom, piece.position.y - extent_y)
	centroid /= float(yard.pieces.size())

	var camera := player.get_node("Camera3D") as Camera3D
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3(0, 0, -1)
	forward = forward.normalized()
	var spot := player.global_position + forward * 8.0
	var ground := float(terrain.surface_at_world(spot.x, spot.z))
	root.position = Vector3(spot.x - centroid.x, ground + 1.6 - min_bottom, spot.z - centroid.z)

	var bodies: Array[RigidBody3D] = []
	var centers: Array[RigidBody3D] = []
	var gps_bodies: Array[RigidBody3D] = []
	var angle_bodies: Array[RigidBody3D] = []
	var linear_bodies: Array[RigidBody3D] = []
	var prop_bodies: Array[RigidBody3D] = []
	var prop_limits: Array[float] = []
	var prop_powers: Array[float] = []
	var hinges: Array[HingeJoint3D] = []
	var steer_hinges: Array[Generic6DOFJoint3D] = []
	var wheel_powers: Array[float] = []
	var wheel_bodies: Array[RigidBody3D] = []
	var hubs: Array[RigidBody3D] = []
	var pad_bodies: Array[RigidBody3D] = []
	var pad_on: Array[bool] = []
	var pad_mode: Array[String] = []
	var stored := 0.0
	var passive := 0.0
	var wheel_draw := 0.0
	for piece in yard.pieces:
		var def := db.get_part(piece.id)
		stored += def.energy_j
		if def.wheel:
			wheel_draw += def.power_w
		elif not def.propeller:
			passive += def.power_w
		var body := RigidBody3D.new()
		body.mass = def.mass
		body.position = piece.position
		body.basis = piece.basis
		body.collision_layer = 2
		body.collision_mask = 3
		body.continuous_cd = true
		body.can_sleep = false
		body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		body.freeze = true
		var phys := PhysicsMaterial.new()
		phys.bounce = 0.02
		phys.friction = def.friction
		phys.rough = true
		body.physics_material_override = phys
		body.angular_damp = 0.08 if def.wheel else 0.35
		body.linear_damp = 0.05
		db.add_body_shapes(body, def)
		var mesh := MeshInstance3D.new()
		mesh.mesh = db.make_mesh(def)
		if piece.id == "wireless_pad":
			mesh.material_override = db.make_material(_pad_color(piece.pad_mode, piece.pad_on), 1.0)
		else:
			mesh.material_override = db.make_material(def.color, 1.0)
		body.add_child(mesh)
		root.add_child(body)
		bodies.append(body)
		if piece.id == "control_center":
			centers.append(body)
		elif piece.id == "gps":
			gps_bodies.append(body)
		elif piece.id == "angle_sensor":
			angle_bodies.append(body)
		elif piece.id == "linear_sensor":
			linear_bodies.append(body)
		elif def.propeller:
			prop_bodies.append(body)
			prop_limits.append(def.thrust_n)
			prop_powers.append(def.power_w)
		elif piece.id == "wireless_pad":
			body.add_to_group("charge_pad")
			body.set_meta("pad_unit", root)
			body.set_meta("pad_index", pad_bodies.size())
			pad_bodies.append(body)
			pad_on.append(piece.pad_on)
			pad_mode.append(piece.pad_mode)

	for i in yard.pieces.size():
		var piece: Yard.Piece = yard.pieces[i]
		if piece.parent < 0:
			continue
		var child_def := db.get_part(piece.id)
		var parent_def := db.get_part(yard.pieces[piece.parent].id)
		var wheel_index := -1
		if child_def.wheel:
			wheel_index = i
		elif parent_def.wheel:
			wheel_index = piece.parent
		if wheel_index >= 0:
			var wheel_body := bodies[wheel_index]
			var mount := bodies[i if wheel_index == piece.parent else piece.parent]
			var axle: Vector3 = wheel_body.basis.y.normalized()
			var hub := RigidBody3D.new()
			hub.mass = 0.25
			hub.position = piece.joint_pos
			hub.collision_layer = 0
			hub.collision_mask = 0
			hub.freeze = true
			hub.can_sleep = false
			root.add_child(hub)
			hubs.append(hub)
			var steer := Generic6DOFJoint3D.new()
			steer.basis = _basis_from_z(_steer_axis(axle))
			steer.position = piece.joint_pos
			steer.exclude_nodes_from_collision = true
			_elastic_mount(steer, 0.0)
			root.add_child(steer)
			steer.node_a = steer.get_path_to(mount)
			steer.node_b = steer.get_path_to(hub)
			var hinge := HingeJoint3D.new()
			hinge.basis = _basis_from_z(axle)
			hinge.position = piece.joint_pos
			hinge.exclude_nodes_from_collision = true
			hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, false)
			root.add_child(hinge)
			hinge.node_a = hinge.get_path_to(hub)
			hinge.node_b = hinge.get_path_to(wheel_body)
			hinges.append(hinge)
			steer_hinges.append(steer)
			wheel_powers.append(db.get_part(yard.pieces[wheel_index].id).power_w)
			wheel_bodies.append(wheel_body)
		else:
			var weld := Generic6DOFJoint3D.new()
			_lock_weld(weld)
			weld.position = piece.joint_pos
			weld.exclude_nodes_from_collision = true
			root.add_child(weld)
			weld.node_a = weld.get_path_to(bodies[piece.parent])
			weld.node_b = weld.get_path_to(bodies[i])
	for body in bodies:
		body.freeze = false
	for hub in hubs:
		hub.freeze = false
	root.energy_j = stored
	root.energy_max = stored
	root.passive_w = passive
	root.wheel_w = wheel_draw
	root.bind(bodies, centers, gps_bodies, angle_bodies, linear_bodies, prop_bodies, prop_limits, prop_powers, hinges, steer_hinges, wheel_powers, wheel_bodies, outline, pad_bodies, pad_on, pad_mode)
	_fill_links(yard, db, root)
	var saved: Dictionary = yard.blueprint_data()
	var raw = saved.get("pieces", [])
	if raw is Array:
		root.layout = (raw as Array).duplicate(true)
	return root


static func _lock_weld(joint: Generic6DOFJoint3D) -> void:
	for axis in ["x", "y", "z"]:
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, false)
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, false)
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, 0.0)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, 0.0)


static func _elastic_mount(joint: Generic6DOFJoint3D, steer_rad: float) -> void:
	for axis in ["x", "y", "z"]:
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, -0.04)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.04)
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_SPRING, true)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_SPRING_STIFFNESS, 6000.0)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_SPRING_DAMPING, 90.0)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_LINEAR_SPRING_EQUILIBRIUM_POINT, 0.0)
	for axis in ["x", "y"]:
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -0.08)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, 0.08)
		joint.call("set_flag_%s" % axis, Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, 400.0)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, 12.0)
		joint.call("set_param_%s" % axis, Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_EQUILIBRIUM_POINT, 0.0)
	_steer_spring(joint, steer_rad)


static func _steer_spring(joint: Generic6DOFJoint3D, steer_rad: float) -> void:
	var give := 0.08
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, steer_rad - give)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, steer_rad + give)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, 500.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, 14.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_EQUILIBRIUM_POINT, steer_rad)


static func _steer_axis(axle: Vector3) -> Vector3:
	var up := Vector3.UP
	if absf(axle.normalized().dot(up)) > 0.85:
		up = Vector3.FORWARD
	var side := axle.cross(up)
	if side.length_squared() < 0.0001:
		return Vector3.UP
	return side.cross(axle).normalized()


static func _basis_from_z(axis: Vector3) -> Basis:
	var z := axis.normalized()
	if z.length_squared() < 0.0001:
		z = Vector3.UP
	var helper := Vector3.UP
	if absf(z.dot(helper)) > 0.9:
		helper = Vector3.FORWARD
	var x := helper.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


static func _pad_color(pad_mode: String, on: bool) -> Color:
	if not on or pad_mode == "off":
		return Color(0.22, 0.24, 0.28)
	if pad_mode == "in":
		return Color(0.95, 0.62, 0.18)
	return Color(0.15, 0.78, 0.86)


static func _fill_links(yard: Yard, db: UnitDB, root: Deployed) -> void:
	var wheel_slot := {}
	var prop_slot := {}
	var pad_slot := {}
	var wheels := 0
	var props := 0
	var pads := 0
	for i in yard.pieces.size():
		var part_id := yard.pieces[i].id
		if db.get_part(part_id).propeller:
			prop_slot[i] = props
			props += 1
		if part_id == "wireless_pad":
			pad_slot[i] = pads
			pads += 1
	for i in yard.pieces.size():
		var piece: Yard.Piece = yard.pieces[i]
		if piece.parent < 0:
			continue
		var child_id := piece.id
		var parent_id := yard.pieces[piece.parent].id
		var wheel_index := -1
		if child_id == "wheel":
			wheel_index = i
		elif parent_id == "wheel":
			wheel_index = piece.parent
		if wheel_index >= 0 and not wheel_slot.has(wheel_index):
			wheel_slot[wheel_index] = wheels
			wheels += 1
	var ordered: Array[Yard.Piece] = []
	for piece in yard.pieces:
		if piece.control_order > 0 and _kind_of(piece.id) != "":
			ordered.append(piece)
	ordered.sort_custom(func(a: Yard.Piece, b: Yard.Piece): return a.control_order < b.control_order)
	var seen := {}
	for piece in ordered:
		var kind := _kind_of(piece.id)
		var index := yard.pieces.find(piece)
		var slot := -1
		if kind == "wheel" and wheel_slot.has(index):
			slot = int(wheel_slot[index])
		elif kind == "propeller" and prop_slot.has(index):
			slot = int(prop_slot[index])
		elif kind == "pad" and pad_slot.has(index):
			slot = int(pad_slot[index])
		var count := int(seen.get(kind, 0)) + 1
		seen[kind] = count
		var prefix := "wheel"
		if kind == "propeller":
			prefix = "propeller"
		elif kind == "pad":
			prefix = "pad"
		root.link_names.append("%s%d" % [prefix, count])
		root.link_kinds.append(kind)
		root.link_slots.append(slot)


static func _kind_of(part_id: String) -> String:
	if part_id == "wheel":
		return "wheel"
	if part_id == "propeller":
		return "propeller"
	if part_id == "wireless_pad":
		return "pad"
	return ""
