extends RigidBody3D
## 预设单位「车车」：地面轮式工程车。
## 四条腿（轮子）负责跑路，车头带钻头能挖方块，头顶小雷达。
## 和飞飞用同一套玩家代码接口：set_rcs(转向, 油门) / drill(True) / find_path(...)。
## 注意：车只能在地面跑，不会飞（lift 之类的控制量对它无效）。

const BlockDB = preload("res://scripts/world/block_db.gd")
const MatCache = preload("res://scripts/core/mat_cache.gd")
const StatusBadges = preload("res://scripts/ui/status_badges.gd")
const PathFinder = preload("res://scripts/world/path_finder.gd")

signal gun_fired(unit, from: Vector3, direction: Vector3)
signal block_dug(unit, cell: Vector3i, block_id: int)

var world: Node3D
var unit_id := "rover"
var display_name := "车车"

var energy_j := 0.0
var energy_max := 1.0
## 没电标记（充电站会把它清掉）
var energy_out := false
var mass_kg := 90.0
var unit_size := 1.2
var radar_radius := 2
## 雷达能看到的敌方单位距离（车车的雷达比飞飞近一点）
var radar_unit_range := 8.0

var team := 0
var uid := 0
var max_hp := 320.0
var hp := 320.0
var alive := true
var _badge: Sprite3D = null

var max_speed := 9.0
var drive_force := 2600.0
var turn_rate := 2.2
var drill_reach := 2.6
var drill_cooldown := 0.3
var drill_power_w := 900.0
var idle_power_w := 60.0
var drive_power_w := 1600.0

## 由玩家代码写入：turn/forward -1..1，drill bool
var controls: Dictionary = {}
var runtime_error := ""
var runtime_logs: Array = []
var thrust_now := 0.0
var drill_hits := 0

## A* 自动驾驶
var path: Array = []
var has_goal := false
var moving := false
var _goal := Vector3.ZERO
const PATH_MAX_SPEED := 6.0
const PATH_REACH := 1.2

## 武器相关字段：车车没有激光和炮，但保留同名属性（射程 0），
## 这样主场景的结算代码可以统一处理两种单位。
var laser_reach := 0.0
var laser_dps_block := 0.0
var laser_dps_unit := 0.0
var laser_on := false
var laser_target := Vector3.ZERO
var laser_hits := 0
var gun_reach := 0.0
var gun_damage_block := 0.0
var gun_damage_unit := 0.0

var _drill_cd := 0.0
var _wheels: Array = []
var _wheel_spin := 0.0


func setup(world_ref: Node3D, def: Dictionary) -> void:
	world = world_ref
	if def.has("id"):
		unit_id = str(def["id"])
	if def.has("display_name"):
		display_name = str(def["display_name"])
	unit_size = float(def.get("size", 1.2))
	mass_kg = float(def.get("mass", 90.0))
	energy_max = float(def.get("energy_j", 200000.0))
	energy_j = energy_max
	max_hp = float(def.get("hp", 320.0))
	hp = max_hp
	max_speed = float(def.get("max_speed", 9.0))
	drive_force = float(def.get("drive_force_n", 2600.0))
	turn_rate = float(def.get("turn_rate", 2.2))
	idle_power_w = float(def.get("idle_power_w", 60.0))
	drive_power_w = float(def.get("drive_power_w", 1600.0))
	radar_radius = int(def.get("radar_radius", 2))
	var drill: Dictionary = def.get("drill", {})
	drill_reach = float(drill.get("reach", 2.6))
	drill_cooldown = float(drill.get("cooldown", 0.3))
	drill_power_w = float(drill.get("power_w", 900.0))

	mass = mass_kg
	gravity_scale = 1.0
	linear_damp = 0.6
	angular_damp = 4.0
	can_sleep = false
	continuous_cd = true
	collision_layer = 4
	collision_mask = 1 | 4
	_apply_physics_material()
	_build_visual()
	_badge = StatusBadges.make_sprite(self, Vector3(0.0, unit_size + 0.5, 0.0))
	_reset_controls()


func _apply_physics_material() -> void:
	var mat := PhysicsMaterial.new()
	mat.friction = 1.2
	mat.bounce = 0.0
	physics_material_override = mat


func _reset_controls() -> void:
	controls = {
		"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false,
		"laser": false, "laser_x": 0.0, "laser_y": 0.0, "laser_z": 0.0,
		"shoot": false, "shoot_x": 0.0, "shoot_y": 0.0, "shoot_z": 0.0,
	}


# ---------------------------------------------------------------- 物理与驾驶

## 头顶状态图标：没电时显示闪电
func _update_badge() -> void:
	if _badge == null:
		return
	var no_power: bool = alive and (energy_out or energy_j <= energy_max * 0.08)
	StatusBadges.set_kind(_badge, StatusBadges.Kind.NO_POWER if no_power else StatusBadges.Kind.NONE)
	if no_power:
		_badge.position = Vector3(0.0, unit_size + 0.5 + sin(Time.get_ticks_msec() * 0.003) * 0.05, 0.0)


func _physics_process(delta: float) -> void:
	if not alive:
		return
	var throttle: float = clampf(float(controls.get("forward", 0.0)), -1.0, 1.0)
	var steer: float = clampf(float(controls.get("turn", 0.0)), -1.0, 1.0)
	var driving := absf(throttle) > 0.01 or absf(steer) > 0.01
	var power := idle_power_w + (drive_power_w if driving else 0.0)
	energy_j = maxf(0.0, energy_j - power * delta)
	energy_out = energy_j <= 0.0
	if energy_out:
		throttle = 0.0
		steer = 0.0

	# 自动驾驶优先：有航路就自己压着航路走
	if has_goal and not path.is_empty():
		_autopilot(delta)
		throttle = _auto_throttle
		steer = _auto_steer

	var basis := global_transform.basis
	var forward := -basis.z
	var speed := linear_velocity.dot(forward)
	if absf(throttle) > 0.01 and absf(speed) < max_speed * 1.05:
		var force := forward * throttle * drive_force
		apply_central_force(force)
		thrust_now = force.length()
	else:
		thrust_now = 0.0
	if absf(steer) > 0.01:
		angular_velocity.y = steer * turn_rate * (0.35 + 0.65 * minf(1.0, absf(speed) / 3.0))

	# 轮子转一转（纯视觉）
	_wheel_spin += speed * delta * 2.4
	for w in _wheels:
		if is_instance_valid(w):
			w.rotation.x = _wheel_spin

	_drill_cd = maxf(0.0, _drill_cd - delta)
	if bool(controls.get("drill", false)) and _drill_cd <= 0.0 and energy_j > 0.0:
		_drill_cd = drill_cooldown
		_drill_once()

	_update_badge()

	# 卡进方块里就往上抬一点（防止掉进未生成的地面）
	if world != null:
		var cell := Vector3i(floori(global_position.x), floori(global_position.y), floori(global_position.z))
		if world.is_solid(cell):
			global_position.y += 0.1


var _auto_throttle := 0.0
var _auto_steer := 0.0


func _autopilot(delta: float) -> void:
	if path.is_empty():
		has_goal = false
		moving = false
		return
	var target: Vector3 = path[0]
	var to_target := target - global_position
	to_target.y = 0.0
	if to_target.length() <= PATH_REACH:
		path.remove_at(0)
		if path.is_empty():
			has_goal = false
			moving = false
		return
	moving = true
	var basis := global_transform.basis
	var forward := -basis.z
	var right := basis.x
	var local_fwd := to_target.normalized().dot(forward)
	var local_side := to_target.normalized().dot(right)
	_auto_throttle = clampf(local_fwd * 1.4, -1.0, 1.0)
	if _auto_throttle < 0.25:
		_auto_throttle = 0.25
	_auto_steer = clampf(local_side * 1.6, -1.0, 1.0)


func request_go(target: Vector3) -> void:
	if world == null:
		return
	if has_goal and _goal.distance_to(target) < 1.0:
		return
	_goal = target
	path = find_path_to(target)
	has_goal = path.size() > 0
	moving = has_goal


func clear_go() -> void:
	path = []
	has_goal = false
	moving = false


func find_path_to(target: Vector3) -> Array:
	if world == null:
		return [target]
	return PathFinder.find_path(world, global_position, target)


func _drill_once() -> void:
	if world == null:
		return
	var basis := global_transform.basis
	var from := global_position + basis * Vector3(0, 0.1, -0.5 * unit_size)
	var to := from + basis * Vector3(0, 0, -drill_reach)
	var hit: Dictionary = world.raycast(from, to)
	if hit.is_empty():
		return
	var cell: Vector3i = hit["cell"]
	var block_id: int = world.get_block(cell)
	if block_id == BlockDB.AIR:
		return
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


func block_here() -> String:
	if world == null:
		return "air"
	var cell := Vector3i(floori(global_position.x), floori(global_position.y), floori(global_position.z))
	return world.db.name_of(world.get_block(cell))


func take_damage(amount: float) -> void:
	if not alive:
		return
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		alive = false
		set_physics_process(false)
		visible = false
		collision_layer = 0
		collision_mask = 0


func aims_at(point: Vector3, max_range: float) -> bool:
	var d := point - global_position
	if d.length() > max_range:
		return false
	var forward := -global_transform.basis.z
	return forward.dot(d.normalized()) > 0.7


func draw_laser(_from: Vector3, _to: Vector3) -> void:
	pass


func clear_laser() -> void:
	pass


func draw_tracer(_from: Vector3, _to: Vector3) -> void:
	pass


func muzzle_world() -> Vector3:
	return global_position + global_transform.basis * Vector3(0, 0.4 * unit_size, -0.6 * unit_size)


func forward_dir() -> Vector3:
	return -global_transform.basis.z


# ---------------------------------------------------------------- 外观

func _build_visual() -> void:
	var k := unit_size / 1.2
	if unit_id == "minelayer":
		_build_minelayer_visual(k)
		return
	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.0, 0.45, 1.5) * k
	body.mesh = body_mesh
	body.material_override = MatCache.solid("rover_body", Color(0.86, 0.72, 0.32))
	body.position.y = 0.05
	add_child(body)

	var cabin := MeshInstance3D.new()
	var cabin_mesh := BoxMesh.new()
	cabin_mesh.size = Vector3(0.7, 0.35, 0.6) * k
	cabin.mesh = cabin_mesh
	cabin.material_override = MatCache.solid("rover_cabin", Color(0.34, 0.4, 0.46))
	cabin.position = Vector3(0.0, 0.42, -0.25) * k
	add_child(cabin)

	# 车头钻头
	var drill := MeshInstance3D.new()
	var drill_mesh := CylinderMesh.new()
	drill_mesh.top_radius = 0.06 * k
	drill_mesh.bottom_radius = 0.11 * k
	drill_mesh.height = 0.5 * k
	drill.mesh = drill_mesh
	drill.material_override = MatCache.solid("rover_drill", Color(0.62, 0.64, 0.68))
	drill.rotation.x = PI * 0.5
	drill.position = Vector3(0.0, 0.0, -1.0) * k
	add_child(drill)

	# 四个轮子
	_wheels = []
	var wheel_offsets := [
		Vector3(-0.62, -0.16, -0.45),
		Vector3(0.62, -0.16, -0.45),
		Vector3(-0.62, -0.16, 0.5),
		Vector3(0.62, -0.16, 0.5),
	]
	for off in wheel_offsets:
		var wheel := MeshInstance3D.new()
		var wheel_mesh := CylinderMesh.new()
		wheel_mesh.top_radius = 0.22 * k
		wheel_mesh.bottom_radius = 0.22 * k
		wheel_mesh.height = 0.14 * k
		wheel.mesh = wheel_mesh
		wheel.material_override = MatCache.solid("rover_wheel", Color(0.16, 0.16, 0.18))
		wheel.rotation.z = PI * 0.5
		var holder := Node3D.new()
		holder.position = off * k
		holder.add_child(wheel)
		add_child(holder)
		_wheels.append(holder)

	# 碰撞盒
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.1, 0.6, 1.5) * k
	shape.shape = box
	shape.position.y = 0.05
	add_child(shape)


## 布雷车造型：低矮装甲车 + 尾部雷架 + 顶部警示灯
func _build_minelayer_visual(k: float) -> void:
	var hull := MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(1.05, 0.34, 1.55) * k
	hull.mesh = hull_mesh
	hull.material_override = MatCache.solid("minelayer_hull", Color(0.28, 0.3, 0.34))
	hull.position.y = 0.02 * k
	add_child(hull)

	var cab := MeshInstance3D.new()
	var cab_mesh := BoxMesh.new()
	cab_mesh.size = Vector3(0.66, 0.32, 0.5) * k
	cab.mesh = cab_mesh
	cab.material_override = MatCache.solid("minelayer_cab", Color(0.36, 0.42, 0.5))
	cab.position = Vector3(0.0, 0.3 * k, -0.3 * k)
	add_child(cab)

	# 尾部雷架：三排小圆筒
	for i in 3:
		var holder := MeshInstance3D.new()
		var holder_mesh := CylinderMesh.new()
		holder_mesh.top_radius = 0.07 * k
		holder_mesh.bottom_radius = 0.09 * k
		holder_mesh.height = 0.16 * k
		holder.mesh = holder_mesh
		holder.material_override = MatCache.solid("minelayer_mine", Color(0.85, 0.32, 0.24), false, 0.3)
		holder.position = Vector3((float(i) - 1.0) * 0.26 * k, 0.26 * k, 0.62 * k)
		add_child(holder)

	# 顶部警示灯
	var lamp := MeshInstance3D.new()
	var lamp_mesh := SphereMesh.new()
	lamp_mesh.radius = 0.07 * k
	lamp_mesh.height = 0.14 * k
	lamp.mesh = lamp_mesh
	lamp.material_override = MatCache.of(Color(1.0, 0.45, 0.2), true, 0.8)
	lamp.position = Vector3(0.0, 0.5 * k, -0.3 * k)
	add_child(lamp)

	# 四个轮子
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var wheel := MeshInstance3D.new()
			var wheel_mesh := CylinderMesh.new()
			wheel_mesh.top_radius = 0.24 * k
			wheel_mesh.bottom_radius = 0.24 * k
			wheel_mesh.height = 0.16 * k
			wheel.mesh = wheel_mesh
			wheel.material_override = MatCache.solid("minelayer_wheel", Color(0.12, 0.12, 0.14))
			wheel.rotation = Vector3(0.0, 0.0, PI * 0.5)
			wheel.position = Vector3(sx * 0.56 * k, -0.12 * k, sz * 0.5 * k)
			add_child(wheel)
