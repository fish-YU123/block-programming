extends Node3D
const MatCache = preload("res://scripts/core/mat_cache.gd")
const ConstructionShader = preload("res://shaders/construction.gdshader")
const StatusBadges = preload("res://scripts/ui/status_badges.gd")
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
signal destroyed(building: Node3D)
var max_hp := 300.0    ## 建筑血量（来自 data/buildings/*.json 的 hp）
var hp := 300.0
var alive := true
var scan_cursor := 0   ## 采矿机扫矿的游标（一轮矿区扫描进度）
## 这座厂当前在生产哪种单位（可以在 options 里切换）
var produce_id := ""
var build_total := 10.0  ## 建造需要多少秒
var build_left := 0.0    ## 还剩多少秒建完（>0 表示还在施工）

var world = null

## 施工时把整个楼换成半透明青色"轮廓"，建完再换回队伍材质
var _saved_materials: Dictionary = {}
var _construction := false
var _unsupported := false
var _blocked := false
## 是不是被单位（而不是方块）挡住
var _blocked_by_unit := false            ## 占地体积被方块占住了（盖在石头里 / 后来被填上）
var _stalled := false            ## 缺电停工（发电站没煤 / 炮塔、充电站没电）
var _construction_mat: ShaderMaterial = null
var _badge: Sprite3D = null      ## 屋顶状态图标（地基不牢 / 被埋）

## 会转的部件：钻头（采矿机）、吊臂（组装厂）
var _drill_bit: MeshInstance3D = null
var _smoke: Array = []          ## 烟囱里冒出来的小烟球
var _smoke_t := 0.0
var _ring: MeshInstance3D = null ## 充电站的感应环
var _core: MeshInstance3D = null
var _anim_t := 0.0
var _smoke_anchor := Vector3.ZERO
var _crane: Node3D = null


func setup(world_ref, definition: Dictionary, at_cell: Vector3i, team_id: int) -> void:
	world = world_ref
	def = definition
	kind = str(definition.get("kind", ""))
	base_cell = at_cell
	team = team_id
	produce_id = str(definition.get("unit", ""))
	var raw: Array = definition.get("size", [3, 2, 3])
	size = Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
	period = maxf(float(definition.get("period", 1.0)), 0.01)
	max_hp = maxf(float(definition.get("hp", 300.0)), 1.0)
	hp = max_hp
	build_total = maxf(float(definition.get("build_seconds", 10.0)), 0.0)
	build_left = build_total
	position = Vector3(base_cell) + Vector3(0.5, 0.0, 0.5)
	_build_visual()
	_badge = StatusBadges.make_sprite(self, Vector3(0.0, float(size.y) + 0.9, 0.0))
	_update_build_progress()
	_refresh_badge()


## 挨打：血量归零就发出 destroyed 信号并把自己从场景里去掉（main 负责从列表里删）
func take_damage(amount: float) -> void:
	if not alive or amount <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		alive = false
		destroyed.emit(self)
		queue_free()


func hp_ratio() -> float:
	return clampf(hp / maxf(max_hp, 0.001), 0.0, 1.0)


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
			_smoke_anchor = Vector3(side * sx * 0.28, sy + sy * 0.72, side * sz * 0.22)

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
		_ring = ring

		var core := MeshInstance3D.new()
		var core_mesh := SphereMesh.new()
		core_mesh.radius = sx * 0.2
		core_mesh.height = sx * 0.4
		core.mesh = core_mesh
		core.material_override = glow_mat
		core.position = Vector3(0.0, sy * 0.62, 0.0)
		add_child(core)
		_core = core

	elif kind == "powerplant":
		# 发电站：两根排烟管 + 顶部橙色能量球
		for i in 2:
			var stack := MeshInstance3D.new()
			var stack_mesh := CylinderMesh.new()
			stack_mesh.top_radius = 0.22
			stack_mesh.bottom_radius = 0.3
			stack_mesh.height = sy * 1.25
			stack.mesh = stack_mesh
			stack.material_override = frame_mat
			stack.position = Vector3(-sx * 0.22 + float(i) * sx * 0.44, sy * 0.95, 0.0)
			add_child(stack)
		var orb := MeshInstance3D.new()
		var orb_mesh := SphereMesh.new()
		orb_mesh.radius = sx * 0.16
		orb_mesh.height = sx * 0.32
		orb.mesh = orb_mesh
		orb.material_override = glow_mat
		orb.position = Vector3(0.0, sy + 0.25, 0.0)
		add_child(orb)
		_core = orb
	elif kind == "battery":
		# 储能站：三颗叠起来的发光电池块
		for i in 3:
			var cell := MeshInstance3D.new()
			var cell_mesh := BoxMesh.new()
			cell_mesh.size = Vector3(sx * 0.42, sy * 0.2, sz * 0.42)
			cell.mesh = cell_mesh
			cell.material_override = glow_mat
			cell.position = Vector3(0.0, sy * (0.25 + float(i) * 0.26), 0.0)
			add_child(cell)
		_ring = null
	elif kind == "turret":
		# 哨戒炮塔：底座 + 可转动的炮管
		var turret_base := MeshInstance3D.new()
		var base_mesh := CylinderMesh.new()
		base_mesh.top_radius = sx * 0.34
		base_mesh.bottom_radius = sx * 0.4
		base_mesh.height = sy * 0.28
		turret_base.mesh = base_mesh
		turret_base.material_override = body_mat
		turret_base.position = Vector3(0.0, sy * 0.18, 0.0)
		add_child(turret_base)

		var head := Node3D.new()
		head.position = Vector3(0.0, sy * 0.34, 0.0)
		add_child(head)
		var barrel := MeshInstance3D.new()
		var barrel_mesh := CylinderMesh.new()
		barrel_mesh.top_radius = 0.075
		barrel_mesh.bottom_radius = 0.09
		barrel_mesh.height = sx * 0.8
		barrel.mesh = barrel_mesh
		barrel.material_override = frame_mat
		barrel.rotation.x = PI * 0.5
		barrel.position = Vector3(0.0, 0.0, -sx * 0.4)
		head.add_child(barrel)
		_crane = head

	elif kind == "radar":
		# 雷达站：旋转的抛物面天线（用扁球 + 支柱凑）
		var mast := MeshInstance3D.new()
		var mast_mesh := CylinderMesh.new()
		mast_mesh.top_radius = 0.07
		mast_mesh.bottom_radius = 0.1
		mast_mesh.height = sy * 1.1
		mast.mesh = mast_mesh
		mast.material_override = frame_mat
		mast.position = Vector3(0.0, sy * 0.72, 0.0)
		add_child(mast)
		var dish := MeshInstance3D.new()
		var dish_mesh := SphereMesh.new()
		dish_mesh.radius = sx * 0.3
		dish_mesh.height = sx * 0.4
		dish.mesh = dish_mesh
		dish.material_override = glow_mat
		dish.position = Vector3(0.0, sy * 1.2, 0.0)
		dish.rotation.x = -0.5
		add_child(dish)
		_core = dish
	elif kind == "repairbay":
		# 维修厂：顶上一个发光的十字
		var bar_a := MeshInstance3D.new()
		var bar_a_mesh := BoxMesh.new()
		bar_a_mesh.size = Vector3(sx * 0.5, 0.12, 0.12)
		bar_a.mesh = bar_a_mesh
		bar_a.material_override = glow_mat
		bar_a.position = Vector3(0.0, sy + 0.2, 0.0)
		add_child(bar_a)
		var bar_b := MeshInstance3D.new()
		var bar_b_mesh := BoxMesh.new()
		bar_b_mesh.size = Vector3(0.12, 0.12, sz * 0.5)
		bar_b.mesh = bar_b_mesh
		bar_b.material_override = glow_mat
		bar_b.position = Vector3(0.0, sy + 0.2, 0.0)
		add_child(bar_b)

	elif kind == "storage":
		# 仓库：三层货箱
		for i in 3:
			var crate := MeshInstance3D.new()
			var crate_mesh := BoxMesh.new()
			crate_mesh.size = Vector3(sx * 0.55, sy * 0.22, sz * 0.55)
			crate.mesh = crate_mesh
			crate.material_override = frame_mat if i % 2 == 0 else body_mat
			crate.position = Vector3(0.0, sy * (0.2 + float(i) * 0.28), 0.0)
			add_child(crate)
	elif kind == "refinery":
		# 精炼厂：粗管道 + 顶部出料口
		for i in 2:
			var pipe := MeshInstance3D.new()
			var pipe_mesh := CylinderMesh.new()
			pipe_mesh.top_radius = 0.16
			pipe_mesh.bottom_radius = 0.22
			pipe_mesh.height = sy * 1.1
			pipe.mesh = pipe_mesh
			pipe.material_override = frame_mat
			pipe.position = Vector3(-sx * 0.2 + float(i) * sx * 0.4, sy * 0.8, -sz * 0.15)
			add_child(pipe)
		var vent := MeshInstance3D.new()
		var vent_mesh := BoxMesh.new()
		vent_mesh.size = Vector3(sx * 0.4, 0.14, sz * 0.4)
		vent.mesh = vent_mesh
		vent.material_override = glow_mat
		vent.position = Vector3(0.0, sy + 0.18, 0.0)
		add_child(vent)

	elif kind == "commandpost":
		# 指挥中心：尖顶塔 + 顶部信号灯
		var tower := MeshInstance3D.new()
		var tower_mesh := CylinderMesh.new()
		tower_mesh.top_radius = 0.1
		tower_mesh.bottom_radius = sx * 0.3
		tower_mesh.height = sy * 1.3
		tower.mesh = tower_mesh
		tower.material_override = body_mat
		tower.position = Vector3(0.0, sy * 0.75, 0.0)
		add_child(tower)
		var beacon := MeshInstance3D.new()
		var beacon_mesh := SphereMesh.new()
		beacon_mesh.radius = sx * 0.12
		beacon_mesh.height = sx * 0.24
		beacon.mesh = beacon_mesh
		beacon.material_override = glow_mat
		beacon.position = Vector3(0.0, sy * 1.45, 0.0)
		add_child(beacon)
		_core = beacon
	elif kind == "conveyor":
		# 传送带：矮平台 + 三条发光滚道
		var base := MeshInstance3D.new()
		var base_mesh := BoxMesh.new()
		base_mesh.size = Vector3(sx * 0.9, 0.12, sz * 0.9)
		base.mesh = base_mesh
		base.material_override = body_mat
		base.position = Vector3(0.0, 0.08, 0.0)
		add_child(base)
		for i in 3:
			var belt := MeshInstance3D.new()
			var belt_mesh := BoxMesh.new()
			belt_mesh.size = Vector3(sx * 0.8, 0.05, 0.12)
			belt.mesh = belt_mesh
			belt.material_override = glow_mat
			belt.position = Vector3(0.0, 0.16, -sz * 0.28 + float(i) * sz * 0.28)
			add_child(belt)
	elif kind == "shield":
		# 护盾发生器：中间一个大圆球罩
		var dome := MeshInstance3D.new()
		var dome_mesh := SphereMesh.new()
		dome_mesh.radius = sx * 0.34
		dome_mesh.height = sx * 0.68
		dome.mesh = dome_mesh
		var dome_mat: StandardMaterial3D = MatCache.of(Color(0.5, 0.8, 1.0), true, 0.7, true, 0.35)
		dome.material_override = dome_mat
		dome.position = Vector3(0.0, sy * 0.55, 0.0)
		add_child(dome)
		_core = dome
	elif kind == "jammertower":
		# 干扰塔：三圈旋转的环
		var last_ring: MeshInstance3D = null
		for i in 3:
			var ring_i := MeshInstance3D.new()
			var ring_mesh := TorusMesh.new()
			ring_mesh.inner_radius = sx * (0.16 + 0.05 * float(i))
			ring_mesh.outer_radius = sx * (0.2 + 0.05 * float(i))
			ring_i.mesh = ring_mesh
			ring_i.material_override = glow_mat
			ring_i.rotation.x = PI * 0.5 * float(i) * 0.4
			ring_i.position = Vector3(0.0, sy * (0.5 + 0.2 * float(i)), 0.0)
			add_child(ring_i)
			last_ring = ring_i
		_ring = last_ring

	# 碰撞体（占满整个格子，单位撞不进去）
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(sx, sy, sz)
	shape.shape = box_shape
	body.add_child(shape)
	body.position = Vector3(0.0, sy * 0.5, 0.0)
	add_child(body)


## 施工中：剖面从地面往上推进（像 3D 打印机那样一层层长起来），建完恢复正常外观
func _update_build_progress() -> void:
	if build_total <= 0.0:
		_set_construction_look(false)
		return
	var progress: float = clampf(1.0 - build_left / build_total, 0.0, 1.0)
	_set_construction_look(progress < 0.999)
	_refresh_badge()
	if _construction and _construction_mat != null:
		# base_cell.y 是建筑底面所在格，顶面 = base_cell.y + size.y
		var base_y: float = float(base_cell.y)
		_construction_mat.set_shader_parameter("cut_y", base_y + progress * float(size.y))


## 占地体积里不能有方块（要和地面/别的方块"不重叠"）
func has_clear_volume() -> bool:
	if world == null:
		return true
	for dx in range(size.x):
		for dy in range(size.y):
			for dz in range(size.z):
				if world.is_solid(Vector3i(base_cell.x + dx, base_cell.y + dy, base_cell.z + dz)):
					return false
	return true


## 被方块占住时也罢工（外观和缺地基一样是红的，只是原因不同）
func set_blocked_look(on: bool, by_unit: bool = false) -> void:
	if on == _blocked and by_unit == _blocked_by_unit:
		return
	_blocked = on
	_blocked_by_unit = by_unit
	_apply_strike_look(_blocked or _unsupported)
	_refresh_badge()


func is_blocked_by_unit() -> bool:
	return _blocked_by_unit


func is_blocked() -> bool:
	return _blocked


## 缺电停工外观（和缺地基一样的红色罢工，但头顶图标是"停机"）
func set_stalled_look(on: bool) -> void:
	if on == _stalled:
		return
	_stalled = on
	_apply_strike_look(_blocked or _unsupported or _stalled)
	_refresh_badge()


func is_stalled() -> bool:
	return _stalled


## 罢工外观：整楼偏红发暗；恢复时按「施工中 / 正常」重新套用正确外观
func _apply_strike_look(on: bool) -> void:
	if on:
		_construction = false
		var tint: StandardMaterial3D = MatCache.of(Color(0.9, 0.25, 0.2), true, 0.5, false, 0.85)
		for m in _all_meshes():
			_saved_materials[m] = m.material_override
			m.material_override = tint
		return
	for m in _saved_materials.keys():
		if is_instance_valid(m):
			m.material_override = _saved_materials[m]
	_saved_materials.clear()
	_construction = false
	_update_build_progress()


## 施工中的样子：半透明青色 + 从下往上的剖面切割 + 切口发光
func _set_construction_look(on: bool) -> void:
	if on == _construction:
		return
	_construction = on
	if on:
		if _construction_mat == null:
			_construction_mat = ShaderMaterial.new()
			_construction_mat.shader = ConstructionShader
		_construction_mat.set_shader_parameter("tint", Color(0.42, 0.84, 1.0, 1.0))
		_construction_mat.set_shader_parameter("alpha", 0.5)
		for m in _all_meshes():
			_saved_materials[m] = m.material_override
			m.material_override = _construction_mat
	else:
		for m in _saved_materials.keys():
			if is_instance_valid(m):
				m.material_override = _saved_materials[m]
		_saved_materials.clear()


## 地基缺失时的样子：整楼偏红发暗，提醒"这里罢工了"
func set_unsupported_look(on: bool) -> void:
	if on == _unsupported:
		return
	_unsupported = on
	_apply_strike_look(_blocked or _unsupported or _stalled)
	_refresh_badge()


func is_unsupported() -> bool:
	return _unsupported


## 屋顶图标：施工中不显示；罢工时按原因显示「地基不牢」或「被埋住」
func _refresh_badge() -> void:
	if _badge == null:
		return
	var kind: int = StatusBadges.Kind.NONE
	if is_under_construction():
		kind = StatusBadges.Kind.NONE
	elif _blocked_by_unit:
		kind = StatusBadges.Kind.OCCUPIED
	elif _blocked:
		kind = StatusBadges.Kind.BURIED
	elif _unsupported:
		kind = StatusBadges.Kind.FOUNDATION
	elif _stalled:
		kind = StatusBadges.Kind.STALLED
	StatusBadges.set_kind(_badge, kind)
	if kind != StatusBadges.Kind.NONE:
		var cam: Camera3D = get_viewport().get_camera_3d()
		_badge.visible = cam != null and cam.global_position.distance_to(global_position) < 90.0
		var bob := sin(_anim_t * 3.0) * 0.06
		_badge.position = Vector3(0.0, float(size.y) + 0.9 + bob, 0.0)


func _all_meshes() -> Array:
	var out: Array = []
	var stack: Array = [self]
	while not stack.is_empty():
		var node = stack.pop_back()
		if node is MeshInstance3D:
			out.append(node)
		for child in node.get_children():
			stack.append(child)
	return out


func is_under_construction() -> bool:
	return build_left > 0.0


func _spawn_smoke() -> void:
	var p := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.1
	mesh.height = 0.2
	p.mesh = mesh
	p.material_override = MatCache.of(Color(0.75, 0.78, 0.82), true, 0.0, false, 0.35)
	p.position = _smoke_anchor
	add_child(p)
	_smoke.append({"node": p, "life": 0.0})


func _animate(delta: float) -> void:
	_anim_t += delta
	if _badge != null and _badge.visible:
		_refresh_badge()
	# 烟囱冒烟
	if _smoke_anchor != Vector3.ZERO and not is_under_construction():
		_smoke_t -= delta
		if _smoke_t <= 0.0:
			_smoke_t = 0.35
			_spawn_smoke()
		for i in range(_smoke.size() - 1, -1, -1):
			var item: Dictionary = _smoke[i]
			item["life"] = float(item["life"]) + delta
			var node: MeshInstance3D = item["node"]
			if not is_instance_valid(node):
				_smoke.remove_at(i)
				continue
			if float(item["life"]) > 1.8:
				node.queue_free()
				_smoke.remove_at(i)
				continue
			node.position.y += delta * 0.55
			node.position.x += delta * 0.12 * sin(float(item["life"]) * 3.0)
			var k: float = 1.0 + float(item["life"]) * 0.9
			node.scale = Vector3(k, k, k)
	# 充电站：感应环转 + 核心呼吸
	if _ring != null:
		_ring.rotation.y += delta * 2.0
	if _core != null:
		var s: float = 1.0 + 0.08 * sin(_anim_t * 3.0)
		_core.scale = Vector3(s, s, s)


func _process(delta: float) -> void:
	_animate(delta)
	if _drill_bit != null:
		_drill_bit.rotation.y += delta * 6.0
	if _crane != null:
		_crane.rotation.y += delta * 1.2


## 地基检查：占地范围内每一格的正下方都必须是实心方块，缺一格就停工
func has_support() -> bool:
	if world == null:
		return true
	for dx in range(size.x):
		for dz in range(size.z):
			var cell := Vector3i(base_cell.x + dx, base_cell.y - 1, base_cell.z + dz)
			if not world.is_solid(cell):
				return false
	return true


## 缺地基时格子坐标（用来提示玩家；没缺就返回 Vector3i(-1,-1,-1)）
func missing_support_cell() -> Vector3i:
	if world == null:
		return Vector3i(-1, -1, -1)
	for dx in range(size.x):
		for dz in range(size.z):
			var cell := Vector3i(base_cell.x + dx, base_cell.y - 1, base_cell.z + dz)
			if not world.is_solid(cell):
				return cell
	return Vector3i(-1, -1, -1)


## 炮塔之类的可转动部件朝目标转过去
func face_target(point: Vector3) -> void:
	if _crane == null:
		return
	var local: Vector3 = to_local(point)
	_crane.rotation.y = atan2(-local.x, -local.z)


## 这座厂能生产哪些单位
func production_options() -> Array:
	return def.get("options", []) if def.has("options") else ([str(def.get("unit", ""))] if def.has("unit") else [])


## 切换生产目标（step = +1 下一个 / -1 上一个），返回切换后的单位 id
func cycle_production(step: int = 1) -> String:
	var opts: Array = production_options()
	if opts.is_empty():
		return ""
	var idx := opts.find(produce_id)
	if idx < 0:
		idx = 0
	else:
		idx = posmod(idx + step, opts.size())
	produce_id = str(opts[idx])
	return produce_id


## 指定生产目标（不在选项里就返回错误字符串）
func set_production(unit_id: String) -> String:
	var opts: Array = production_options()
	if opts.is_empty():
		return "这种建筑不能生产单位"
	if not opts.has(unit_id):
		return "这里不能生产 %s" % unit_id
	produce_id = unit_id
	return ""


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
