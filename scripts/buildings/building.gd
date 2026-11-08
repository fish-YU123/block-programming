extends Node3D
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
	var base_color := Color.from_hsv(0.60 if team == 0 else 0.02, 0.55, 0.86)
	var raw: Array = def.get("color", [])
	if raw.size() == 3:
		base_color = Color(float(raw[0]), float(raw[1]), float(raw[2]))
	var body_size := Vector3(float(size.x), float(size.y), float(size.z)) * 0.94

	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = body_size
	body.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	mat.metallic = 0.15
	mat.roughness = 0.6
	body.material_override = mat
	body.position = Vector3(0.0, float(size.y) * 0.5, 0.0)
	add_child(body)

	# 顶部一圈亮色描边，方便在地形里一眼认出这是建筑
	var cap := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(body_size.x * 1.02, 0.14, body_size.z * 1.02)
	cap.mesh = cap_box
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = base_color.lightened(0.35)
	cap_mat.emission_enabled = true
	cap_mat.emission = base_color.lightened(0.25)
	cap_mat.emission_energy_multiplier = 0.35
	cap.material_override = cap_mat
	cap.position = Vector3(0.0, float(size.y) * 0.94, 0.0)
	add_child(cap)

	# 小天线，区分不同建筑种类
	if kind == "miner":
		var mast := MeshInstance3D.new()
		var mast_box := BoxMesh.new()
		mast_box.size = Vector3(0.12, 1.1, 0.12)
		mast.mesh = mast_box
		var mast_mat := StandardMaterial3D.new()
		mast_mat.albedo_color = Color(0.25, 0.25, 0.28)
		mast.material_override = mast_mat
		mast.position = Vector3(0.0, float(size.y) + 0.5, 0.0)
		add_child(mast)

	var body_node := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(float(size.x), float(size.y), float(size.z))
	shape.shape = box_shape
	body_node.add_child(shape)
	body_node.position = Vector3(0.0, float(size.y) * 0.5, 0.0)
	add_child(body_node)


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
