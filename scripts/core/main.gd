extends Node3D
## 游戏入口：搭建世界、相机、HUD 与方块交互。

const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const CameraRig = preload("res://scripts/player/camera_rig.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const UnitDB = preload("res://scripts/units/unit_db.gd")
const Flyer = preload("res://scripts/units/flyer.gd")
const UnitController = preload("res://scripts/units/unit_controller.gd")
const DefaultCode = preload("res://scripts/units/unit_code_default.gd")
const CodePanel = preload("res://scripts/ui/code_panel.gd")
const Economy = preload("res://scripts/economy/economy.gd")
const Production = preload("res://scripts/economy/production.gd")
const BuildingDB = preload("res://scripts/buildings/building_db.gd")
const Building = preload("res://scripts/buildings/building.gd")
const TerrainGen = preload("res://scripts/world/terrain_gen.gd")

const WORLD_SIZE_X := 256
const WORLD_SIZE_Z := 256
const WORLD_HEIGHT := 64
const WORLD_SEED := 20261108
const REACH := 8.0

var db: BlockDB
var world: VoxelWorld
var rig: CameraRig
var hud: Hud
var block_options: Array[int] = []
var selected := 0

var unit_db: UnitDB
var code_panel: CodePanel
var economy: Economy
var production: Production
var building_db: BuildingDB
## 已有的建筑：{def_id, node, team, kind, timer}
var buildings: Array = []
var selected_building := 0
const MAX_BUILDINGS := 12
## 开局资源（还没做采集经济闭环前的启动资金）
const STARTING_RESOURCES := {"copper": 120, "coal": 60}
## 队伍
const TEAM_BLUE := 0
const TEAM_RED := 1
## 红方脚本单位（M5 先放 3 台当对手）
const RED_START := [{"x": 226.0, "z": 108.0}, {"x": 232.0, "z": 128.0}, {"x": 226.0, "z": 150.0}]
## 激光钻头打单位：每秒伤害 / 有效距离
const DRILL_DAMAGE_PER_SEC := 45.0
const DRILL_UNIT_RANGE := 3.2
## 每项：{uid, unit, controller, code, revision, team, cost}
var units: Array = []
var _next_uid := 1
var game_over := ""
var _physics_frames := 0
var units_root: Node3D
var buildings_root: Node3D
## 预设单位 + 玩家代码（现在还没有编辑器，先用默认代码）
const MAX_UNITS := 20
const START_UNITS := [{"id": "feifei", "x": 34.0, "z": 128.0, "code": DefaultCode.FLYER_SOURCE}]

var _highlight: MeshInstance3D
var _highlight_material: StandardMaterial3D
var _highlight_array := ArrayMesh.new()
var _last_cell := Vector3i(999999, 999999, 999999)


func _ready() -> void:
	db = BlockDB.new()
	var problem := db.load_dir("res://data/blocks")
	if problem != "":
		push_error(problem)
		return
	for def in db.defs:
		if def.id != BlockDB.AIR:
			block_options.append(def.id)
	selected = 0

	world = VoxelWorld.new()
	world.name = "World"
	add_child(world)
	world.setup(db, WORLD_SEED, WORLD_SIZE_X, WORLD_SIZE_Z, WORLD_HEIGHT)
	_install_environment()

	rig = CameraRig.new()
	rig.name = "CameraRig"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.far = 400.0
	camera.near = 0.05
	camera.current = true
	rig.add_child(camera)
	add_child(rig)
	rig.primary_click.connect(_on_primary_click)

	var spawn := Vector3(30.0, 0.0, WORLD_SIZE_Z * 0.5)
	var h := world.surface_height(int(spawn.x), int(spawn.z))
	rig.position = Vector3(spawn.x, float(h) + 16.0, spawn.z)
	rig.yaw = -1.5708
	world.prefetch(rig.position, 20)

	economy = Economy.new()
	economy.setup(db, STARTING_RESOURCES)
	production = Production.new()
	production.setup(economy)
	# 一个示例配方：3 煤 + 1 铜 → 30 秒产 1 块「电池」（M4 先打通链路，具体数值后面调）
	production.add_recipe("battery", {"coal": 3, "copper": 1}, {"battery": 1}, 30.0)

	units_root = Node3D.new()
	units_root.name = "Units"
	add_child(units_root)
	_setup_units()

	building_db = BuildingDB.new()
	var building_problem := building_db.load_dir("res://data/buildings")
	if building_problem != "":
		push_error(building_problem)
	buildings_root = Node3D.new()
	buildings_root.name = "Buildings"
	add_child(buildings_root)

	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)

	code_panel = CodePanel.new()
	code_panel.name = "CodePanel"
	add_child(code_panel)
	code_panel.apply_pressed.connect(_on_code_applied)
	code_panel.unit_selected.connect(_on_unit_selected)
	code_panel.panel_closed.connect(_on_panel_closed)
	_highlight = MeshInstance3D.new()
	_highlight.name = "BlockHighlight"
	_highlight_material = StandardMaterial3D.new()
	_highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_material.albedo_color = Color(0.1, 0.1, 0.1, 0.9)
	_highlight_material.no_depth_test = false
	_highlight.mesh = _highlight_array
	_highlight.material_override = _highlight_material
	add_child(_highlight)
	_refresh_hud()


func _setup_units() -> void:
	unit_db = UnitDB.new()
	var problem := unit_db.load_dir("res://data/units")
	if problem != "":
		push_error(problem)
		return
	for spec in START_UNITS:
		var def: Dictionary = unit_db.get_def(str(spec["id"]))
		if def.is_empty():
			push_error("找不到预设单位：%s" % spec["id"])
			continue
		_spawn_unit(def, Vector3(float(spec["x"]), 0.0, float(spec["z"])), str(spec["code"]), TEAM_BLUE)
	for spec in RED_START:
		var red_def: Dictionary = unit_db.get_def("feifei")
		if red_def.is_empty():
			break
		_spawn_unit(red_def, Vector3(float(spec["x"]), 0.0, float(spec["z"])), DefaultCode.RED_SOURCE, TEAM_RED)


func _spawn_unit(def: Dictionary, at: Vector3, code: String, team: int = TEAM_BLUE) -> void:
	var flyer := Flyer.new()
	flyer.name = "%s_%d" % [str(def.get("id", "unit")), units.size() + 1]
	units_root.add_child(flyer)
	var ground := world.surface_height(int(at.x), int(at.z))
	flyer.global_position = Vector3(at.x, float(ground) + 6.0, at.z)
	flyer.setup(world, def)
	flyer.team = team
	# 蓝方面朝 +X、红方面朝 -X
	flyer.rotation.y = -PI * 0.5 if team == TEAM_BLUE else PI * 0.5
	var controller := UnitController.new()
	controller.bind(flyer, code, 1)
	units.append({"uid": _next_uid, "unit": flyer, "controller": controller, "code": code, "revision": 1, "team": team, "cost": economy.unit_cost(def) if economy != null else {}})
	_next_uid += 1
	flyer.name = "%s_%d" % [str(def.get("id", "unit")), int(units[units.size() - 1]["uid"])]


func _cost_text(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	for kind in cost:
		parts.append("%s %d" % [str(kind), int(cost[kind])])
	return "、".join(parts)


func _entry_by_uid(uid: int) -> Dictionary:
	for entry in units:
		if int(entry["uid"]) == uid:
			return entry
	return {}


func _panel_open() -> bool:
	return code_panel != null and code_panel.is_open()


func _toggle_code_panel() -> void:
	if code_panel == null:
		return
	if code_panel.is_open():
		code_panel.close()
		return
	var items: Array = []
	for entry in units:
		var flyer: Flyer = entry["unit"]
		var controller: UnitController = entry["controller"]
		items.append({
			"uid": int(entry["uid"]),
			"label": ("蓝 " if int(entry.get("team", TEAM_BLUE)) == TEAM_BLUE else "红 ") + flyer.name,
			"error": controller.last_error() if controller.halted() else "",
		})
	code_panel.set_units(items)
	if not units.is_empty():
		var first: Dictionary = units[0]
		code_panel.set_code(int(first["uid"]), str(first["code"]))
	code_panel.open()
	rig.input_enabled = false


func _on_code_applied(uid: int, code: String) -> void:
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	entry["code"] = code
	entry["revision"] = int(entry["revision"]) + 1
	var controller: UnitController = entry["controller"]
	controller.bind(entry["unit"], code, int(entry["revision"]))
	code_panel.show_error(controller.last_error())
	code_panel.show_status("已应用（版本 %d）" % int(entry["revision"]))


func _on_unit_selected(uid: int) -> void:
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	code_panel.set_code(uid, str(entry["code"]))


func _on_panel_closed() -> void:
	rig.input_enabled = true


func _update_code_panel() -> void:
	if code_panel == null or not code_panel.is_open():
		return
	var uid := code_panel.current_uid()
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	var flyer: Flyer = entry["unit"]
	var controller: UnitController = entry["controller"]
	var altitude := flyer.global_position.y - float(world.surface_height(floori(flyer.global_position.x), floori(flyer.global_position.z)))
	code_panel.show_status("%s ｜ 高度 %.1f 米 ｜ 电量 %.0f%% ｜ 代码版本 %d" % [flyer.name, altitude, flyer.energy_j / flyer.energy_max * 100.0, int(entry["revision"])])
	if controller.halted():
		code_panel.show_error(controller.last_error())
	else:
		code_panel.show_error("")
	code_panel.show_logs(controller.logs)


func _physics_process(delta: float) -> void:
	_physics_frames += 1
	if production != null:
		production.tick(delta)
	_refresh_enemy_sensors()
	_tick_buildings(delta)
	for entry in units:
		var controller: UnitController = entry["controller"]
		controller.tick(delta)
	_process_combat(delta)
	_purge_dead()
	_check_victory()


## 把敌方单位的位置塞给每个单位的传感器（按距离排序，最近的前 8 个）
func _refresh_enemy_sensors() -> void:
	for entry in units:
		var self_unit: Flyer = entry["unit"]
		if not self_unit.alive:
			continue
		var enemy_team: int = TEAM_BLUE if int(entry.get("team", TEAM_BLUE)) == TEAM_RED else TEAM_RED
		var found: Array = []
		for other in team_units(enemy_team):
			var o: Flyer = other["unit"]
			found.append({
				"x": o.global_position.x,
				"y": o.global_position.y,
				"z": o.global_position.z,
				"d": self_unit.global_position.distance_to(o.global_position),
			})
		found.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
		var top: Array = found.slice(0, 8)
		for item in top:
			item.erase("d")
		var controller: UnitController = entry["controller"]
		controller.set_enemies(top)


## ---------------- 建筑（M4：挖矿 / 产单位） ----------------


func building_ids() -> Array[String]:
	return building_db.order if building_db != null else [] as Array[String]


func _current_building_id() -> String:
	var ids := building_ids()
	if ids.is_empty():
		return ""
	return ids[clampi(selected_building, 0, ids.size() - 1)]


func _cycle_building(step: int) -> void:
	var ids := building_ids()
	if ids.is_empty():
		return
	selected_building = (selected_building + step + ids.size()) % ids.size()
	_refresh_hud()
	hud.show_message("当前建筑：%s（%d/%d）" % [str(building_db.get_def(ids[selected_building]).get("display_name", ids[selected_building])), selected_building + 1, ids.size()])


## 建筑占位是否合法：在自己那半边、地形上方、占位格全空、不与已有建筑重叠
func _building_placement(at_cell: Vector3i, team: int, size: Vector3i) -> Dictionary:
	var reason := ""
	if buildings.size() >= MAX_BUILDINGS:
		return {"ok": false, "reason": "建筑数量上限 %d" % MAX_BUILDINGS}
	if team == TEAM_BLUE and at_cell.x + size.x > TerrainGen.ZONE_A_END:
		reason = "只能在自己的半场建造"
	elif team == TEAM_RED and at_cell.x < TerrainGen.ZONE_B_START:
		reason = "只能在自己的半场建造"
	if reason == "":
		for dx in size.x:
			for dz in size.z:
				var cell := Vector3i(at_cell.x + dx, at_cell.y, at_cell.z + dz)
				if not world.in_bounds(cell) or at_cell.y + size.y > world.size_y:
					reason = "超出世界边界"
					break
				for dy in size.y:
					if world.get_block(Vector3i(cell.x, at_cell.y + dy, cell.z)) != BlockDB.AIR:
						reason = "地盘被方块占了，先挖空"
						break
				if reason != "":
					break
			if reason != "":
				break
	if reason == "":
		for entry in buildings:
			var node = entry["node"]
			for dy in size.y:
				if node.occupies(Vector3i(at_cell.x, at_cell.y + dy, at_cell.z)) \
						or node.occupies(Vector3i(at_cell.x + size.x - 1, at_cell.y + dy, at_cell.z + size.z - 1)):
					reason = "和已有建筑重叠"
					break
			if reason != "":
				break
	return {"ok": reason == "", "reason": reason}


func _place_building() -> void:
	if building_db == null or buildings.size() >= MAX_BUILDINGS:
		hud.show_message("建筑数量上限 %d" % MAX_BUILDINGS)
		return
	var def_id := _current_building_id()
	if def_id == "":
		return
	var def: Dictionary = building_db.get_def(def_id)
	var cost: Dictionary = building_db.cost_of(def_id)
	if not economy.can_afford(cost):
		hud.show_message("资源不足：%s" % _cost_text(cost))
		return
	var size: Vector3i = building_db.size_of(def_id)
	var hit := _aim()
	if hit.is_empty():
		hud.show_message("准星指着地面再放建筑")
		return
	var base := Vector3i(hit["cell"]) + Vector3i(hit["normal"])
	var problem := place_building_at(def_id, base, TEAM_BLUE)
	if problem != "":
		hud.show_message(problem)
		return
	hud.show_message("建好 %s（%s）" % [str(def.get("display_name", def_id)), _cost_text(cost)])


## 程序化放置（输入处理和测试共用）：成功返回空串，失败返回原因
func place_building_at(def_id: String, base: Vector3i, team: int = TEAM_BLUE) -> String:
	if building_db == null or not building_db.has(def_id):
		return "没有这种建筑：%s" % def_id
	var def: Dictionary = building_db.get_def(def_id)
	var cost: Dictionary = building_db.cost_of(def_id)
	var size: Vector3i = building_db.size_of(def_id)
	if not economy.can_afford(cost):
		return "资源不足：%s" % _cost_text(cost)
	var check := _building_placement(base, team, size)
	if not check["ok"]:
		return str(check["reason"])
	economy.spend(cost)
	var node := Building.new()
	node.name = "building_%d" % (buildings.size() + 1)
	buildings_root.add_child(node)
	node.setup(world, def, base, team)
	buildings.append({"id": def_id, "node": node, "team": team, "timer": 0.0, "cost": cost})
	return ""


func _remove_last_building() -> void:
	if buildings.is_empty():
		hud.show_message("还没有建筑")
		return
	var entry: Dictionary = buildings.pop_back()
	var node = entry["node"]
	node.queue_free()
	economy.refund(entry["cost"])
	hud.show_message("拆掉一栋建筑，资源已退回")


func _tick_buildings(delta: float) -> void:
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		entry["timer"] = float(entry["timer"]) + delta
		var def: Dictionary = building_db.get_def(str(entry["id"]))
		var kind := str(def.get("kind", ""))
		var period := maxf(float(def.get("period", 1.0)), 0.01)
		if float(entry["timer"]) < period:
			continue
		entry["timer"] = 0.0
		if kind == "miner":
			_mine_with(node, def)
		elif kind == "factory":
			_produce_unit(node)


func _mine_with(node, def: Dictionary) -> void:
	var center: Vector3i = node.center_cell()
	var depth := int(def.get("mine_depth", 10))
	for i in depth:
		var cell := Vector3i(center.x, center.y - 1 - i, center.z)
		if not world.in_bounds(cell):
			return
		var block_id := world.get_block(cell)
		if block_id == BlockDB.AIR:
			continue
		if block_id == db.id_of("bedrock"):
			return
		var drop := economy.mine_block(block_id)
		world.set_block(cell, BlockDB.AIR)
		node.produced += 1
		if drop != "":
			hud.show_message("采矿机挖到 %s" % drop)
		return


func _produce_unit(node) -> void:
	var def: Dictionary = building_db.get_def(str(node.def.get("id", "")))
	var unit_id := str(def.get("unit", "feifei"))
	var unit_def: Dictionary = unit_db.get_def(unit_id)
	if unit_def.is_empty():
		return
	if units.size() >= MAX_UNITS:
		return
	var cost: Dictionary = economy.unit_cost(unit_def)
	if not economy.can_afford(cost):
		return
	economy.spend(cost)
	var point: Vector3 = node.spawn_point()
	_spawn_unit(unit_def, point, DefaultCode.FLYER_SOURCE, int(node.team))
	node.produced += 1
	hud.show_message("组装厂下线一台 %s" % str(unit_def.get("display_name", unit_id)))


func team_units(team: int) -> Array:
	var out: Array = []
	for entry in units:
		var flyer: Flyer = entry["unit"]
		if int(entry.get("team", TEAM_BLUE)) == team and flyer.alive:
			out.append(entry)
	return out


## 激光钻头打敌方单位：正前方、距离够近、正在钻
func _process_combat(delta: float) -> void:
	for attacker_entry in units:
		var attacker: Flyer = attacker_entry["unit"]
		if not attacker.alive or not bool(attacker.controls.get("drill", false)):
			continue
		if attacker.energy_out:
			continue
		for victim_entry in units:
			var victim: Flyer = victim_entry["unit"]
			if victim == attacker or not victim.alive:
				continue
			if int(victim_entry.get("team", TEAM_BLUE)) == int(attacker_entry.get("team", TEAM_BLUE)):
				continue
			if attacker.global_position.distance_to(victim.global_position) <= DRILL_UNIT_RANGE:
				victim.take_damage(DRILL_DAMAGE_PER_SEC * delta)


func _purge_dead() -> void:
	var survivors: Array = []
	for entry in units:
		var flyer: Flyer = entry["unit"]
		if flyer.alive:
			survivors.append(entry)
		else:
			var node: Node3D = entry["unit"]
			if is_instance_valid(node):
				node.queue_free()
	units = survivors


func _check_victory() -> void:
	if game_over != "":
		return
	if _physics_frames < 30:
		return  # 开局 0.5 秒内不判负，等代码跑起来
	if team_units(TEAM_RED).is_empty():
		game_over = "蓝方胜利"
	elif team_units(TEAM_BLUE).is_empty():
		game_over = "红方胜利"
	if game_over != "":
		hud.show_overlay(game_over + "\n按 R 重开")
		hud.show_message(game_over, 6.0)


func _install_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.55, 0.86)
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_bottom_color = Color(0.55, 0.63, 0.72)
	sky_mat.ground_horizon_color = Color(0.72, 0.82, 0.92)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.32
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.72, 0.82, 0.92)
	env.fog_depth_begin = 150.0
	env.fog_depth_end = 340.0
	env.fog_depth_curve = 1.4
	env.fog_density = 1.0
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(-0.9, 0.7, 0.0)
	sun.light_energy = 0.95
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(sun)


func _process(_delta: float) -> void:
	if world == null or rig == null:
		return
	world.update_streaming(rig.position)
	_update_highlight()
	_update_unit_hud()
	_update_code_panel()


func _update_highlight() -> void:
	var hit := _aim()
	if hit.is_empty():
		_highlight.visible = false
		return
	var cell: Vector3i = hit["cell"]
	_highlight.visible = true
	_highlight.global_position = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	if cell != _last_cell:
		_last_cell = cell
		_build_wire_box(Vector3.ONE * 1.006)


func _build_wire_box(scale: Vector3) -> void:
	var corners := [
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1),
	]
	var edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var verts := PackedVector3Array()
	for edge in edges:
		for index in edge:
			var p: Vector3 = corners[index] - Vector3(0.5, 0.5, 0.5)
			verts.append(Vector3(p.x * scale.x, p.y * scale.y, p.z * scale.z))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	_highlight_array.clear_surfaces()
	_highlight_array.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)


func _aim() -> Dictionary:
	if rig == null or world == null:
		return {}
	var from := rig.camera.global_position
	var to := from + rig.look_direction() * REACH
	return world.raycast(from, to)


func _on_primary_click() -> void:
	if _panel_open():
		return
	var hit := _aim()
	if hit.is_empty():
		return
	var cell: Vector3i = hit["cell"]
	var block_id := world.get_block(cell)
	if block_id == BlockDB.AIR:
		return
	var drop := economy.mine_block(block_id)
	world.set_block(cell, BlockDB.AIR)
	if drop != "":
		hud.show_message("挖到 %s（+1）" % drop)
	_refresh_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		selected = (selected + 1) % block_options.size()
		_refresh_hud()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		selected = (selected - 1 + block_options.size()) % block_options.size()
		_refresh_hud()
	elif event.button_index == MOUSE_BUTTON_RIGHT and rig != null and not _panel_open():
		var hit := _aim()
		if hit.is_empty():
			return
		var cell: Vector3i = hit["cell"] + hit["normal"]
		if not world.in_bounds(cell):
			return
		if db.is_solid(world.get_block(cell)):
			return
		var place_at := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
		if place_at.distance_to(rig.camera.global_position) < 0.9:
			return
		world.set_block(cell, block_options[selected])


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_R and game_over != "":
		get_tree().reload_current_scene()
		return
	if event.keycode == KEY_C:
		_toggle_code_panel()
		return
	if _panel_open():
		return
	if event.keycode == KEY_F:
		_place_unit()
		return
	if event.keycode == KEY_G:
		_remove_last_unit()
		return
	if event.keycode == KEY_Q:
		_cycle_building(-1 if event.shift_pressed else 1)
		return
	if event.keycode == KEY_B:
		_place_building()
		return
	if event.keycode == KEY_N:
		_remove_last_building()
		return
	var index := -1
	if event.keycode >= KEY_1 and event.keycode <= KEY_9:
		index = event.keycode - KEY_1
	if index >= 0 and index < block_options.size():
		selected = index
		_refresh_hud()


## 在准星指到的地方（或眼前空地上方）放一台预设单位
func _place_unit() -> void:
	if unit_db == null:
		return
	if units.size() >= MAX_UNITS:
		hud.show_message("单位数量上限 %d" % MAX_UNITS)
		return
	var def: Dictionary = unit_db.get_def("feifei")
	if def.is_empty():
		return
	var cost: Dictionary = economy.unit_cost(def)
	if not economy.can_afford(cost):
		hud.show_message("资源不足：%s" % _cost_text(cost))
		return
	var at := Vector3.ZERO
	var hit := _aim()
	if not hit.is_empty():
		at = (Vector3(hit["cell"]) + Vector3(0.5, 0.5, 0.5)) + Vector3(0, 1.2, 0)
	else:
		at = rig.camera.global_position + rig.look_direction() * 5.0
	at.x = clampf(at.x, 1.0, float(world.size_x) - 2.0)
	at.z = clampf(at.z, 1.0, float(world.size_z) - 2.0)
	var ground := world.surface_height(floori(at.x), floori(at.z))
	economy.spend(cost)
	_spawn_unit(def, Vector3(at.x, float(ground), at.z), DefaultCode.FLYER_SOURCE)
	hud.show_message("放下飞飞（共 %d 台）" % units.size())
	_refresh_hud()


func _remove_last_unit() -> void:
	if units.is_empty():
		return
	var entry: Dictionary = units.pop_back()
	var node: Node3D = entry["unit"]
	node.queue_free()
	if entry.has("cost"):
		economy.refund(entry["cost"])
	hud.show_message("收回一台飞飞（剩 %d 台）" % units.size())
	_refresh_hud()


func _update_unit_hud() -> void:
	if hud == null or units.is_empty():
		return
	var mine: Array = team_units(TEAM_BLUE)
	if mine.is_empty():
		hud.set_info("你的单位全部被击毁\n按 R 重开")
		hud.set_resources(_resources_text())
		return
	var entry: Dictionary = mine[mine.size() - 1]
	var flyer: Flyer = entry["unit"]
	var controller: UnitController = entry["controller"]
	var text := "我方单位 %d 台 ｜ %s  高度 %.1f 米  电量 %.0f%%" % [mine.size(), flyer.display_name, flyer.global_position.y - float(world.surface_height(floori(flyer.global_position.x), floori(flyer.global_position.z))), flyer.energy_j / flyer.energy_max * 100.0]
	if controller.halted():
		text += "\n代码出错：%s" % controller.last_error()
	hud.set_info(text + "\nC 打开代码面板")
	hud.set_resources(_resources_text())


func _resources_text() -> String:
	var parts: PackedStringArray = []
	var all: Dictionary = economy.all() if economy != null else {}
	for kind in all:
		parts.append("%s %d" % [str(kind), int(all[kind])])
	return "资源：" + ("、".join(parts) if not parts.is_empty() else "无")


func _refresh_hud() -> void:
	if hud == null:
		return
	var def := db.get_def(block_options[selected])
	var building_name := "-"
	var building_id := _current_building_id()
	if building_id != "":
		building_name = str(building_db.get_def(building_id).get("display_name", building_id))
	hud.set_block_name("手持：%s（%d/%d） ｜ 建筑：%s" % [def.display_name if def != null else "?", selected + 1, block_options.size(), building_name])
