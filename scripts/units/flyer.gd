extends RigidBody3D
## 预设单位「飞飞」：悬浮飞行器。
## 底部矢量喷口提供升力（可偏转产生侧移）、两侧 RCS 前后喷口负责平移与转向、
## 前置激光钻头可挖方块、机背炮管可远程射击、顶部小雷达扫描周围 5×5×5 的方块与 10 米内单位。

const BlockDB = preload("res://scripts/world/block_db.gd")
const MatCache = preload("res://scripts/core/mat_cache.gd")

## 炮管开火（主场景据此结算命中与伤害）
signal gun_fired(unit, from: Vector3, direction: Vector3)
## 钻头挖掉了一个方块
signal block_dug(unit, cell: Vector3i, block_id: int)

const PathFinder = preload("res://scripts/world/path_finder.gd")
var world: Node3D
var unit_id := "feifei"
var display_name := "飞飞"

var mass_kg := 40.0
var energy_j := 0.0
var energy_max := 1.0
var hover_thrust := 2100.0
var rcs_thrust := 320.0
var gimbal_rad := 0.42
## ---- 自动驾驶（A* 寻路） ----
var path: Array = []
var has_goal := false
var moving := false
var _goal := Vector3.ZERO
const PATH_MAX_SPEED := 9.0
const PATH_REACH := 1.0
var radar_radius := 2
## 队伍（0=蓝方玩家，1=红方）
var team := 0
var max_hp := 120.0
var hp := 120.0
var alive := true
## 单位外接立方体边长（米）：0.75×0.75×0.75
var unit_size := 0.75
var drill_reach := 3.4
var drill_cooldown := 0.25
var drill_power_w := 1200.0
## 激光（挖掘/切割）：5 格拉一条持续光束，对第一个命中的方块或单位持续伤害
var laser_reach := 5.0
var laser_dps_block := 80.0
var laser_dps_unit := 22.0
var laser_power_w := 700.0
## 炮管：15 格射程，单发伤害
var gun_reach := 15.0
var gun_cooldown := 1.0
var gun_damage_block := 60.0
var gun_damage_unit := 34.0
var gun_energy_j := 2400.0
## 雷达能看到的敌方单位数量上限与距离
var radar_unit_range := 10.0
var idle_power_w := 180.0
var lift_power_w := 1500.0
var rcs_power_w := 420.0

## 由玩家代码写入：lift/pitch/roll 0..1 或 -1..1，turn/forward -1..1，drill bool
var controls := {
	"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false,
	"laser": false, "laser_x": 0.0, "laser_y": 0.0, "laser_z": 0.0,
	"shoot": false, "shoot_x": 0.0, "shoot_y": 0.0, "shoot_z": 0.0,
}
var runtime_error := ""
var runtime_logs: Array = []
var energy_out := false
var drill_hits := 0
var thrust_now := 0.0

var _nozzle: Node3D
var _drill_cd := 0.0
var _gun_cd := 0.0
var _beam: MeshInstance3D
var _tracer: MeshInstance3D
var _tracer_left := 0.0
## 本帧是否在打激光、以及瞄准点（由 main 每帧读取后结算伤害）
var laser_on := false
var laser_target := Vector3.ZERO
var laser_hits := 0
var shots_fired := 0


func setup(world_node: Node3D, def: Dictionary) -> void:
	world = world_node
	unit_id = str(def.get("id", "feifei"))
	display_name = str(def.get("display_name", "飞飞"))
	mass_kg = float(def.get("mass", 40.0))
	energy_max = float(def.get("energy_j", 120000.0))
	energy_j = energy_max
	hover_thrust = float(def.get("hover_thrust_n", 2100.0))
	rcs_thrust = float(def.get("rcs_thrust_n", 320.0))
	gimbal_rad = deg_to_rad(float(def.get("gimbal_deg", 24.0)))
	radar_radius = int(def.get("radar_radius", 2))
	unit_size = float(def.get("size", 0.75))
	max_hp = float(def.get("hp", 120.0))
	hp = max_hp
	var drill: Dictionary = def.get("drill", {})
	drill_reach = float(drill.get("reach", 3.4))
	drill_cooldown = float(drill.get("cooldown", 0.25))
	drill_power_w = float(drill.get("power_w", 1200.0))
	idle_power_w = float(def.get("idle_power_w", 180.0))
	lift_power_w = float(def.get("lift_power_w", 1500.0))
	rcs_power_w = float(def.get("rcs_power_w", 420.0))
	var laser: Dictionary = def.get("laser", {})
	laser_reach = float(laser.get("reach", 5.0))
	laser_dps_block = float(laser.get("dps_block", 80.0))
	laser_dps_unit = float(laser.get("dps_unit", 22.0))
	laser_power_w = float(laser.get("power_w", 700.0))
	var gun: Dictionary = def.get("gun", {})
	gun_reach = float(gun.get("reach", 15.0))
	gun_cooldown = float(gun.get("cooldown", 1.0))
	gun_damage_block = float(gun.get("damage_block", 60.0))
	gun_damage_unit = float(gun.get("damage_unit", 34.0))
	gun_energy_j = float(gun.get("energy_j", 2400.0))
	radar_unit_range = float(def.get("radar_unit_range", 10.0))

	mass = mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.1, 0)
	axis_lock_angular_x = true
	axis_lock_angular_z = true
	linear_damp = 0.12
	angular_damp = 2.5
	can_sleep = false
	continuous_cd = true
	contact_monitor = false
	collision_layer = 2
	collision_mask = 1
	_build_visual()


# ---------------------------------------------------------------- 物理

## 算一条从当前位置到目标的航路（给玩家代码里的 find_path 用）
func find_path_to(target: Vector3) -> Array:
	if world == null:
		return [target]
	return PathFinder.find_path(world, global_position, target)


## 让单位自动飞到某个点：内部用 A* 算航路，然后自己压着航路飞
func request_go(target: Vector3) -> void:
	if has_goal and target.distance_to(_goal) < 1.2:
		return
	_goal = target
	has_goal = true
	path = PathFinder.find_path(world, global_position, _goal) if world != null else [_goal]
	if path.is_empty():
		path = [_goal]
	moving = true


func clear_go() -> void:
	has_goal = false
	moving = false
	path.clear()


## 每物理帧：沿着航路算推力方向，直接覆盖 controls 里的 lift/pitch/roll
func _autopilot() -> void:
	if not has_goal:
		return
	while not path.is_empty():
		var wp: Vector3 = path[0]
		if global_position.distance_to(wp) < PATH_REACH:
			path.remove_at(0)
		else:
			break
	if path.is_empty():
		if global_position.distance_to(_goal) < 1.5:
			moving = false
		else:
			# 水平到了但高度还差：继续用升力贴住目标高度
			controls["lift"] = _lift_for(_goal.y)
		return
	moving = true
	var wp: Vector3 = path[0]
	var to := wp - global_position
	var horiz := Vector3(to.x, 0.0, to.z)
	var v_des := Vector3.ZERO
	if horiz.length() > 0.25:
		var speed: float = clampf(horiz.length() * 1.4, 1.0, PATH_MAX_SPEED)
		v_des = horiz.normalized() * speed
	_steer_toward(v_des)
	controls["lift"] = _lift_for(wp.y)
	controls["turn"] = 0.0
	controls["forward"] = 0.0


## 把"想达到的水平速度"换算成倾角（每物理帧调用，所以没有代码刷新延迟）
const MAX_ACCEL := 12.0  ## 水平机动时允许的最大加速度（m/s²），决定"跟手"程度

func _steer_toward(v_des: Vector3) -> void:
	var dv := v_des - Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var acc := dv.limit_length(MAX_ACCEL)
	var local := global_transform.basis.inverse() * acc
	# 加速度按 MAX_ACCEL 归一化后直接映射到喷口偏转（0~1）
	controls["roll"] = clampf(local.x / MAX_ACCEL, -1.0, 1.0)
	controls["pitch"] = clampf(-local.z / MAX_ACCEL, -1.0, 1.0)


## 高度保持用的升力
func _lift_for(target_y: float) -> float:
	return clampf(0.585 + (target_y - global_position.y) * 0.2 - linear_velocity.y * 0.12, 0.0, 1.0)


## 玩家代码用 set_velocity / set_altitude 下指令时，每帧在这里闭环
func _command_control() -> void:
	if has_goal:
		return  # 自动驾驶优先
	if bool(controls.get("vel_mode", false)):
		_steer_toward(Vector3(float(controls.get("vx", 0.0)), 0.0, float(controls.get("vz", 0.0))))
	if bool(controls.get("alt_mode", false)):
		controls["lift"] = _lift_for(float(controls.get("alt_target", global_position.y)))


func _physics_process(delta: float) -> void:
	_autopilot()
	_command_control()

	var lift := clampf(float(controls.get("lift", 0.0)), 0.0, 1.0)
	var pitch := clampf(float(controls.get("pitch", 0.0)), -1.0, 1.0)
	var roll := clampf(float(controls.get("roll", 0.0)), -1.0, 1.0)
	var turn := clampf(float(controls.get("turn", 0.0)), -1.0, 1.0)
	var forward := clampf(float(controls.get("forward", 0.0)), -1.0, 1.0)
	var drilling := bool(controls.get("drill", false))

	# 武器状态
	laser_on = bool(controls.get("laser", false)) and not energy_out and energy_j > 0.0
	laser_target = Vector3(
		float(controls.get("laser_x", 0.0)),
		float(controls.get("laser_y", 0.0)),
		float(controls.get("laser_z", 0.0))
	)
	_gun_cd = maxf(0.0, _gun_cd - delta)
	# 开火请求：一次调用打一发，打完后清掉标志
	var shoot_requested := bool(controls.get("shoot", false))
	if shoot_requested:
		controls["shoot"] = false

	# 能耗
	var power := idle_power_w + lift * lift_power_w + (absf(turn) + absf(forward)) * rcs_power_w
	if drilling:
		power += drill_power_w
	if laser_on:
		power += laser_power_w
	energy_j = maxf(0.0, energy_j - power * delta)
	energy_out = energy_j <= 0.0
	if energy_out:
		lift = 0.0
		turn = 0.0
		forward = 0.0
		drilling = false
		laser_on = false

	if shoot_requested and _gun_cd <= 0.0 and energy_j >= gun_energy_j:
		_gun_cd = gun_cooldown
		energy_j = maxf(0.0, energy_j - gun_energy_j)
		shots_fired += 1
		_fire_gun_once()
	else:
		_gun_cd = maxf(0.0, _gun_cd - 0.0)

	# 曳光弹视觉效果衰减
	if _tracer_left > 0.0:
		_tracer_left = maxf(0.0, _tracer_left - delta)
		if _tracer_left <= 0.0 and _tracer != null:
			_tracer.visible = false

	# 卡进方块里时自己抬出来（防止被地形吞掉后永远出不来）
	if world != null:
		var body_cell := Vector3i(floori(global_position.x), floori(global_position.y), floori(global_position.z))
		if world.is_solid(body_cell):
			global_position.y += 0.08

	# 底部矢量喷口：推力方向随 gimbal 偏转，产生侧移
	# 喷口朝下喷气，反作用力向上；偏转产生侧移
	var dir_local := Vector3(sin(roll * gimbal_rad), 1.0, -sin(pitch * gimbal_rad)).normalized()
	thrust_now = lift * hover_thrust
	var basis := global_transform.basis
	apply_force(basis * (dir_local * thrust_now), basis * Vector3(0, -0.3, 0))

	# 两侧 RCS：前后喷口
	if absf(forward) > 0.001:
		var f := forward * rcs_thrust
		apply_force(basis * Vector3(0, 0, -f), basis * Vector3(-0.55, 0.05, 0.15))
		apply_force(basis * Vector3(0, 0, -f), basis * Vector3(0.55, 0.05, 0.15))
	if absf(turn) > 0.001:
		var t := turn * rcs_thrust
		apply_force(basis * Vector3(0, 0, t), basis * Vector3(-0.55, 0.05, 0.15))
		apply_force(basis * Vector3(0, 0, -t), basis * Vector3(0.55, 0.05, 0.15))

	# 喷口朝向跟随输入（纯视觉）
	if _nozzle != null:
		_nozzle.rotation.x = -pitch * gimbal_rad
		_nozzle.rotation.z = -roll * gimbal_rad

	# 激光钻头
	_drill_cd = maxf(0.0, _drill_cd - delta)
	if drilling and _drill_cd <= 0.0:
		_drill_cd = drill_cooldown
		_drill_once()


## 炮口/激光发射口的世界坐标（机头前上方）
func muzzle_world() -> Vector3:
	return global_position + global_transform.basis * Vector3(0.0, 0.14 * unit_size / 0.75, -0.42 * unit_size / 0.75)


## 机体前向
func forward_dir() -> Vector3:
	return -global_transform.basis.z


## 打一发光束/炮弹的视觉效果（伤害在 main 里结算）
func _fire_gun_once() -> void:
	gun_fired.emit(self, muzzle_world(), forward_dir())


## 在两点之间画一根细柱（激光/曳光弹共用）
func _draw_segment(node: MeshInstance3D, from: Vector3, to: Vector3, width: float) -> void:
	if node == null:
		return
	var dir := to - from
	var length := dir.length()
	if length < 0.001:
		node.visible = false
		return
	node.visible = true
	node.global_position = from + dir * 0.5
	var mesh: CylinderMesh = node.mesh
	if mesh != null:
		mesh.top_radius = width
		mesh.bottom_radius = width
		mesh.height = length
	# 让圆柱的 +Y 轴对准 from→to 方向
	var y_axis := dir / length
	var helper := Vector3.RIGHT if absf(y_axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x_axis := helper.cross(y_axis).normalized()
	var z_axis := y_axis.cross(x_axis)
	node.global_basis = Basis(x_axis, y_axis, z_axis)


## 激光束：从炮口到命中点；传 null 表示关闭
func draw_laser(from: Vector3, to: Vector3) -> void:
	_draw_segment(_beam, from, to, 0.035)


func clear_laser() -> void:
	if _beam != null:
		_beam.visible = false


## 炮弹曳光（短暂显示）
func draw_tracer(from: Vector3, to: Vector3) -> void:
	_draw_segment(_tracer, from, to, 0.02)
	_tracer_left = 0.08


## 受到伤害；血量归零则失去战斗能力
func take_damage(amount: float) -> void:
	if not alive or amount <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		alive = false
		controls = {"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false}
		visible = false
		set_physics_process(false)
		collision_layer = 0
		collision_mask = 0


## 钻头是否正对某个世界坐标（用于打敌方单位）
func aims_at(point: Vector3, max_range: float) -> bool:
	var forward := -global_transform.basis.z
	var delta := point - global_position
	if delta.length() > max_range:
		return false
	return forward.dot(delta.normalized()) > 0.7


func _drill_once() -> void:
	if world == null:
		return
	var basis := global_transform.basis
	var from := global_position + basis * Vector3(0, 0, -0.3 * unit_size)
	var to := from + basis * Vector3(0, 0, -drill_reach)
	var hit: Dictionary = world.raycast(from, to)
	if hit.is_empty():
		return
	var cell: Vector3i = hit["cell"]
	if world.get_block(cell) == BlockDB.AIR:
		return
	var block_id: int = world.get_block(cell)
	world.set_block(cell, BlockDB.AIR)
	drill_hits += 1
	block_dug.emit(self, cell, block_id)


# ---------------------------------------------------------------- 传感器

func sense() -> Dictionary:
	var p := global_position
	var v := linear_velocity
	var cell := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	return {
		"pos": {"x": p.x, "y": p.y, "z": p.z},
		"vel": {"x": v.x, "y": v.y, "z": v.z},
		"cell": {"x": cell.x, "y": cell.y, "z": cell.z},
		"yaw": rotation.y,
		"energy": energy_j,
		"energy_ratio": energy_j / energy_max if energy_max > 0.0 else 0.0,
		"thrust": thrust_now,
		"drill_hits": drill_hits,
	}


## 以单位为中心扫描 (2r+1)×(2r+1) 的方块：表面方块名 + 表面高度
func radar() -> Dictionary:
	var r := radar_radius
	var cx := floori(global_position.x)
	var cz := floori(global_position.z)
	var names: Array = []
	var heights: Array = []
	for dx in range(-r, r + 1):
		var row_names: Array = []
		var row_heights: Array = []
		for dz in range(-r, r + 1):
			var x := cx + dx
			var z := cz + dz
			var h := -1
			var block_name := "air"
			if world != null and x >= 0 and x < world.size_x and z >= 0 and z < world.size_z:
				h = world.surface_y(x, z)
				block_name = world.db.name_of(world.get_block(Vector3i(x, h, z)))
			row_names.append(block_name)
			row_heights.append(h)
		names.append(row_names)
		heights.append(row_heights)
	return {"blocks": names, "heights": heights, "blocks3": _radar_blocks3()}


## 以单位所在格为中心的 5×5×5 三维方块名
## blocks3[dx + r][dy + r][dz + r]，dx/dy/dz 相对单位所在格，范围 -r..r
func _radar_blocks3() -> Array:
	var r := radar_radius
	var cx := floori(global_position.x)
	var cy := floori(global_position.y)
	var cz := floori(global_position.z)
	var out: Array = []
	for dx in range(-r, r + 1):
		var plane: Array = []
		for dy in range(-r, r + 1):
			var row: Array = []
			for dz in range(-r, r + 1):
				var name := "air"
				if world != null:
					var cell := Vector3i(cx + dx, cy + dy, cz + dz)
					if world.in_bounds(cell):
						name = world.db.name_of(world.get_block(cell))
				row.append(name)
			plane.append(row)
		out.append(plane)
	return out


## 单位自己所在那一格的方块名
func block_here() -> String:
	var cell := Vector3i(floori(global_position.x), floori(global_position.y), floori(global_position.z))
	if world == null:
		return "air"
	return world.db.name_of(world.get_block(cell))


# ---------------------------------------------------------------- 外观

func _build_visual() -> void:
	# 所有尺寸以 0.75 米立方体为单位，k 按实际 unit_size 缩放
	var k := unit_size / 0.75
	var body_mat: StandardMaterial3D = MatCache.solid("flyer_body", Color(0.25, 0.28, 0.34))
	var trim_mat: StandardMaterial3D = MatCache.solid("flyer_trim", Color(0.92, 0.55, 0.15))
	var glass_mat: StandardMaterial3D = MatCache.solid("flyer_glass", Color(0.3, 0.75, 0.9), false, 1.0)

	var model := Node3D.new()
	model.name = "Model"
	model.scale = Vector3(k, k, k)
	add_child(model)

	# 机身：扁方的核心舱（0.62 × 0.20 × 0.62）
	var hull := MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(0.62, 0.2, 0.62)
	hull.mesh = hull_mesh
	hull.material_override = body_mat
	model.add_child(hull)

	# 背部装甲条（俯视时的识别色）
	var stripe := MeshInstance3D.new()
	var stripe_mesh := BoxMesh.new()
	stripe_mesh.size = Vector3(0.2, 0.02, 0.5)
	stripe.mesh = stripe_mesh
	stripe.position = Vector3(0, 0.11, 0)
	stripe.material_override = trim_mat
	model.add_child(stripe)

	# 底部矢量喷口（随机身俯仰/横滚偏转）
	_nozzle = Node3D.new()
	_nozzle.position = Vector3(0, -0.1, 0)
	model.add_child(_nozzle)
	var bell := MeshInstance3D.new()
	var bell_mesh := CylinderMesh.new()
	bell_mesh.top_radius = 0.05
	bell_mesh.bottom_radius = 0.11
	bell_mesh.height = 0.08
	bell.mesh = bell_mesh
	bell.position = Vector3(0, -0.05, 0)
	bell.material_override = trim_mat
	_nozzle.add_child(bell)
	var flame := MeshInstance3D.new()
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.1
	flame_mesh.bottom_radius = 0.02
	flame_mesh.height = 0.16
	flame.mesh = flame_mesh
	flame.position = Vector3(0, -0.17, 0)
	flame.material_override = glass_mat
	_nozzle.add_child(flame)

	# 两侧 RCS 吊舱：每个吊舱前后各一个喷口
	for side in [-1.0, 1.0]:
		var pod := MeshInstance3D.new()
		var pod_mesh := BoxMesh.new()
		pod_mesh.size = Vector3(0.1, 0.1, 0.26)
		pod.mesh = pod_mesh
		pod.position = Vector3(0.32 * side, 0.0, 0.04)
		pod.material_override = body_mat
		model.add_child(pod)
		for fz in [-0.14, 0.12]:
			var jet := MeshInstance3D.new()
			var jet_mesh := CylinderMesh.new()
			jet_mesh.top_radius = 0.03
			jet_mesh.bottom_radius = 0.03
			jet_mesh.height = 0.06
			jet.mesh = jet_mesh
			jet.position = Vector3(0.32 * side, 0.0, 0.04 + fz)
			jet.rotation.x = PI * 0.5
			jet.material_override = trim_mat
			model.add_child(jet)

	# 机头 + 激光钻头
	var nose := MeshInstance3D.new()
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.24, 0.14, 0.12)
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 0, -0.33)
	nose.material_override = body_mat
	model.add_child(nose)
	var drill := MeshInstance3D.new()
	var drill_mesh := CylinderMesh.new()
	drill_mesh.top_radius = 0.07
	drill_mesh.bottom_radius = 0.012
	drill_mesh.height = 0.2
	drill.mesh = drill_mesh
	drill.position = Vector3(0, 0, -0.31)
	drill.rotation.x = -PI * 0.5
	drill.material_override = trim_mat
	model.add_child(drill)

	# 顶部小雷达罩
	var radar := MeshInstance3D.new()
	var radar_mesh := SphereMesh.new()
	radar_mesh.radius = 0.08
	radar_mesh.height = 0.1
	radar_mesh.is_hemisphere = true
	radar.mesh = radar_mesh
	radar.position = Vector3(0, 0.1, 0.16)
	radar.material_override = glass_mat
	model.add_child(radar)

	# 机背炮管（沿 -Z 伸出），带一小段炮尾
	var gun_mat: StandardMaterial3D = MatCache.solid("flyer_gun", Color(0.16, 0.17, 0.2))
	var barrel := MeshInstance3D.new()
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.028
	barrel_mesh.bottom_radius = 0.032
	barrel_mesh.height = 0.4
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0, 0.14, -0.18)
	barrel.rotation.x = PI * 0.5
	barrel.material_override = gun_mat
	model.add_child(barrel)
	var muzzle := MeshInstance3D.new()
	var muzzle_mesh := CylinderMesh.new()
	muzzle_mesh.top_radius = 0.05
	muzzle_mesh.bottom_radius = 0.05
	muzzle_mesh.height = 0.06
	muzzle.mesh = muzzle_mesh
	muzzle.position = Vector3(0, 0.14, -0.4)
	muzzle.rotation.x = PI * 0.5
	muzzle.material_override = gun_mat
	model.add_child(muzzle)

	# 激光/曳光弹：直接挂在机体上（不随 model 缩放），运行时动态调整位置与长度
	var beam_mat: StandardMaterial3D = MatCache.solid("flyer_beam", Color(1.0, 0.35, 0.15), true, 3.0, false, 0.85)
	_beam = MeshInstance3D.new()
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.035
	beam_mesh.bottom_radius = 0.035
	beam_mesh.height = 1.0
	_beam.mesh = beam_mesh
	_beam.material_override = beam_mat
	_beam.visible = false
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)
	_tracer = MeshInstance3D.new()
	var tracer_mesh := CylinderMesh.new()
	tracer_mesh.top_radius = 0.02
	tracer_mesh.bottom_radius = 0.02
	tracer_mesh.height = 1.0
	_tracer.mesh = tracer_mesh
	_tracer.material_override = beam_mat
	_tracer.visible = false
	_tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tracer)

	# 碰撞体（略小于外接立方体，避免卡方块）
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.66, 0.34, 0.6) * k
	shape.shape = box
	add_child(shape)
