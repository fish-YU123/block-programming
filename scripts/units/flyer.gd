extends RigidBody3D
## 预设单位「飞飞」：悬浮飞行器。
## 底部矢量喷口提供升力（可偏转产生侧移）、两侧 RCS 前后喷口负责平移与转向、
## 前置激光钻头可挖方块、顶部小雷达扫描周围 5×5 的方块。

const BlockDB = preload("res://scripts/world/block_db.gd")

var world: Node3D
var unit_id := "feifei"
var display_name := "飞飞"

var mass_kg := 40.0
var energy_j := 0.0
var energy_max := 1.0
var hover_thrust := 2100.0
var rcs_thrust := 320.0
var gimbal_rad := 0.42
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
var idle_power_w := 180.0
var lift_power_w := 1500.0
var rcs_power_w := 420.0

## 由玩家代码写入：lift/pitch/roll 0..1 或 -1..1，turn/forward -1..1，drill bool
var controls := {"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false}
var runtime_error := ""
var runtime_logs: Array = []
var energy_out := false
var drill_hits := 0
var thrust_now := 0.0

var _nozzle: Node3D
var _drill_cd := 0.0


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

	mass = mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.1, 0)
	axis_lock_angular_x = true
	axis_lock_angular_z = true
	linear_damp = 0.3
	angular_damp = 2.5
	can_sleep = false
	continuous_cd = true
	contact_monitor = false
	collision_layer = 2
	collision_mask = 1
	_build_visual()


# ---------------------------------------------------------------- 物理

func _physics_process(delta: float) -> void:
	var lift := clampf(float(controls.get("lift", 0.0)), 0.0, 1.0)
	var pitch := clampf(float(controls.get("pitch", 0.0)), -1.0, 1.0)
	var roll := clampf(float(controls.get("roll", 0.0)), -1.0, 1.0)
	var turn := clampf(float(controls.get("turn", 0.0)), -1.0, 1.0)
	var forward := clampf(float(controls.get("forward", 0.0)), -1.0, 1.0)
	var drilling := bool(controls.get("drill", false))

	# 能耗
	var power := idle_power_w + lift * lift_power_w + (absf(turn) + absf(forward)) * rcs_power_w
	if drilling:
		power += drill_power_w
	energy_j = maxf(0.0, energy_j - power * delta)
	energy_out = energy_j <= 0.0
	if energy_out:
		lift = 0.0
		turn = 0.0
		forward = 0.0
		drilling = false

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
	world.set_block(cell, BlockDB.AIR)
	drill_hits += 1


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
	return {"blocks": names, "heights": heights}


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
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.25, 0.28, 0.34)
	body_mat.metallic = 0.4
	body_mat.roughness = 0.55
	var trim_mat := StandardMaterial3D.new()
	trim_mat.albedo_color = Color(0.92, 0.55, 0.15)
	trim_mat.roughness = 0.5
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.3, 0.75, 0.9)
	glass_mat.emission_enabled = true
	glass_mat.emission = Color(0.2, 0.6, 0.8)

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

	# 碰撞体（略小于外接立方体，避免卡方块）
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.66, 0.34, 0.6) * k
	shape.shape = box
	add_child(shape)
