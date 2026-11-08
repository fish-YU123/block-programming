extends Node3D
const MatCache = preload("res://scripts/core/mat_cache.gd")
## 一栋建筑：一个占方格的方块体，带队伍颜色和碰撞体。
## 具体行为（采矿 / 产单位）由 main 每帧按 kind 驱动。

var kind := ""
var team := 0
var def: Dictionary = {}
var base_cell := Vector3i.ZERO
var size := Vector3i(3, 2, 3)
var period := 1.0
var timer := 0.0
var produced := 0      ## 已经产出多少个东西（单位或矿石）

var world = null

## 会转的部件：钻头（采矿机）、吊臂（组装厂）
var _drill_bit: MeshInstance3D = null
var _crane: Node3D = null


func setup(world_ref, definition: Dictionary, at_cell: Vector3i, team_id: int) -> void:
	world = world_ref
	def = definition
	kind = str(definition.get("kind", ""))
	base_cell = at_cell
	team = team_id
	var raw: Array = definition.get("size", [3, 2, 3])
	size = Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
	period = maxf(float(definition.get("period", 1.0)), 0.01)
	position = Vector3(base_cell) + Vector3(0.5, 0.0, 0.5)
	_build_visual()


func _build_visual() -> void:
	# 队伍色：蓝方深蓝、红方赤红；建筑本体的细节用深浅两色分层
	var team_main := Color(0.22, 0.38, 0.78) if team == 0 else Color(0.72, 0.2, 0.18)
	var team_glow := Color(0.35, 0.9, 1.0) if team == 0 else Color(1.0, 0.66, 0.22)
	var frame_mat: StandardMaterial3D = MatCache.solid("building_frame", Color(0.20, 0.22, 0.26))
	var body_mat: StandardMaterial3D = MatCache.solid("building_body_%s_%d" % [str(def.get("id", "")), team], team_main)
	var glow_mat: StandardMaterial3D = MatCache.of(team_glow, false, 0.55)

	var sx := float(size.x)
	var sy := float(size.y)
	var sz := float(size.z)

	# 底座：一圈略宽的深色地基，让建筑"坐"在地上，不会像浮着的盒子
	var plinth := MeshInstance3D.new()
	var plinth_mesh := BoxMesh.new()
	plinth_mesh.size = Vector3(sx * 0.98, 0.18, sz * 0.98)
	plinth.mesh = plinth_mesh
	plinth.material_override = frame_mat
	plinth.position = Vector3(0.0, 0.09, 0.0)
	add_child(plinth)

	# 主体：比占地小一圈，露出底座和边角
	var hull := MeshInstance3D.new()
	var hull_mesh := BoxMesh.new()
	hull_mesh.size = Vector3(sx * 0.84, sy - 0.26, sz * 0.84)
	hull.mesh = hull_mesh
	hull.material_override = body_mat
	hull.position = Vector3(0.0, 0.26 + (sy - 0.26) * 0.5, 0.0)
	add_child(hull)

	# 腰部队伍色发光带（远近都能看出这是哪一队）
	var band := MeshInstance3D.new()
	var band_mesh := BoxMesh.new()
	band_mesh.size = Vector3(sx * 0.88, 0.10, sz * 0.88)
	band.mesh = band_mesh
	band.material_override = glow_mat
	band.position = Vector3(0.0, sy * 0.55, 0.0)
	add_child(band)

	# 顶盖 + 四角护角，避免"纯方块"的观感
	var roof := MeshInstance3D.new()
	var roof_mesh := BoxMesh.new()
	roof_mesh.size = Vector3(sx * 0.9, 0.12, sz * 0.9)
	roof.mesh = roof_mesh
	roof.material_override = frame_mat
	roof.position = Vector3(0.0, sy - 0.06, 0.0)
	add_child(roof)

	for corner_x in [-1.0, 1.0]:
		for corner_z in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			var post_mesh := BoxMesh.new()
			post_mesh.size = Vector3(0.16, sy - 0.2, 0.16)
			post.mesh = post_mesh
			post.material_override = frame_mat
			post.position = Vector3(corner_x * (sx * 0.42 - 0.08), 0.2 + (sy - 0.2) * 0.5, corner_z * (sz * 0.42 - 0.08))
			add_child(post)

	# 不同建筑加各自的特征件
	if kind == "miner":
		# 采矿机：中间一根钻杆 + 旋转的钻头 + 顶部小雷达罩
		var tower := MeshInstance3D.new()
		var tower_mesh := CylinderMesh.new()
		tower_mesh.top_radius = 0.10
		tower_mesh.bottom_radius = 0.16
		tower_mesh.height = 1.6
		tower.mesh = tower_mesh
		tower.material_override = frame_mat
		tower.position = Vector3(0.0, sy + 0.7, 0.0)
		add_child(tower)

		_drill_bit = MeshInstance3D.new()
		var bit_mesh := CylinderMesh.new()
		bit_mesh.top_radius = 0.04
		bit_mesh.bottom_radius = 0.26
		bit_mesh.height = 0.7
		_drill_bit.mesh = bit_mesh
		_drill_bit.material_override = glow_mat
		_drill_bit.position = Vector3(0.0, sy + 1.72, 0.0)
		add_child(_drill_bit)

		var dome := MeshInstance3D.new()
		var dome_mesh := SphereMesh.new()
		dome_mesh.radius = 0.22
		dome_mesh.height = 0.3
		dome.mesh = dome_mesh
		dome.material_override = glow_mat
		dome.position = Vector3(sx * 0.3, sy + 0.12, -sz * 0.3)
		add_child(dome)
	elif kind == "factory":
		# 组装厂：两根烟囱 + 侧面成品出口 + 顶上转动的吊臂
		for side in [-1.0, 1.0]:
			var stack := MeshInstance3D.new()
			var stack_mesh := CylinderMesh.new()
			stack_mesh.top_radius = 0.16
			stack_mesh.bottom_radius = 0.22
			stack_mesh.height = sy * 0.8
			stack.mesh = stack_mesh
			stack.material_override = frame_mat
			stack.position = Vector3(side * sx * 0.28, sy + sy * 0.3, side * sz * 0.22)
			add_child(stack)
			var stack_ring := MeshInstance3D.new()
			var ring_mesh := CylinderMesh.new()
			ring_mesh.top_radius = 0.18
			ring_mesh.bottom_radius = 0.18
			ring_mesh.height = 0.1
			stack_ring.mesh = ring_mesh
			stack_ring.material_override = glow_mat
			stack_ring.position = Vector3(side * sx * 0.28, sy + sy * 0.68, side * sz * 0.22)
			add_child(stack_ring)

		# 产线出口（朝 +X 方向，飞飞从这里下线）
		var outlet := MeshInstance3D.new()
		var outlet_mesh := BoxMesh.new()
		outlet_mesh.size = Vector3(0.16, sy * 0.45, sz * 0.5)
		outlet.mesh = outlet_mesh
		outlet.material_override = glow_mat
		outlet.position = Vector3(sx * 0.44, sy * 0.35, 0.0)
		add_child(outlet)

		_crane = Node3D.new()
		_crane.position = Vector3(0.0, sy + 0.1, 0.0)
		add_child(_crane)
		var arm := MeshInstance3D.new()
		var arm_mesh := BoxMesh.new()
		arm_mesh.size = Vector3(sx * 0.7, 0.1, 0.1)
		arm.mesh = arm_mesh
		arm.material_override = frame_mat
		arm.position = Vector3(sx * 0.2, 0.35, 0.0)
		_crane.add_child(arm)
	elif kind == "charger":
		# 充电站：四根立柱 + 顶部感应环 + 中间发光的核心
		for corner_x in [-1.0, 1.0]:
			for corner_z in [-1.0, 1.0]:
				var rod := MeshInstance3D.new()
				var rod_mesh := CylinderMesh.new()
				rod_mesh.top_radius = 0.06
				rod_mesh.bottom_radius = 0.06
				rod_mesh.height = sy * 0.9
				rod.mesh = rod_mesh
				rod.material_override = glow_mat
				rod.position = Vector3(corner_x * sx * 0.36, sy * 0.7, corner_z * sz * 0.36)
				add_child(rod)

		var ring := MeshInstance3D.new()
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = sx * 0.3
		ring_mesh.outer_radius = sx * 0.4
		ring.mesh = ring_mesh
		ring.material_override = glow_mat
		ring.position = Vector3(0.0, sy + 0.15, 0.0)
		add_child(ring)

		var core := MeshInstance3D.new()
		var core_mesh := SphereMesh.new()
		core_mesh.radius = sx * 0.2
		core_mesh.height = sx * 0.4
		core.mesh = core_mesh
		core.material_override = glow_mat
		core.position = Vector3(0.0, sy * 0.62, 0.0)
		add_child(core)

	# 碰撞体（占满整个格子，单位撞不进去）
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(sx, sy, sz)
	shape.shape = box_shape
	body.add_child(shape)
	body.position = Vector3(0.0, sy * 0.5, 0.0)
	add_child(body)


func _process(delta: float) -> void:
	if _drill_bit != null:
		_drill_bit.rotation.y += delta * 6.0
	if _crane != null:
		_crane.rotation.y += delta * 1.2


func center_cell() -> Vector3i:
	return Vector3i(base_cell.x + size.x / 2, base_cell.y, base_cell.z + size.z / 2)


func center_world() -> Vector3:
	return Vector3(base_cell) + Vector3(float(size.x) * 0.5, 0.0, float(size.z) * 0.5)


## 组装厂产出单位的位置：蓝方在 +X 侧，红方在 -X 侧
func spawn_point() -> Vector3:
	var front := 1.0 if team == 0 else -1.0
	var p := center_world()
	p.x += front * (float(size.x) * 0.5 + 1.2)
	return p


func occupies(cell: Vector3i) -> bool:
	return cell.x >= base_cell.x and cell.x < base_cell.x + size.x \
		and cell.y >= base_cell.y and cell.y < base_cell.y + size.y \
		and cell.z >= base_cell.z and cell.z < base_cell.z + size.z
