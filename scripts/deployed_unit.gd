extends Node3D

var display_name := ""
var source := ""
var layout: Array = []
var uid := 0
var revision := 0
var runtime_error := ""
var runtime_log := ""
var bodies: Array[RigidBody3D] = []
var centers: Array[RigidBody3D] = []
var gps_bodies: Array[RigidBody3D] = []
var angle_bodies: Array[RigidBody3D] = []
var linear_bodies: Array[RigidBody3D] = []
var prop_bodies: Array[RigidBody3D] = []
var prop_limits: Array[float] = []
var prop_powers: Array[float] = []
var spin_hinges: Array[HingeJoint3D] = []
var steer_hinges: Array[Generic6DOFJoint3D] = []
var wheel_powers: Array[float] = []
var wheel_bodies: Array[RigidBody3D] = []
var pad_bodies: Array[RigidBody3D] = []
var pad_on: Array[bool] = []
var pad_mode: Array[String] = []
var link_names: Array[String] = []
var link_kinds: Array[String] = []
var link_slots: Array[int] = []
var outlined := false
var energy_j := 0.0
var energy_max := 0.0
var passive_w := 0.0
var wheel_w := 0.0

var _outline: Material
var _hover: ShaderMaterial
var _hover_index := -1
var _command := 0.0
var _wheel_draw := 0.0
var _last_drive := 0.0
var _last_spins := {}
var _last_steers := {}
var _last_thrusts := {}
var _thrust_now: Array[float] = []
var _steer_applied: Array[float] = []
var _lin_prev := Vector3.ZERO
var _lin_have := false
var _sense_frame := -1
var _sense: Dictionary = {}


func bind(all_bodies: Array[RigidBody3D], center_bodies: Array[RigidBody3D], gps: Array[RigidBody3D], angles: Array[RigidBody3D], linears: Array[RigidBody3D], props: Array[RigidBody3D], limits: Array[float], prop_draw: Array[float], drive_hinges: Array[HingeJoint3D], turn_hinges: Array[Generic6DOFJoint3D], powers: Array[float], wheels: Array[RigidBody3D], outline: Material, pads: Array[RigidBody3D], pads_on: Array[bool], pads_mode: Array[String]) -> void:
	bodies = all_bodies
	centers = center_bodies
	gps_bodies = gps
	angle_bodies = angles
	linear_bodies = linears
	prop_bodies = props
	prop_limits = limits
	prop_powers = prop_draw
	_thrust_now.clear()
	for _i in prop_bodies.size():
		_thrust_now.append(0.0)
	_lin_have = false
	spin_hinges = drive_hinges
	steer_hinges = turn_hinges
	wheel_powers = powers
	wheel_bodies = wheels
	pad_bodies = pads
	pad_on = pads_on
	pad_mode = pads_mode
	_outline = outline
	var source := outline as ShaderMaterial
	if source != null:
		_hover = source.duplicate() as ShaderMaterial
		_hover.set_shader_parameter("outline_color", Color(0.35, 0.95, 1.0))
	_steer_applied.clear()
	for _i in steer_hinges.size():
		_steer_applied.append(0.0)


func wheel_count() -> int:
	return spin_hinges.size()


func prop_count() -> int:
	return prop_bodies.size()


func link_payload() -> Array:
	var rows: Array = []
	for i in link_names.size():
		rows.append({"name": link_names[i], "kind": link_kinds[i], "slot": link_slots[i]})
	return rows


func center_count() -> int:
	var count := 0
	for center in centers:
		if is_instance_valid(center):
			count += 1
	return count


func sense(delta: float) -> Dictionary:
	var frame := Engine.get_physics_frames()
	if frame == _sense_frame:
		return _sense
	_sense_frame = frame
	var data := {}
	var gps := gps_fix()
	if bool(gps.get("ok", false)):
		data["px"] = float(gps["x"])
		data["py"] = float(gps["y"])
		data["pz"] = float(gps["z"])
	var linear := linear_fix(delta)
	if bool(linear.get("ok", false)):
		data["vx"] = float(linear["vx"])
		data["vy"] = float(linear["vy"])
		data["vz"] = float(linear["vz"])
		data["ax"] = float(linear["ax"])
		data["ay"] = float(linear["ay"])
		data["az"] = float(linear["az"])
	var angle := angle_fix()
	if bool(angle.get("ok", false)):
		data["yaw"] = float(angle["yaw"])
		data["pitch"] = float(angle["pitch"])
		data["roll"] = float(angle["roll"])
		data["wx"] = float(angle["wx"])
		data["wy"] = float(angle["wy"])
		data["wz"] = float(angle["wz"])
	data["energy"] = energy_j
	data["wheels"] = wheel_count()
	data["props"] = prop_count()
	_sense = data
	return data


func gps_fix() -> Dictionary:
	for body in gps_bodies:
		if is_instance_valid(body):
			var pos := body.global_position
			return {"ok": true, "x": pos.x, "y": pos.y, "z": pos.z}
	return {"ok": false}


func angle_fix() -> Dictionary:
	for body in angle_bodies:
		if is_instance_valid(body):
			var euler := body.global_basis.get_euler()
			var spin := body.angular_velocity
			return {
				"ok": true,
				"yaw": rad_to_deg(euler.y),
				"pitch": rad_to_deg(euler.x),
				"roll": rad_to_deg(euler.z),
				"wx": spin.x,
				"wy": spin.y,
				"wz": spin.z,
			}
	return {"ok": false}


func linear_fix(delta: float) -> Dictionary:
	for body in linear_bodies:
		if is_instance_valid(body):
			var vel := body.linear_velocity
			var acc := Vector3.ZERO
			if _lin_have and delta > 0.0:
				acc = (vel - _lin_prev) / delta
			_lin_prev = vel
			_lin_have = true
			return {
				"ok": true,
				"vx": vel.x,
				"vy": vel.y,
				"vz": vel.z,
				"ax": acc.x,
				"ay": acc.y,
				"az": acc.z,
			}
	_lin_have = false
	return {"ok": false}


func sample_motion() -> Dictionary:
	var node: RigidBody3D = null
	for center in centers:
		if is_instance_valid(center):
			node = center
			break
	if node == null:
		for body in bodies:
			if is_instance_valid(body):
				node = body
				break
	if node == null:
		return {"pos": global_position, "vel": Vector3.ZERO}
	return {"pos": node.global_position, "vel": node.linear_velocity}


func command() -> float:
	return _command


func draw_w() -> float:
	return passive_w + _wheel_draw


func reapply(delta: float) -> void:
	spend(delta, _last_drive, _last_spins, _last_steers, _last_thrusts)


func spend(delta: float, drive: float, spins: Dictionary, steers: Dictionary, thrusts: Dictionary) -> void:
	_last_drive = drive
	_last_spins = spins.duplicate()
	_last_steers = steers.duplicate()
	_last_thrusts = thrusts.duplicate()
	var alive := energy_max <= 0.0 or energy_j > 0.0
	var use_drive := alive and absf(drive) >= 0.02
	var total_w := 0.0
	var peak := 0.0
	for i in spin_hinges.size():
		var speed := 0.0
		if _has_key(spins, i):
			speed = _num_at(spins, i)
		elif use_drive:
			speed = drive * 14.0
		if not alive:
			speed = 0.0
		_spin_to(i, speed)
		if _has_key(steers, i):
			_steer_to(i, _num_at(steers, i))
		var fraction := clampf(absf(speed) / 14.0, 0.0, 1.0)
		peak = maxf(peak, fraction)
		if i < wheel_powers.size():
			total_w += wheel_powers[i] * fraction
	for i in prop_bodies.size():
		var commanded := 0.0
		if alive and _has_key(thrusts, i):
			commanded = _num_at(thrusts, i)
		var limit := 0.0
		if i < prop_limits.size():
			limit = prop_limits[i]
		if limit > 0.0:
			commanded = clampf(commanded, -limit, limit)
		else:
			commanded = 0.0
		if not alive:
			commanded = 0.0
		if i < _thrust_now.size():
			_thrust_now[i] = commanded
		if limit > 0.0 and i < prop_powers.size():
			total_w += prop_powers[i] * clampf(absf(commanded) / limit, 0.0, 1.0)
	_command = peak if absf(drive) < 0.02 else drive
	if not alive:
		_command = 0.0
		total_w = 0.0
	_wheel_draw = total_w
	if energy_j > 0.0:
		var draw := passive_w + total_w
		energy_j = maxf(0.0, energy_j - draw * delta)
		if energy_j <= 0.0:
			for i in spin_hinges.size():
				_spin_to(i, 0.0)
			for i in _thrust_now.size():
				_thrust_now[i] = 0.0
			_wheel_draw = 0.0
			_command = 0.0


func _physics_process(_delta: float) -> void:
	for i in prop_bodies.size():
		if i >= _thrust_now.size():
			break
		var body := prop_bodies[i]
		if not is_instance_valid(body):
			continue
		var force := _thrust_now[i]
		if absf(force) < 0.001:
			continue
		body.apply_central_force(body.global_basis.y * force)


func _has_key(values: Dictionary, index: int) -> bool:
	return values.has(index) or values.has(str(index))


func _num_at(values: Dictionary, index: int) -> float:
	if values.has(index):
		return float(values[index])
	return float(values[str(index)])


func _spin_to(index: int, speed: float) -> void:
	var hinge := spin_hinges[index]
	if not is_instance_valid(hinge):
		return
	hinge.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	hinge.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, speed)
	hinge.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 8.0)


func _steer_to(index: int, degrees: float) -> void:
	if index >= steer_hinges.size():
		return
	var joint := steer_hinges[index]
	if not is_instance_valid(joint):
		return
	if absf(_steer_applied[index] - degrees) < 0.05:
		return
	_steer_applied[index] = degrees
	var give := 0.08
	var rad := deg_to_rad(degrees)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, rad - give)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, rad + give)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, 500.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, 14.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_EQUILIBRIUM_POINT, rad)


func highlight_wheel(index: int) -> void:
	_hover_index = index
	_apply_overlays()


func set_outline(on: bool) -> void:
	outlined = on
	_apply_overlays()


func _apply_overlays() -> void:
	var hover_body: RigidBody3D = null
	if _hover_index >= 0 and _hover_index < wheel_bodies.size() and is_instance_valid(wheel_bodies[_hover_index]):
		hover_body = wheel_bodies[_hover_index]
	for body in bodies:
		if not is_instance_valid(body):
			continue
		var overlay: Material = _outline if outlined else null
		if body == hover_body and _hover != null:
			overlay = _hover
		for child in body.get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).material_overlay = overlay


func focus_point() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for body in bodies:
		if is_instance_valid(body):
			sum += body.global_position
			count += 1
	if count == 0:
		return global_position
	return sum / float(count)
