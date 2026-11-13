extends Node3D
## 游戏入口：搭建世界、相机、HUD 与方块交互。

const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const CameraRig = preload("res://scripts/player/camera_rig.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const UnitDB = preload("res://scripts/units/unit_db.gd")
const Flyer = preload("res://scripts/units/flyer.gd")
const Rover = preload("res://scripts/units/rover.gd")
const UnitController = preload("res://scripts/units/unit_controller.gd")
const DefaultCode = preload("res://scripts/units/unit_code_default.gd")
const CodePanel = preload("res://scripts/ui/code_panel.gd")
const Economy = preload("res://scripts/economy/economy.gd")
## 两方各一套资源账（玩家看的是蓝方的 economy）
const Production = preload("res://scripts/economy/production.gd")
const BuildingDB = preload("res://scripts/buildings/building_db.gd")
const Building = preload("res://scripts/buildings/building.gd")
const TerrainGen = preload("res://scripts/world/terrain_gen.gd")
const MpManager = preload("res://scripts/net/mp_manager.gd")
const MpPanel = preload("res://scripts/ui/mp_panel.gd")
const MatCache = preload("res://scripts/core/mat_cache.gd")

const WORLD_SIZE_X := 256
const WORLD_SIZE_Z := 256
const WORLD_HEIGHT := 64
## 每局随机地形；想复现某张图可以在命令行加 --world-seed=12345
var world_seed := 0
const REACH := 8.0

var db: BlockDB
var world: VoxelWorld
var rig: CameraRig
var hud: Hud
var block_options: Array[int] = []
var selected := 0

var unit_db: UnitDB
var code_panel: CodePanel
## 联机
var mp: MpManager
var mp_panel: MpPanel
## 客户端编辑过的单位代码缓存：uid -> {code, revision}
var _client_codes: Dictionary = {}
var _world_ready_shown := false
## 地形没建完之前不开始游戏：不生成单位、不响应操作、物理也不跑
var _world_ready := false
var economy: Economy
var economy_red: Economy
var production: Production
var building_db: BuildingDB
## 已有的建筑：{def_id, node, team, kind, timer}
var buildings: Array = []
var mines: Array = []            ## 布雷车埋下的地雷
var _delta_cache := 0.0
var power_pool: Dictionary = {}   ## 每队当前电力储量（team -> float）
var selected_building := 0
## 玩家当前选的预设单位（T 键切换）
var selected_unit := 0
const MAX_BUILDINGS := 12
## 单位刚体所在的物理层（1 << 1）
const UNIT_COLLISION_MASK := 2
const DOUBLE_CLICK_MS := 400
## 开局资源（还没做采集经济闭环前的启动资金）
const STARTING_RESOURCES := {"copper": 200, "coal": 200, "iron": 40, "gold": 10}
## 队伍
const TEAM_BLUE := 0
const TEAM_RED := 1
## 红方脚本单位：开局 1 台，跟蓝方 1 台对打
const RED_START := [{"x": 221.0, "z": 128.0}]
## 开局发育时间（秒）：这段时间双方都不能互相攻击，只能挖矿、造建筑、写代码
const PEACE_SECONDS := 60.0
const SUDDEN_DEATH_SECONDS := 180.0
var peace_left := PEACE_SECONDS
## 激光钻头打单位：每秒伤害 / 有效距离
## 鼠标射线能够多远
const AIM_RANGE := 40.0
const DRILL_DAMAGE_PER_SEC := 30.0
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
const START_UNITS := [{"id": "feifei", "x": 34.0, "z": 128.0, "code": DefaultCode.COMMANDER_SOURCE}]

## 玩家标记的施工/挖掘指令（虚影）：{x, y, z, action, id}
## action：mine 挖一格 / place 放方块 / build 造建筑 / remove 拆建筑
var orders: Array = []
var orders_root: Node3D
## 采矿机只挖这些产出（其他的方块跳过，免得白挖）
const MINER_DROPS := ["coal", "copper", "iron", "gold"]
const ORDER_MINE := "mine"
const ORDER_PLACE := "place"
const ORDER_BUILD := "build"
const ORDER_REMOVE := "remove"
const ORDER_COLOR := {
	"mine": Color(1.0, 0.35, 0.3),
	"place": Color(0.45, 0.95, 0.45),
	"build": Color(0.4, 0.65, 1.0),
	"remove": Color(1.0, 0.75, 0.2),
}
var _ghost_nodes: Array = []

var _highlight: MeshInstance3D
var _highlight_material: StandardMaterial3D
var _highlight_array := ArrayMesh.new()
var _last_cell := Vector3i(999999, 999999, 999999)
var _last_click_uid := -1
var _last_click_time := 0


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
	world_seed = _pick_world_seed()
	world.setup(db, world_seed, WORLD_SIZE_X, WORLD_SIZE_Z, WORLD_HEIGHT)
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
	# 不在这里同步建完 256 个区块（会冻住 4 秒多），改成每帧按预算建，配一个进度提示
	world.update_streaming(rig.position)

	economy = Economy.new()
	economy.setup(db, STARTING_RESOURCES)
	economy_red = Economy.new()
	economy_red.setup(db, STARTING_RESOURCES)
	production = Production.new()
	production.setup(economy)
	# 一个示例配方：3 煤 + 1 铜 → 30 秒产 1 块「电池」（M4 先打通链路，具体数值后面调）
	production.add_recipe("battery", {"coal": 3, "copper": 1}, {"battery": 1}, 30.0)

	units_root = Node3D.new()
	units_root.name = "Units"
	add_child(units_root)
	_load_unit_db()
	if unit_db != null and unit_db.has("feifei"):
		selected_unit = unit_db.order.find("feifei")
	# 单位等世界建好再生（见 _process 里的 _world_ready 分支），否则会掉进没碰撞的空地形里
	rig.input_enabled = false

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
	code_panel.rerun_pressed.connect(_on_code_rerun)

	mp = MpManager.new()
	mp.name = "MpManager"
	add_child(mp)
	mp.world = world
	mp.replicas_root = units_root
	mp.unit_def = unit_db.get_def("feifei")
	mp.units_provider = func(): return _snapshot_units()
	mp.status_changed.connect(_on_mp_status)
	mp.code_from_client.connect(_on_mp_code)
	mp.joined.connect(_on_mp_joined)
	mp_panel = MpPanel.new()
	mp_panel.name = "MpPanel"
	add_child(mp_panel)
	mp_panel.host_requested.connect(_on_mp_host)
	mp_panel.join_requested.connect(_on_mp_join)
	mp_panel.disconnect_requested.connect(_on_mp_disconnect)
	orders_root = Node3D.new()
	orders_root.name = "Orders"
	add_child(orders_root)

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
	hud.set_loading_mode(true)


## ---------------- 建筑血量 / 能源 / 炮塔 ----------------

## 建筑挨打：血掉光就从列表里移除（节点自己 queue_free）
func _damage_building(node: Node3D, amount: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not node.has_method("take_damage"):
		return
	if shield_absorbs(int(node.team), node.center_world()):
		return
	node.take_damage(amount)
	if node.hp <= 0.0:
		_remove_building(node)


var command_lost: Array = [false, false]   ## 每队指挥中心有没有被拆掉

func _remove_building(node: Node3D) -> void:
	for i in range(buildings.size() - 1, -1, -1):
		if buildings[i]["node"] == node:
			buildings.remove_at(i)
			break
	if str(node.def.get("id", "")) == "commandpost" and int(node.team) >= 0 and int(node.team) < 2:
		command_lost[int(node.team)] = true
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()
	if hud != null:
		hud.show_message("一栋建筑被摧毁了")


## 射线与敌方建筑求交（逐个建筑做 AABB），返回 {building, point}
func _building_ray_hit(from: Vector3, dir: Vector3, max_dist: float, attacker_team: int) -> Dictionary:
	var best_t := max_dist
	var best: Dictionary = {}
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive:
			continue
		if int(node.team) == attacker_team:
			continue
		if node.is_under_construction():
			continue
		var bmin: Vector3 = Vector3(node.base_cell)
		var bmax: Vector3 = Vector3(node.base_cell) + Vector3(node.size)
		var hit_t: float = _ray_aabb(from, dir, bmin, bmax)
		if hit_t < 0.0 or hit_t > best_t:
			continue
		best_t = hit_t
		best = {"building": node, "point": from + dir * hit_t}
	return best


## 射线与轴对齐盒子求交（slab 法），返回进入距离；不命中返回 -1
func _ray_aabb(from: Vector3, dir: Vector3, bmin: Vector3, bmax: Vector3) -> float:
	var tmin := -INF
	var tmax := INF
	for i in 3:
		var d: float = dir[i]
		var o: float = from[i]
		if absf(d) < 0.00001:
			if o < bmin[i] or o > bmax[i]:
				return -1.0
			continue
		var t1: float = (bmin[i] - o) / d
		var t2: float = (bmax[i] - o) / d
		if t1 > t2:
			var swap: float = t1
			t1 = t2
			t2 = swap
		if t1 > tmin:
			tmin = t1
		if t2 < tmax:
			tmax = t2
		if tmin > tmax:
			return -1.0
	if tmax < 0.0:
		return -1.0
	if tmin < 0.0:
		return 0.0
	return tmin


const POWER_BASE_CAP := 120.0

const BASE_RESOURCE_CAP := 400.0
const STORAGE_CAP_BONUS := 600.0

## 每队资源上限：基础 400，每座仓库 +600
func storage_cap(team: int) -> int:
	var cap := BASE_RESOURCE_CAP
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or int(node.team) != team:
			continue
		if str(entry["id"]) == "storage" and not node.is_under_construction():
			cap += int(STORAGE_CAP_BONUS)
	return int(cap)


## 把上限套到两队经济账本上（仓库建好/被拆后自动变化）
func _sync_economy_caps() -> void:
	for team in [TEAM_BLUE, TEAM_RED]:
		var cap := storage_cap(team)
		var table := {"copper": cap, "coal": cap, "iron": cap, "gold": cap, "steel": cap, "battery": cap}
		_economy_for(team).set_caps(table)


## 精炼厂：铁矿 + 煤 → 钢
func _run_refinery(node, def: Dictionary) -> void:
	var team_economy = _economy_for(int(node.team))
	if not use_power(int(node.team), float(def.get("power_draw", 15.0))):
		node.set_stalled_look(true)
		return
	var inputs: Dictionary = def.get("inputs", {})
	var outputs: Dictionary = def.get("outputs", {})
	if not team_economy.spend(inputs):
		node.set_stalled_look(true)
		return
	node.set_stalled_look(false)
	for kind in outputs.keys():
		team_economy.add(str(kind), int(outputs[kind]))
	node.produced += 1


## 货运飞飞：把自身电量输送给附近缺电的友军
func _process_cargo_transfers(delta: float) -> void:
	if in_peace():
		return
	for entry in units:
		var carrier: RigidBody3D = entry["unit"]
		if not is_instance_valid(carrier) or not carrier.alive:
			continue
		if not bool(carrier.controls.get("transfer", false)):
			continue
		var budget: float = carrier.transfer_rate_j * delta
		if budget <= 0.0:
			continue
		for other in units:
			if budget <= 0.01 or carrier.energy_j <= 0.0:
				break
			var target: RigidBody3D = other["unit"]
			if target == carrier or not is_instance_valid(target) or not target.alive:
				continue
			if int(target.team) != int(carrier.team):
				continue
			if target.energy_j >= target.energy_max:
				continue
			if carrier.global_position.distance_to(target.global_position) > carrier.transfer_radius:
				continue
			var give: float = minf(budget, target.energy_max - target.energy_j)
			give = minf(give, carrier.energy_j)
			if give <= 0.0:
				continue
			target.energy_j += give
			target.energy_out = target.energy_j <= 0.0
			carrier.energy_j -= give
			budget -= give


## 单位技能：自爆 / 布雷 / 维修 / 供电光环 / 干扰
func _process_unit_abilities(delta: float) -> void:
	var mines_alive: Array = []
	# 地雷先结算：敌人踩到就炸
	for mine in mines:
		if not _step_mine(mine, delta):
			continue
		mines_alive.append(mine)
	mines = mines_alive

	for entry in units:
		var u: RigidBody3D = entry["unit"]
		if not is_instance_valid(u) or not u.alive:
			continue
		var def: Dictionary = entry.get("def", {})
		var my_team := int(entry.get("team", TEAM_BLUE))
		# 自爆无人机：靠近敌人就炸
		if float(def.get("explode_damage", 0.0)) > 0.0:
			var trigger := float(def.get("explode_unit_range", 2.5))
			for other in units:
				var target: RigidBody3D = other["unit"]
				if target == u or not is_instance_valid(target) or not target.alive:
					continue
				if int(target.team) == my_team:
					continue
				if u.global_position.distance_to(target.global_position) <= trigger:
					_explode_unit(u, def, my_team)
					break
			continue
		# 布雷车：每隔 mine_interval 秒在自己脚下埋一颗雷
		if float(def.get("mine_interval", 0.0)) > 0.0 and u.alive:
			var cooldown: float = float(entry.get("mine_cd", 0.0)) - delta
			if cooldown <= 0.0:
				cooldown = float(def.get("mine_interval", 2.0))
				_drop_mine(u, def, my_team)
			entry["mine_cd"] = cooldown
		# 维修无人机：给附近友军回血
		if float(def.get("repair_rate", 0.0)) > 0.0:
			var radius := float(def.get("repair_radius", 9.0))
			var heal_rate := float(def.get("repair_rate", 14.0))
			for other in units:
				var friend: RigidBody3D = other["unit"]
				if not is_instance_valid(friend) or not friend.alive or int(friend.team) != my_team:
					continue
				if friend.hp >= friend.max_hp:
					continue
				if u.global_position.distance_to(friend.global_position) > radius:
					continue
				friend.hp = minf(friend.max_hp, friend.hp + heal_rate * delta)
		# 平台无人机：给附近友军回电
		if float(def.get("aura_power", 0.0)) > 0.0:
			var aura := float(def.get("aura_radius", 14.0))
			var gain := float(def.get("aura_power", 9000.0)) * delta
			for other in units:
				var friend: RigidBody3D = other["unit"]
				if friend == u or not is_instance_valid(friend) or not friend.alive:
					continue
				if int(friend.team) != my_team or friend.energy_j >= friend.energy_max:
					continue
				if u.global_position.distance_to(friend.global_position) > aura:
					continue
				friend.energy_j = minf(friend.energy_max, friend.energy_j + gain)


## 自爆：对半径内所有敌方单位 + 建筑造成伤害，然后自己消失
func _explode_unit(u: RigidBody3D, def: Dictionary, team: int) -> void:
	if not is_instance_valid(u) or not u.alive:
		return
	var radius := float(def.get("explode_radius", 6.0))
	var damage := float(def.get("explode_damage", 150.0))
	var center := u.global_position
	for other in units:
		var target: RigidBody3D = other["unit"]
		if target == u or not is_instance_valid(target) or not target.alive:
			continue
		if int(target.team) == team:
			continue
		var dist := center.distance_to(target.global_position)
		if dist > radius:
			continue
		var falloff := clampf(1.0 - dist / radius, 0.35, 1.0)
		target.take_damage(damage * falloff)
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or int(node.team) == team:
			continue
		if center.distance_to(node.center_world()) <= radius:
			_damage_building(node, damage * 0.8)
	u.take_damage(100000.0)


## 布雷车放雷
func _drop_mine(u: RigidBody3D, def: Dictionary, team: int) -> void:
	var mine := {
		"pos": u.global_position - Vector3(0.0, 0.5, 0.0),
		"team": team,
		"radius": float(def.get("mine_radius", 4.0)),
		"damage": float(def.get("mine_damage", 120.0)),
		"arm": float(def.get("mine_arm_time", 1.0)),
		"node": null,
	}
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.22
	mesh.height = 0.3
	marker.mesh = mesh
	marker.material_override = MatCache.of(Color(1.0, 0.35, 0.25), true, 0.8)
	marker.position = mine["pos"]
	marker.set_meta("mine", true)
	mine["node"] = marker
	add_child(marker)
	mines.append(mine)


## 地雷结算：有人踩到就炸；返回 true 表示这颗雷还在
func _step_mine(mine: Dictionary, delta: float) -> bool:
	var arm := float(mine.get("arm", 1.0)) - delta
	mine["arm"] = arm
	if arm > 0.0:
		return true
	var pos: Vector3 = mine["pos"]
	var team := int(mine["team"])
	for entry in units:
		var u: RigidBody3D = entry["unit"]
		if not is_instance_valid(u) or not u.alive or int(u.team) == team:
			continue
		if u.global_position.distance_to(pos) > 1.6:
			continue
		var radius := float(mine["radius"])
		var damage := float(mine["damage"])
		for other in units:
			var victim: RigidBody3D = other["unit"]
			if not is_instance_valid(victim) or not victim.alive or int(victim.team) == team:
				continue
			var dist := pos.distance_to(victim.global_position)
			if dist <= radius:
				victim.take_damage(damage * clampf(1.0 - dist / radius, 0.3, 1.0))
		for bentry in buildings:
			var node = bentry["node"]
			if not is_instance_valid(node) or not node.alive or int(node.team) == team:
				continue
			if pos.distance_to(node.center_world()) <= radius:
				_damage_building(node, damage * 0.5)
		if mine["node"] != null and is_instance_valid(mine["node"]):
			mine["node"].queue_free()
		return false
	return true


## 传送带：给附近的矿机/组装厂加速
func conveyor_boost(node) -> float:
	var bonus := 0.0
	for entry in buildings:
		var other = entry["node"]
		if other == node or not is_instance_valid(other) or not other.alive:
			continue
		if str(entry["id"]) != "conveyor" or other.is_under_construction():
			continue
		if int(other.team) != int(node.team):
			continue
		if other.center_world().distance_to(node.center_world()) > 6.0:
			continue
		bonus += float(other.def.get("boost", 0.3))
	return minf(bonus, 0.9)


## 队伍里有没有通电的雷达站（有就共享视野）
## 某队伍已经建好的某类建筑数量（AI 用来判断"有没有维修厂/充电站"）
func facility_count(team: int, kind: String) -> int:
	var n := 0
	for entry in buildings:
		var node = entry.get("node")
		if node == null or not is_instance_valid(node) or not node.alive:
			continue
		if int(node.team) != team:
			continue
		if node.is_under_construction() or node.is_stalled():
			continue
		if str(entry.get("id", "")) == kind:
			n += 1
	return n


func team_has_radar(team: int) -> bool:
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or int(node.team) != team:
			continue
		if str(entry["id"]) == "radar" and not node.is_under_construction() and not node.is_stalled():
			return true
	return false


func team_radar_range(team: int) -> float:
	var best := 0.0
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or int(node.team) != team:
			continue
		if str(entry["id"]) != "radar" or node.is_under_construction() or node.is_stalled():
			continue
		best = maxf(best, float(building_db.get_def("radar").get("radar_range", 30.0)))
	return best


## 雷达站维持运转要电；维修厂给半径内友军补血
func _run_radar(node, def: Dictionary) -> void:
	if not use_power(int(node.team), float(def.get("power_draw", 6.0))):
		node.set_stalled_look(true)
		return
	node.set_stalled_look(false)


func _run_repairbay(node, def: Dictionary) -> void:
	if not use_power(int(node.team), float(def.get("power_draw", 8.0))):
		node.set_stalled_look(true)
		return
	node.set_stalled_look(false)
	var radius := float(def.get("radius", 12.0))
	var heal := float(def.get("heal", 6.0))
	var center: Vector3 = node.center_world()
	for entry in units:
		var unit: RigidBody3D = entry["unit"]
		if not is_instance_valid(unit) or not unit.alive:
			continue
		if int(unit.team) != int(node.team):
			continue
		if unit.global_position.distance_to(center) > radius:
			continue
		if unit.hp >= unit.max_hp:
			continue
		unit.hp = minf(unit.max_hp, unit.hp + heal)
		node.produced += 1


## 坐标是否被本队护盾罩住；罩住就按伤害消耗电力来吸收
func shield_absorbs(team: int, point: Vector3) -> bool:
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or int(node.team) != team:
			continue
		if str(entry["id"]) != "shield":
			continue
		if node.is_under_construction() or node.is_stalled():
			continue
		var radius := float(building_db.get_def("shield").get("radius", 16.0))
		if node.center_world().distance_to(point) > radius:
			continue
		# 吸收一发要电
		if not use_power(team, 8.0):
			node.set_stalled_look(true)
			return false
		return true
	return false


## 全队当前电力储量
func power_of(team: int) -> float:
	return float(power_pool.get(team, 0.0))


## 全队电力上限：基础 120 + 每座储能站的容量
func power_cap(team: int) -> float:
	var cap := POWER_BASE_CAP
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive or int(node.team) != team:
			continue
		if str(entry["id"]) == "battery":
			cap += float(building_db.get_def("battery").get("capacity", 600.0))
	return cap


func add_power(team: int, amount: float) -> void:
	power_pool[team] = minf(power_cap(team), power_of(team) + amount)


## 花电：不够就返回 false（建筑因此罢工）
func use_power(team: int, amount: float) -> bool:
	if power_of(team) < amount:
		return false
	power_pool[team] = power_of(team) - amount
	return true


## 发电站：烧煤换电
func _run_powerplant(node, def: Dictionary) -> void:
	var team_economy = _economy_for(int(node.team))
	var fuel := str(def.get("fuel", "coal"))
	var amount := int(def.get("fuel_amount", 1))
	if not team_economy.spend({fuel: amount}):
		node.set_stalled_look(true)
		return
	node.set_stalled_look(false)
	add_power(int(node.team), float(def.get("power_out", 120.0)))
	node.produced += 1


## 哨戒炮塔：打范围内最近的敌方单位（要消耗电）
func _run_turret(node, def: Dictionary) -> void:
	var radius := float(def.get("range", 14.0))
	var center: Vector3 = node.center_world() + Vector3(0.0, float(node.size.y) * 0.5, 0.0)
	var target: RigidBody3D = null
	var best_dist := radius
	for entry in units:
		var unit: RigidBody3D = entry["unit"]
		if not is_instance_valid(unit) or not unit.alive:
			continue
		if int(unit.team) == int(node.team):
			continue
		var dist: float = unit.global_position.distance_to(center)
		if dist < best_dist:
			best_dist = dist
			target = unit
	if target == null:
		return
	if best_dist > 0.01:
		var blocked_hit: Dictionary = world.raycast(center, target.global_position) if world != null else {}
		if not blocked_hit.is_empty():
			var hit_dist: float = center.distance_to(blocked_hit["point"])
			if hit_dist < best_dist - 0.8:
				return
	if not use_power(int(node.team), float(def.get("power_draw", 20.0))):
		node.set_stalled_look(true)
		return
	node.set_stalled_look(false)
	node.face_target(target.global_position)
	if not shield_absorbs(int(target.team), target.global_position):
		target.take_damage(float(def.get("damage", 42.0)))
	node.produced += 1


## ---------------- 联机 ----------------

## 主机：把当前所有单位的可同步状态打包给快照
func _snapshot_units() -> Array:
	var out: Array = []
	for entry in units:
		var u: RigidBody3D = entry["unit"]
		if not u.alive:
			continue
		out.append({
			"uid": int(entry["uid"]),
			"team": int(entry["team"]),
			"pos": u.global_position,
			"vel": u.linear_velocity,
			"yaw": u.rotation.y,
			"energy": u.energy_j,
		})
	return out


## 代码：客户端取本地缓存，主机取本单位代码
func _code_of(uid: int) -> String:
	if mp != null and mp.is_client():
		return str(_client_codes.get(uid, {}).get("code", DefaultCode.FLYER_SOURCE))
	var entry := _entry_by_uid(uid)
	if not entry.is_empty():
		return str(entry["code"])
	return str(_client_codes.get(uid, {}).get("code", DefaultCode.FLYER_SOURCE))


func _on_mp_host() -> void:
	var err := mp.host_game()
	if err == "":
		hud.show_message("房间已开，等别人加入（M 打开面板）")


func _on_mp_join(address: String) -> void:
	if address == "":
		hud.show_message("请先填主机 IP")
		return
	var err := mp.join_game(address)
	if err == "":
		hud.show_message("正在连接 %s …" % address)


func _on_mp_status(text: String) -> void:
	if mp_panel != null:
		mp_panel.set_status(text)
	if hud != null:
		hud.show_message(text)


func _on_mp_joined(team: int) -> void:
	_client_codes.clear()
	# 客户端只看主机同步过来的单位，本地模拟的那些先藏起来（它们不再被更新）
	for entry in units:
		var local: RigidBody3D = entry["unit"]
		local.visible = false
	hud.show_message("已加入房间：你是%s方（C 打开代码面板）" % ("蓝" if team == TEAM_BLUE else "红"))


func _on_mp_disconnect() -> void:
	if mp == null:
		return
	var was_client := mp.is_client()
	mp.stop()
	if was_client:
		# 断开后回到单机：重载场景最省事
		get_tree().reload_current_scene()
	else:
		hud.show_message("已关闭房间")


## 主机：收到客户端改的代码，绑定到对应单位上
func _on_mp_code(uid: int, revision: int, source: String) -> void:
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	entry["code"] = source
	entry["revision"] = revision
	var controller: UnitController = entry["controller"]
	controller.bind(entry["unit"], source, revision)


## 单位表在 _ready 里就加载好（组装厂、联机、测试都要用），真正的生成放 _start_game
func _load_unit_db() -> void:
	unit_db = UnitDB.new()
	var problem := unit_db.load_dir("res://data/units")
	if problem != "":
		push_error(problem)


func _setup_units() -> void:
	if unit_db == null:
		_load_unit_db()
	if unit_db != null and unit_db.has("feifei"):
		selected_unit = unit_db.order.find("feifei")
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
		_spawn_unit(red_def, Vector3(float(spec["x"]), 0.0, float(spec["z"])), DefaultCode.COMMANDER_SOURCE, TEAM_RED)


## 按单位表里的 id 造对应的节点：车车是地面车，其余默认飞飞
func _make_unit_node(def: Dictionary) -> RigidBody3D:
	# 有 ground 标记的单位用地面载具实现（车车 / 布雷车）
	if str(def.get("id", "")) == "rover" or bool(def.get("ground", false)):
		return Rover.new()
	return Flyer.new()


func _spawn_unit(def: Dictionary, at: Vector3, code: String, team: int = TEAM_BLUE) -> void:
	var unit := _make_unit_node(def)
	unit.name = "%s_%d" % [str(def.get("id", "unit")), units.size() + 1]
	units_root.add_child(unit)
	var ground := world.surface_height(int(at.x), int(at.z))
	unit.global_position = Vector3(at.x, float(ground) + 6.0, at.z)
	unit.team = team
	unit.uid = _next_uid
	# 红方补偿：完全对称的 AI 对局里红方略吃亏（先手框架/遍历顺序），给一点血量补偿拉平胜率
	if team == TEAM_RED:
		unit.max_hp *= 1.10
		unit.hp = unit.max_hp
	unit.setup(world, def)
	# 蓝方面朝 +X、红方面朝 -X
	unit.rotation.y = -PI * 0.5 if team == TEAM_BLUE else PI * 0.5
	var controller := UnitController.new()
	controller.is_leader = team_units(team).is_empty()
	controller.build_provider = func(def_id: String, cell: Vector3i) -> String:
		return place_building_at(def_id, cell, team)
	controller.build_here_provider = func(def_id: String) -> String:
		return build_near(def_id, unit.global_position, team)
	controller.place_provider = func(kind: String, cell: Vector3i) -> String:
		return place_block_for(unit, kind, cell)
	unit.gun_fired.connect(_on_gun_fired)
	unit.block_dug.connect(_on_block_dug)
	controller.bind(unit, code, 1)
	units.append({"uid": _next_uid, "unit": unit, "controller": controller, "code": code, "revision": 1, "team": team, "cost": _economy_for(team).unit_cost(def) if economy != null else {}, "def": def})
	_next_uid += 1
	unit.name = "%s_%d" % [str(def.get("id", "unit")), int(units[units.size() - 1]["uid"])]


## 在自己附近找一块平地盖建筑（给单位代码的 build_here 用）
func build_near(def_id: String, near: Vector3, team: int) -> String:
	if building_db == null or not building_db.has(def_id):
		return "没有这种建筑：%s" % def_id
	var size: Vector3i = building_db.size_of(def_id)
	var base := Vector3i(floori(near.x), floori(near.y), floori(near.z))
	# 从近到远找一个「地面平坦、上方全空」的位置
	for radius in range(0, 13):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var x: int = base.x + dx
				var z: int = base.z + dz
				if x < 2 or z < 2 or x + size.x >= world.size_x - 1 or z + size.z >= world.size_z - 1:
					continue
				var top := world.surface_height(x, z)
				var flat := true
				for ox in size.x:
					for oz in size.z:
						if world.surface_height(x + ox, z + oz) != top:
							flat = false
				if not flat:
					continue
				var cell := Vector3i(x, top, z)
				var err := place_building_at(def_id, cell, team)
				if err == "":
					return ""
				# 位置被占就继续往远处找
	return "附近找不到平地"

## 取某支队伍的资源账（红方也是独立的一套）
func _economy_for(team: int):
	if team == TEAM_RED and economy_red != null:
		return economy_red
	return economy


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


## 正在代码框里打字（面板开着并且焦点在编辑器里）——这时才锁住游戏操作
func _code_typing() -> bool:
	return code_panel != null and code_panel.is_open() and code_panel.editor_has_focus()


## 每帧同步：不在打字就恢复 WASD/挖掘等操作
func _update_debug_hud() -> void:
	if hud == null or rig == null or not hud.debug_label.visible:
		return
	hud.set_debug("鼠标模式 %d ｜ 按下 %s ｜ 拖动 %s ｜ yaw %.2f ｜ 输入 %s ｜ FOV %.0f" % [
		Input.mouse_mode, str(rig._pressing), str(rig.dragging), rig.yaw,
		str(rig.input_enabled), rig.fov
	])


func _sync_wheel_state() -> void:
	if rig == null:
		return
	rig.wheel_blocked = code_panel != null and code_panel.is_open() and code_panel.mouse_over()


func _sync_input_state() -> void:
	if rig == null:
		return
	rig.input_enabled = not _code_typing()


func _toggle_code_panel(force_open: bool = false) -> void:
	if code_panel == null:
		return
	if code_panel.is_open() and not force_open:
		code_panel.close()
		return
	# 只列本方单位，敌方代码不给看
	var items: Array = []
	if mp != null and mp.is_client():
		for rep in mp.replicas():
			if int(rep["team"]) != mp.my_team:
				continue
			var node: RigidBody3D = rep["node"]
			items.append({"uid": int(rep["uid"]), "label": node.name, "error": ""})
	else:
		for entry in units:
			if int(entry.get("team", TEAM_BLUE)) != TEAM_BLUE:
				continue
			var flyer: RigidBody3D = entry["unit"]
			var controller: UnitController = entry["controller"]
			items.append({
				"uid": int(entry["uid"]),
				"label": flyer.name,
				"error": controller.last_error() if controller.halted() else "",
			})
	code_panel.set_units(items)
	if not items.is_empty():
		var first_uid: int = int(items[0]["uid"])
		code_panel.set_code(first_uid, _code_of(first_uid))
	code_panel.open()


func _on_code_applied(uid: int, code: String) -> void:
	if mp != null and mp.is_client():
		_client_codes[uid] = {"code": code, "revision": int(_client_codes.get(uid, {}).get("revision", 0)) + 1}
		var rev := int(_client_codes[uid]["revision"])
		mp.send_code(uid, rev, code)
		code_panel.show_status("已发送到主机（版本 %d）" % rev)
		return
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	entry["code"] = code
	entry["revision"] = int(entry["revision"]) + 1
	var controller: UnitController = entry["controller"]
	controller.bind(entry["unit"], code, int(entry["revision"]))
	code_panel.show_error(controller.last_error())
	code_panel.show_status("已应用（版本 %d）" % int(entry["revision"]))


## 重新运行：丢弃当前运行状态、从头再跑一遍（mem 也会清空）
func _on_code_rerun(uid: int) -> void:
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	entry["revision"] = int(entry["revision"]) + 1
	var controller: UnitController = entry["controller"]
	controller.bind(entry["unit"], str(entry["code"]), int(entry["revision"]))
	code_panel.show_status("已重新运行（版本 %d）" % int(entry["revision"]))
	code_panel.show_error(controller.last_error())
	code_panel.show_logs([])


func _on_unit_selected(uid: int) -> void:
	if mp != null and mp.is_client():
		code_panel.set_code(uid, _code_of(uid))
		return
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
	if mp != null and mp.is_client():
		var found := false
		for rep in mp.replicas():
			if int(rep["uid"]) == uid:
				found = true
				code_panel.show_status("%s ｜ 联机中（位置来自主机）" % str(rep["node"].name))
		if not found:
			code_panel.show_status("联机中：等主机分配单位…")
		return
	var entry := _entry_by_uid(uid)
	if entry.is_empty():
		return
	var flyer: RigidBody3D = entry["unit"]
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
	_delta_cache = delta
	if mp != null:
		if mp.is_client():
			# 客户端只是看：单位位置全部来自主机快照，本地不跑战斗/生产
			mp.tick(delta)
			return
		if mp.is_host():
			mp.tick(delta)
	if production != null:
		production.tick(delta)
	_prune_orders()
	_refresh_enemy_sensors()
	_tick_buildings(delta)
	_tick_peace(delta)
	for entry in units:
		var controller: UnitController = entry["controller"]
		var self_unit: RigidBody3D = entry["unit"]
		if self_unit.alive:
			controller.set_orders(orders_for(self_unit.global_position))
			controller.set_peace(peace_left)
			var team_res: Dictionary = _economy_for(int(entry.get("team", TEAM_BLUE))).all()
			team_res["power"] = int(power_of(int(entry.get("team", TEAM_BLUE))))
			team_res["repair"] = facility_count(int(entry.get("team", TEAM_BLUE)), "repairbay")
			team_res["charger"] = facility_count(int(entry.get("team", TEAM_BLUE)), "charger")
			controller.set_resources(team_res)
			controller.sudden = _damage_scale() > 1.001
		controller.tick(delta)
	# 武器：发育时间里也能挖方块（只对单位断伤）；贴身钻头战斗只在开打后结算
	_process_cargo_transfers(delta)
	_process_unit_abilities(delta)
	_refresh_jamming()
	_process_weapons(delta)
	if not in_peace():
		_process_combat(delta)
	_flush_damage()
	_purge_dead()
	_check_victory()


## ---------------- 开局发育时间 ----------------

## 是否还在发育时间（60 秒内双方不能互相攻击）
func in_peace() -> bool:
	return peace_left > 0.0


## 跳过发育时间（测试和调试用）
func skip_peace() -> void:
	peace_left = 0.0
	_peace_label_seconds = -1
	if hud != null:
		hud.set_peace("", -1.0)


func _tick_peace(delta: float) -> void:
	if peace_left <= 0.0:
		return
	peace_left = maxf(0.0, peace_left - delta)
	if peace_left <= 0.0:
		if hud != null:
			hud.set_peace("", -1.0)
			hud.show_message("发育时间结束，可以开打了", 4.0)
		return
	# 每秒刷新一次倒计时显示
	var seconds := int(ceil(peace_left))
	if seconds != _peace_label_seconds:
		_peace_label_seconds = seconds
		if hud != null:
			hud.set_peace("发育时间 %d 秒（双方不能互相攻击）" % seconds, peace_left / PEACE_SECONDS)


var _peace_label_seconds := -1


## ---------------- 武器：激光（5 格）与炮管（15 格） ----------------

## 命中判定用的单位半径（米）
const WEAPON_UNIT_RADIUS := 0.45

## 方块受击累计伤害：Vector3i -> float（方块血量见 BlockDB.hp_of）
var _block_damage: Dictionary = {}
var _pending_damage: Dictionary = {}


func _process_weapons(delta: float) -> void:
	# 发育时间内只禁「打单位」，激光挖方块照常（不然发育期没法挖矿攒资源）
	for entry in units:
		var u: RigidBody3D = entry["unit"]
		if not u.alive:
			continue
		_resolve_laser(u, delta)
	_flush_damage()


## 激光：朝玩家给的方向打一条 5 格光束，对第一个碰到的方块/单位持续伤害
func _resolve_laser(u: RigidBody3D, delta: float) -> void:
	if not u.laser_on:
		u.clear_laser()
		return
	var from: Vector3 = u.muzzle_world()
	var dir: Vector3 = u.laser_target - from
	if dir.length() < 0.001:
		dir = u.forward_dir()
	dir = dir.normalized()
	var max_len: float = u.laser_reach
	var end: Vector3 = from + dir * max_len
	var block_hit: Dictionary = world.raycast(from, end) if world != null else {}
	var block_t := max_len
	var block_cell := Vector3i.ZERO
	var limit: float = max_len
	if not block_hit.is_empty():
		block_t = from.distance_to(block_hit["point"])
		block_cell = block_hit["cell"]
		limit = block_t
	var unit_hit: Dictionary = {} if in_peace() else _unit_ray_hit(u, from, dir, limit)
	var reach := limit
	if not unit_hit.is_empty():
		reach = from.distance_to(unit_hit["point"])
	var building_hit: Dictionary = {} if in_peace() else _building_ray_hit(from, dir, reach, int(u.team))
	if not building_hit.is_empty():
		end = building_hit["point"]
		_damage_building(building_hit["building"], u.laser_dps_unit * delta)
		u.laser_hits += 1
	elif not unit_hit.is_empty():
		end = unit_hit["point"]
		var victim: RigidBody3D = unit_hit["unit"]
		_queue_damage(victim, u.laser_dps_unit * delta)
		u.laser_hits += 1
	elif not block_hit.is_empty():
		end = block_hit["point"]
		_damage_block(block_cell, u.laser_dps_block * delta, int(u.team))
	u.draw_laser(from, end)


## 单位用钻头挖掉方块：蓝方拿到资源
func _on_block_dug(unit: RigidBody3D, cell: Vector3i, block_id: int) -> void:
	if economy == null:
		return
	if int(unit.team) != TEAM_BLUE:
		return
	var drop := economy.mine_block(block_id)
	if drop != "":
		hud.show_message("飞飞挖到 %s" % drop)
	_prune_orders()


## 炮弹命中结算：沿射击方向找第一个碰到的方块/单位
func _on_gun_fired(u: RigidBody3D, from: Vector3, dir: Vector3) -> void:
	var max_len: float = u.gun_reach
	var end: Vector3 = from + dir * max_len
	var block_hit: Dictionary = world.raycast(from, end) if world != null else {}
	var limit := max_len
	var block_cell := Vector3i.ZERO
	if not block_hit.is_empty():
		limit = from.distance_to(block_hit["point"])
		block_cell = block_hit["cell"]
	var unit_hit: Dictionary = {} if in_peace() else _unit_ray_hit(u, from, dir, limit)
	var reach := limit
	if not unit_hit.is_empty():
		reach = from.distance_to(unit_hit["point"])
	var building_hit: Dictionary = {} if in_peace() else _building_ray_hit(from, dir, reach, int(u.team))
	if not building_hit.is_empty():
		end = building_hit["point"]
		_damage_building(building_hit["building"], u.gun_damage_unit)
	elif not unit_hit.is_empty():
		end = unit_hit["point"]
		var victim: RigidBody3D = unit_hit["unit"]
		if not shield_absorbs(int(victim.team), victim.global_position):
			_queue_damage(victim, u.gun_damage_unit)
	elif not block_hit.is_empty():
		end = block_hit["point"]
		_damage_block(block_cell, u.gun_damage_block, int(u.team))
	u.draw_tracer(from, end)


## 射线与敌方单位求交（球体近似），返回最近命中 {unit, point}，没命中返回空字典
func _unit_ray_hit(shooter: RigidBody3D, from: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var best_t := max_dist
	var best: Dictionary = {}
	for entry in units:
		var target: RigidBody3D = entry["unit"]
		if target == shooter or not target.alive or int(target.team) == int(shooter.team):
			continue
		var oc := from - target.global_position
		var b := dir.dot(oc)
		var c := oc.dot(oc) - WEAPON_UNIT_RADIUS * WEAPON_UNIT_RADIUS
		var disc := b * b - c
		if disc < 0.0:
			continue
		var t := -b - sqrt(disc)
		if t < 0.0:
			t = 0.0
		if t > best_t:
			continue
		best_t = t
		best = {"unit": target, "point": from + dir * t}
	return best


## 对某个方块累计伤害；血量打光就挖掉。返回是否打掉了
func _damage_block(cell: Vector3i, amount: float, team: int = -1) -> bool:
	if world == null or amount <= 0.0:
		return false
	var block_id := world.get_block(cell)
	if block_id == BlockDB.AIR:
		return false
	if world.db.name_of(block_id) == "bedrock":
		return false
	var hp := world.db.hp_of(block_id)
	var total := float(_block_damage.get(cell, 0.0)) + amount
	if total >= hp:
		_block_damage.erase(cell)
		world.set_block(cell, BlockDB.AIR)
		if team == TEAM_BLUE and economy != null:
			economy.mine_block(block_id)
		return true
	_block_damage[cell] = total
	return false


## 某个方块已承受的伤害（测试用）
func block_damage_at(cell: Vector3i) -> float:
	return float(_block_damage.get(cell, 0.0))


## 把敌方单位的位置塞给每个单位的传感器（10 米内，按距离排序，最近的前 8 个）
## 敌方干扰塔覆盖到的单位，代码执行速度减半
func _refresh_jamming() -> void:
	var jammers: Array = []
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node) or not node.alive:
			continue
		if str(entry["id"]) != "jammertower" or node.is_under_construction():
			continue
		if node.is_stalled():
			continue
		jammers.append({"pos": node.center_world(), "team": int(node.team), "radius": float(building_db.get_def("jammertower").get("radius", 18.0)), "slow": float(building_db.get_def("jammertower").get("slow", 0.5))})
	# 飞行的干扰机也算
	for entry in units:
		var ju: RigidBody3D = entry["unit"]
		if not is_instance_valid(ju) or not ju.alive:
			continue
		var jdef: Dictionary = entry.get("def", {})
		if float(jdef.get("jam_radius", 0.0)) <= 0.0 or ju.energy_out:
			continue
		jammers.append({"pos": ju.global_position, "team": int(ju.team), "radius": float(jdef.get("jam_radius", 16.0)), "slow": float(jdef.get("jam_slow", 0.55))})
	for entry in units:
		var unit: RigidBody3D = entry["unit"]
		var controller: UnitController = entry["controller"]
		if not is_instance_valid(unit) or not unit.alive:
			continue
		var rate := 1.0
		for jammer in jammers:
			if int(jammer["team"]) == int(unit.team):
				continue
			if (jammer["pos"] as Vector3).distance_to(unit.global_position) <= float(jammer["radius"]):
				rate = minf(rate, float(jammer["slow"]))
		controller.line_rate = rate


func _refresh_enemy_sensors() -> void:
	for entry in units:
		var self_unit: RigidBody3D = entry["unit"]
		if not self_unit.alive:
			continue
		var enemy_team: int = TEAM_BLUE if int(entry.get("team", TEAM_BLUE)) == TEAM_RED else TEAM_RED
		var my_team: int = int(entry.get("team", TEAM_BLUE))
		var sensor_range: float = self_unit.radar_unit_range
		if team_has_radar(my_team):
			sensor_range = maxf(sensor_range, team_radar_range(my_team))
		var found: Array = []
		for other in team_units(enemy_team):
			var o: RigidBody3D = other["unit"]
			if not o.alive:
				continue
			var dist: float = self_unit.global_position.distance_to(o.global_position)
			if dist > sensor_range:
				continue
			found.append({
				"x": o.global_position.x,
				"y": o.global_position.y,
				"z": o.global_position.z,
				"type": o.unit_id,
				"hp": o.hp,
				"dist": dist,
			})
		found.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
		var controller: UnitController = entry["controller"]
		controller.set_enemies(found.slice(0, 8))


## ---------------- 玩家标记（虚影指令） ----------------


## 标记一个格子；已经标过同样的指令就取消它（返回 true 表示这次是"新增"）
func toggle_order(cell: Vector3i, action: String, id: String = "") -> bool:
	var index := order_index_at(cell, action)
	if index >= 0:
		orders.remove_at(index)
		_refresh_order_ghosts()
		return false
	orders.append({"x": cell.x, "y": cell.y, "z": cell.z, "action": action, "id": id})
	_refresh_order_ghosts()
	return true


## 取消某个格子上的指令
func cancel_order(cell: Vector3i, action: String = "") -> bool:
	var removed := false
	for i in range(orders.size() - 1, -1, -1):
		var o: Dictionary = orders[i]
		if int(o["x"]) != cell.x or int(o["y"]) != cell.y or int(o["z"]) != cell.z:
			continue
		if action != "" and str(o["action"]) != action:
			continue
		orders.remove_at(i)
		removed = true
	if removed:
		_refresh_order_ghosts()
	return removed


func order_index_at(cell: Vector3i, action: String) -> int:
	for i in orders.size():
		var o: Dictionary = orders[i]
		if int(o["x"]) == cell.x and int(o["y"]) == cell.y and int(o["z"]) == cell.z and str(o["action"]) == action:
			return i
	return -1


## 某个格子上有没有指令（任意类型）
func order_at(cell: Vector3i) -> Dictionary:
	for o in orders:
		if int(o["x"]) == cell.x and int(o["y"]) == cell.y and int(o["z"]) == cell.z:
			return o
	return {}


func clear_orders() -> void:
	orders.clear()
	_refresh_order_ghosts()


## 给单位代码用的指令列表：按距离排序，每项 {x, y, z, action, id, dist}
func orders_for(pos: Vector3, limit := 8) -> Array:
	var list: Array = []
	for o in orders:
		var p := Vector3(float(o["x"]) + 0.5, float(o["y"]) + 0.5, float(o["z"]) + 0.5)
		list.append({
			"x": int(o["x"]),
			"y": int(o["y"]),
			"z": int(o["z"]),
			"action": str(o["action"]),
			"id": str(o.get("id", "")),
			"dist": pos.distance_to(p),
		})
	list.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
	return list.slice(0, limit)


## 指令已经不需要了（格子空了 / 已经盖了东西 / 建筑没了）就自动清掉
func _prune_orders() -> void:
	var keep: Array = []
	for o in orders:
		var cell := Vector3i(int(o["x"]), int(o["y"]), int(o["z"]))
		match str(o["action"]):
			ORDER_MINE:
				if world.get_block(cell) != BlockDB.AIR:
					keep.append(o)
			ORDER_PLACE:
				if world.get_block(cell) == BlockDB.AIR:
					keep.append(o)
			ORDER_BUILD:
				keep.append(o)
			_:
				keep.append(o)
	if keep.size() != orders.size():
		orders = keep
		_refresh_order_ghosts()


## 重建虚影（半透明方块 + 线框）
func _refresh_order_ghosts() -> void:
	if orders_root == null:
		return
	for node in _ghost_nodes:
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.queue_free()
	_ghost_nodes.clear()
	for o in orders:
		var action := str(o["action"])
		var color: Color = ORDER_COLOR.get(action, Color(1, 1, 1))
		var size := Vector3.ONE * 1.02
		if action == ORDER_BUILD and building_db != null and building_db.has(str(o.get("id", ""))):
			size = Vector3(building_db.size_of(str(o["id"]))) * 1.02
		var ghost := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = size
		ghost.mesh = mesh
		ghost.material_override = MatCache.of(color, true, 0.0, true, 0.4)
		var half := size * 0.5
		ghost.position = Vector3(float(o["x"]), float(o["y"]), float(o["z"])) + half + Vector3(0, 0, 0)
		if action == ORDER_BUILD:
			# 建筑虚影从 base 往上长，所以向上偏移一半
			ghost.position = Vector3(float(o["x"]) + 0.5, float(o["y"]) + size.y * 0.5, float(o["z"]) + 0.5)
		orders_root.add_child(ghost)
		_ghost_nodes.append(ghost)
		# 线框
		var frame := MeshInstance3D.new()
		var frame_mesh := BoxMesh.new()
		frame_mesh.size = size * 1.06
		frame.mesh = frame_mesh
		frame.material_override = MatCache.of(color, true, 0.0, true, 0.85)
		frame.position = ghost.position
		orders_root.add_child(frame)
		_ghost_nodes.append(frame)


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
		# 地面必须平：每一列的地表高度都要正好等于基座高度，否则建筑会一半埋土一半悬空
		for dx in size.x:
			for dz in size.z:
				if world.surface_height(at_cell.x + dx, at_cell.z + dz) != at_cell.y:
					reason = "地面不平，先把这块铺平"
					break
			if reason != "":
				break
	if reason == "":
		# 每一格底下都必须踩实（洞穴/悬空会漏）
		for dx in size.x:
			for dz in size.z:
				if not world.is_solid(Vector3i(at_cell.x + dx, at_cell.y - 1, at_cell.z + dz)):
					reason = "地基下面是空的，先把脚下填实"
					break
			if reason != "":
				break
	if reason == "":
		# 占地范围里不能站着单位（不然单位会被糊进墙里）
		for entry in units:
			var u: RigidBody3D = entry["unit"]
			if not u.alive:
				continue
			var p := u.global_position
			if p.x >= float(at_cell.x) and p.x <= float(at_cell.x + size.x) \
					and p.z >= float(at_cell.z) and p.z <= float(at_cell.z + size.z) \
					and p.y >= float(at_cell.y) - 0.8 and p.y <= float(at_cell.y + size.y) + 0.8:
				reason = "这里有单位挡着，先让它飞走"
				break
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
		# 用 AABB 判重叠，任意一格相交都算（角点检查会漏掉交叉重叠）
		var amin := at_cell
		var amax := at_cell + size
		for entry in buildings:
			var node = entry["node"]
			var bmin: Vector3i = node.base_cell
			var bmax: Vector3i = node.base_cell + node.size
			var overlap := amin.x < bmax.x and amax.x > bmin.x \
					and amin.y < bmax.y and amax.y > bmin.y \
					and amin.z < bmax.z and amax.z > bmin.z
			if overlap:
				reason = "和已有建筑重叠"
				break
	return {"ok": reason == "", "reason": reason}


## 标记一个建筑虚影（真正施工要等单位的代码去做）
func _mark_build_order() -> void:
	if building_db == null:
		return
	var def_id := _current_building_id()
	if def_id == "":
		return
	var def: Dictionary = building_db.get_def(def_id)
	var size: Vector3i = building_db.size_of(def_id)
	var hit := _aim()
	if hit.is_empty():
		hud.show_message("准星指着地面再标建筑")
		return
	var base := Vector3i(hit["cell"]) + Vector3i(hit["normal"])
	var check := _building_placement(base, TEAM_BLUE, size)
	if not check["ok"]:
		hud.show_message(str(check["reason"]))
		return
	if toggle_order(base, ORDER_BUILD, def_id):
		hud.show_message("标记建造 %s（%s）" % [str(def.get("display_name", def_id)), _cost_text(building_db.cost_of(def_id))])
	else:
		hud.show_message("取消标记")


## 标记拆除：准星指着的建筑
func _mark_remove_order() -> void:
	var hit := _aim()
	if hit.is_empty():
		hud.show_message("准星指着要拆的建筑")
		return
	var cell := Vector3i(hit["cell"])
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		if node.occupies(cell):
			if toggle_order(Vector3i(int(node.base_cell.x), int(node.base_cell.y), int(node.base_cell.z)), ORDER_REMOVE, str(entry["id"])):
				hud.show_message("标记拆除 %s" % str(entry["id"]))
			else:
				hud.show_message("取消标记")
			return
	hud.show_message("这里没有建筑")


## 程序化放置（输入处理和测试共用）：成功返回空串，失败返回原因
func place_building_at(def_id: String, base: Vector3i, team: int = TEAM_BLUE) -> String:
	if building_db == null or not building_db.has(def_id):
		return "没有这种建筑：%s" % def_id
	var def: Dictionary = building_db.get_def(def_id)
	var cost: Dictionary = building_db.cost_of(def_id)
	var size: Vector3i = building_db.size_of(def_id)
	if not _economy_for(team).can_afford(cost):
		return "资源不足：%s" % _cost_text(cost)
	var check := _building_placement(base, team, size)
	if not check["ok"]:
		return str(check["reason"])
	_economy_for(team).spend(cost)
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
	_economy_for(int(entry.get("team", TEAM_BLUE))).refund(entry["cost"])
	hud.show_message("拆掉一栋建筑，资源已退回")


func _tick_buildings(delta: float) -> void:
	_sync_economy_caps()
	for entry in buildings:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		# 还在施工（默认 10 秒）不产出：进度按物理帧推进
		# 占地体积里被方块占住了（比如被埋进石头）也罢工，等清出来再继续
		var blocked: bool = not node.has_clear_volume()
		node.set_blocked_look(blocked)
		if blocked:
			continue
		if node.build_left > 0.0:
			node.build_left = maxf(0.0, node.build_left - delta)
			node._update_build_progress()
			continue
		# 地基被挖掉就停工（占地每格下面都要有方块）
		var supported: bool = node.has_support()
		if supported == false:
			node.set_unsupported_look(true)
			continue
		node.set_unsupported_look(false)
		entry["timer"] = float(entry["timer"]) + delta * (1.0 + conveyor_boost(node))
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
		elif kind == "charger":
			_charge_nearby(node, def, period)
		elif kind == "powerplant":
			_run_powerplant(node, def)
		elif kind == "turret":
			_run_turret(node, def)
		elif kind == "radar":
			_run_radar(node, def)
		elif kind == "repairbay":
			_run_repairbay(node, def)
		elif kind == "refinery":
			_run_refinery(node, def)
		elif kind == "shield" or kind == "jammertower":
			if not use_power(int(node.team), float(def.get("power_draw", 12.0))):
				node.set_stalled_look(true)
			else:
				node.set_stalled_look(false)


func _mine_with(node, def: Dictionary) -> void:
	# 采矿机在自己的"矿区"里找矿：以建筑为中心半径 12、深度 mine_depth 的方块体积，
	# 每次扫描一小段（node.scan_cursor 记录进度），找到一块矿就挖掉收进资源，
	# 这样不会把脚下的矿挖完就停工，能一直供矿。
	var depth := int(def.get("mine_depth", 10))
	var radius := int(def.get("mine_radius", 12))
	var center: Vector3i = node.center_cell()
	var bedrock := db.id_of("bedrock")
	var economy = _economy_for(int(node.team))
	var budget := 400
	var span := radius * 2 + 1
	var per_layer := span * span
	var total := per_layer * depth
	var cursor := int(node.scan_cursor)
	while budget > 0 and cursor < total:
		var layer := cursor / per_layer
		var rem := cursor % per_layer
		var ox := rem % span - radius
		var oz := rem / span - radius
		cursor += 1
		budget -= 1
		var cell := Vector3i(center.x + ox, center.y - 1 - layer, center.z + oz)
		# 别把自己脚下的地基挖空（缺一格地基就会停工）
		if cell.x >= node.base_cell.x and cell.x < node.base_cell.x + node.size.x \
				and cell.z >= node.base_cell.z and cell.z < node.base_cell.z + node.size.z:
			continue
		if not world.in_bounds(cell):
			continue
		var block_id := world.get_block(cell)
		if block_id == BlockDB.AIR:
			continue
		if block_id == bedrock:
			continue
		if not MINER_DROPS.has(economy.drop_of(block_id)):
			continue
		var drop := economy.mine_block(block_id)
		world.set_block(cell, BlockDB.AIR)
		node.produced += 1
		node.scan_cursor = cursor
		if drop != "":
			hud.show_message("采矿机挖到 %s" % drop)
		return
	# 扫完一圈就从头再扫（矿会随着地形变化重新出现）
	node.scan_cursor = 0


## 充电站：给半径内同队伍的单位补电
func _charge_nearby(node, def: Dictionary, period: float) -> void:
	var radius := float(def.get("radius", 14.0))
	var power := float(def.get("power_w", 900.0))
	# 充电站要从电网里取电：没电就罢工（头顶显示停机图标）
	if not use_power(int(node.team), float(def.get("power_draw", 24.0))):
		node.set_stalled_look(true)
		return
	node.set_stalled_look(false)
	var center: Vector3 = node.center_world()
	var charged := 0
	for entry in units:
		var unit: Node3D = entry["unit"]
		if not is_instance_valid(unit) or not unit.alive:
			continue
		if int(entry["team"]) != int(node.team):
			continue
		if unit.global_position.distance_to(center) > radius:
			continue
		if unit.energy_j >= unit.energy_max:
			continue
		unit.energy_j = minf(unit.energy_max, unit.energy_j + power * period)
		unit.energy_out = unit.energy_j <= 0.0
		charged += 1
	if charged > 0:
		node.produced += charged


func _produce_unit(node) -> void:
	var def: Dictionary = building_db.get_def(str(node.def.get("id", "")))
	var unit_id := str(def.get("unit", "feifei"))
	var unit_def: Dictionary = unit_db.get_def(unit_id)
	if unit_def.is_empty():
		return
	if units.size() >= MAX_UNITS:
		return
	var team_economy = _economy_for(int(node.team))
	var cost: Dictionary = team_economy.unit_cost(unit_def)
	if not team_economy.can_afford(cost):
		return
	team_economy.spend(cost)
	var point: Vector3 = node.spawn_point()
	_spawn_unit(unit_def, point, _preset_code_for(int(node.team)), int(node.team))
	node.produced += 1
	hud.show_message("组装厂下线一台 %s" % str(unit_def.get("display_name", unit_id)))


## 各队伍的预设代码：蓝方是"指挥官"AI（造建筑 + 滚雪球），红方是简单的战斗 AI
func _preset_code_for(team: int) -> String:
	return DefaultCode.COMMANDER_SOURCE


## 按单位类型选预设代码（工厂产出的单位也用这个）
func _preset_for_unit(def: Dictionary) -> String:
	var uid := str(def.get("id", ""))
	if uid == "builder":
		return DefaultCode.BUILDER_SOURCE
	if uid == "scout":
		return DefaultCode.SCOUT_SOURCE
	if uid == "cargo":
		return DefaultCode.CARGO_SOURCE
	if uid == "gunship":
		return DefaultCode.GUNSHIP_SOURCE
	if uid == "kamikaze":
		return DefaultCode.KAMIKAZE_SOURCE
	if uid == "minelayer":
		return DefaultCode.MINELAYER_SOURCE
	if uid == "repair":
		return DefaultCode.REPAIR_SOURCE
	if uid == "jammer":
		return DefaultCode.JAMMER_SOURCE
	if uid == "burrower":
		return DefaultCode.BURROWER_SOURCE
	if uid == "carrier":
		return DefaultCode.CARRIER_SOURCE
	if uid == "rover":
		return DefaultCode.ROVER_SOURCE
	if uid == "feifei":
		return DefaultCode.FLYER_SOURCE
	return DefaultCode.COMMANDER_SOURCE


## 单位按代码在指定格放一块方块：要扣资源和电量，非法位置返回错误字符串
func place_block_for(unit: RigidBody3D, kind: String, cell: Vector3i) -> String:
	if world == null or db == null:
		return "世界还没准备好"
	var block_id: int = db.id_of(kind)
	if block_id == 0:
		return "没有叫 %s 的方块" % kind
	if not world.in_bounds(cell):
		return "超出地图范围"
	if not world.is_buildable(cell):
		return "这里不让建造"
	if world.get_block(cell) != 0:
		return "这格已经有方块了"
	if unit.energy_j < 800.0:
		return "电量不足"
	var team_economy = _economy_for(int(unit.team))
	# 自然方块（土/草/沙）免费，加工过的方块要 1 铜
	var material_cost := 0 if kind in ["dirt", "grass", "sand"] else 1
	if material_cost > 0 and not team_economy.spend({"copper": material_cost}):
		return "铜不够（需要 %d）" % material_cost
	unit.energy_j -= 800.0
	world.set_block(cell, block_id)
	return ""


func team_units(team: int) -> Array:
	var out: Array = []
	for entry in units:
		var flyer: RigidBody3D = entry["unit"]
		if int(entry.get("team", TEAM_BLUE)) == team and flyer.alive:
			out.append(entry)
	return out


## 激光钻头打敌方单位：正前方、距离够近、正在钻
## 本帧要施加到单位身上的伤害先排队，等所有武器/钻头都结算完再统一执行，
## 免得分属蓝红两队的单位因为遍历顺序不同而有一方"先手"
func _queue_damage(body: RigidBody3D, amount: float) -> void:
	if body == null or not is_instance_valid(body) or amount <= 0.0:
		return
	amount *= _damage_scale()
	_pending_damage[body] = float(_pending_damage.get(body, 0.0)) + amount


## 决胜时刻：开打 3 分半还没分出胜负，就逐步放大伤害，保证对局一定会结束
func _damage_scale() -> float:
	var war_time := (float(_physics_frames) / 60.0) - PEACE_SECONDS
	if war_time < SUDDEN_DEATH_SECONDS:
		return 1.0
	return 1.0 + (war_time - SUDDEN_DEATH_SECONDS) / 45.0


func _flush_damage() -> void:
	if _pending_damage.is_empty():
		return
	var pending := _pending_damage
	_pending_damage = {}
	for body in pending.keys():
		if is_instance_valid(body) and body.alive:
			body.take_damage(float(pending[body]))


func _process_combat(delta: float) -> void:
	# 发育时间内不打仗
	if in_peace():
		return
	for attacker_entry in units:
		var attacker: RigidBody3D = attacker_entry["unit"]
		if not attacker.alive or not bool(attacker.controls.get("drill", false)):
			continue
		if attacker.energy_out:
			continue
		for victim_entry in units:
			var victim: RigidBody3D = victim_entry["unit"]
			if victim == attacker or not victim.alive:
				continue
			if int(victim_entry.get("team", TEAM_BLUE)) == int(attacker_entry.get("team", TEAM_BLUE)):
				continue
			if attacker.global_position.distance_to(victim.global_position) <= DRILL_UNIT_RANGE:
				_queue_damage(victim, DRILL_DAMAGE_PER_SEC * delta)
	_flush_damage()


func _purge_dead() -> void:
	var survivors: Array = []
	for entry in units:
		var flyer: RigidBody3D = entry["unit"]
		if flyer.alive:
			survivors.append(entry)
		else:
			var node: Node3D = entry["unit"]
			if is_instance_valid(node):
				node.queue_free()
	units = survivors


func _check_victory() -> void:
	if game_over != "" or not _world_ready or units.is_empty():
		return
	if _physics_frames < 30:
		return  # 开局 0.5 秒内不判负，等代码跑起来
	if command_lost[TEAM_RED] or team_units(TEAM_RED).is_empty():
		game_over = "蓝方胜利"
	elif command_lost[TEAM_BLUE] or team_units(TEAM_BLUE).is_empty():
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
	if not _world_ready:
		# 加载阶段：每帧多建几块，只刷进度条，不响应操作、不跑游戏逻辑
		world.update_streaming(rig.position, 4, 12000)
		_update_loading_hint()
		if hud != null:
			hud.set_resources(_resources_text())
		if _loading_finished():
			_start_game()
		return
	_sync_input_state()
	_update_debug_hud()
	_sync_wheel_state()
	world.update_streaming(rig.position)
	_update_loading_hint()
	_update_highlight()
	_update_unit_hud()
	_update_code_panel()


## 载入是否完成：视野内该建的区块都建好了
func _loading_finished() -> bool:
	if world == null:
		return true
	var total := world.chunk_count_x() * world.chunk_count_z()
	return world.chunks.size() >= total and world.pending.is_empty() and world.dirty_count() == 0


## 随机种子：命令行给了 --world-seed=N 就用它（方便复现 / 测试），否则每局都换一张图
func _pick_world_seed() -> int:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--world-seed="):
			return int(arg.substr("--world-seed=".length()))
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi_range(1, 2000000000)


## 世界建好后正式开始：生成双方单位、恢复操作、收起进度条
func _start_game() -> void:
	if _world_ready:
		return
	_world_ready = true
	rig.input_enabled = true
	hud.set_loading_mode(false)
	hud.set_loading("")
	_world_ready_shown = false
	_setup_units()
	hud.show_message("世界已生成，双方各一台飞飞开始对局")


## 载入进度：区块没建完时在屏幕中间显示百分比
func _update_loading_hint() -> void:
	if hud == null or world == null:
		return
	# 开局以后就不再显示加载进度（改方块引起的 pending 重建不打扰玩家）
	if _world_ready:
		hud.set_loading("")
		return
	var total := world.chunk_count_x() * world.chunk_count_z()
	if world.chunks.size() >= total and world.pending.is_empty():
		if _world_ready_shown:
			_world_ready_shown = false
		hud.set_loading("")
		return
	var built := mini(world.chunks.size(), total)
	var percent := int(float(built) / float(total) * 100.0)
	hud.set_loading("正在生成世界  %d%%" % percent)
	_world_ready_shown = true


func _update_highlight() -> void:
	if _highlight == null:
		return
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


## 鼠标指哪打哪：从鼠标位置往场景里发射线
func _aim() -> Dictionary:
	if rig == null or world == null:
		return {}
	var screen := get_viewport().get_mouse_position()
	return _aim_at(screen)


func _aim_at(screen: Vector2) -> Dictionary:
	if rig == null or world == null:
		return {}
	var from := rig.camera.project_ray_origin(screen)
	var to := from + rig.camera.project_ray_normal(screen) * AIM_RANGE
	return world.raycast(from, to)


func _on_primary_click(at: Vector2) -> void:
	if _code_typing():
		return
	# 先看是不是点在自己单位上：双击打开它的代码
	var picked := _pick_own_unit(at)
	if not picked.is_empty():
		_on_unit_clicked(picked)
		return
	var hit := _aim()
	if hit.is_empty():
		return
	var cell: Vector3i = hit["cell"]
	if world.get_block(cell) == BlockDB.AIR:
		return
	if toggle_order(cell, ORDER_MINE):
		hud.show_message("标记挖掘 %d,%d,%d（单位的代码会读到）" % [cell.x, cell.y, cell.z])
	else:
		hud.show_message("取消标记")
	_refresh_hud()


## 屏幕坐标 → 命中我方单位（返回 units 里的一项，没命中返回空字典）
func _pick_own_unit(at: Vector2) -> Dictionary:
	if rig == null or rig.camera == null:
		return {}
	var camera: Camera3D = rig.camera
	var from := camera.project_ray_origin(at)
	var to := from + camera.project_ray_normal(at) * 120.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, UNIT_COLLISION_MASK)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {}
	var collider = hit.get("collider")
	for entry in units:
		if entry["unit"] == collider and int(entry.get("team", TEAM_BLUE)) == TEAM_BLUE:
			return entry
	return {}


## 单击记下候选，双击（同一台、0.4 秒内）打开代码面板
func _on_unit_clicked(entry: Dictionary) -> void:
	var uid := int(entry["uid"])
	var now := Time.get_ticks_msec()
	if uid == _last_click_uid and now - _last_click_time <= DOUBLE_CLICK_MS:
		_last_click_uid = -1
		_open_code_for(uid)
		return
	_last_click_uid = uid
	_last_click_time = now
	var flyer: RigidBody3D = entry["unit"]
	hud.show_message("%s：再点一次打开代码" % flyer.display_name)


## 直接打开某台单位的代码面板（会顺带把面板切到该单位）
func _open_code_for(uid: int) -> void:
	_toggle_code_panel(true)
	code_panel.set_current(uid)
	code_panel.set_code(uid, _code_of(uid))
	code_panel.set_current(uid)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_RIGHT and rig != null and not _code_typing():
		var hit := _aim_at(event.position)
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
		var block_name := db.name_of(block_options[selected])
		if toggle_order(cell, ORDER_PLACE, block_name):
			hud.show_message("标记放置 %s" % block_name)
		else:
			hud.show_message("取消标记")


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_R and game_over != "":
		get_tree().reload_current_scene()
		return
	if event.keycode == KEY_C:
		_toggle_code_panel()
		return
	if _code_typing():
		return
	if event.keycode == KEY_F:
		_place_unit()
		return
	if event.keycode == KEY_G:
		_remove_last_unit()
		return
	if event.keycode == KEY_T:
		_cycle_unit(-1 if event.shift_pressed else 1)
		return
	if event.keycode == KEY_Q:
		_cycle_building(-1 if event.shift_pressed else 1)
		return
	if event.keycode == KEY_B:
		_mark_build_order()
		return
	if event.keycode == KEY_N:
		_mark_remove_order()
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
	var def: Dictionary = _current_unit_def()
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
	var code: String = _preset_for_unit(def)
	_spawn_unit(def, Vector3(at.x, float(ground), at.z), code)
	hud.show_message("放下%s（共 %d 台）" % [str(def.get("display_name", "单位")), units.size()])
	_refresh_hud()


## 当前选中的预设单位定义
func _current_unit_def() -> Dictionary:
	if unit_db == null:
		return {}
	var ids: Array = unit_db.order
	if ids.is_empty():
		return {}
	selected_unit = clampi(selected_unit, 0, ids.size() - 1)
	return unit_db.get_def(str(ids[selected_unit]))


## T 切换预设单位（Shift+T 反向）
func _cycle_unit(step: int) -> void:
	if unit_db == null:
		return
	var ids: Array = unit_db.order
	if ids.is_empty():
		return
	selected_unit = posmod(selected_unit + step, ids.size())
	var def: Dictionary = _current_unit_def()
	hud.show_message("当前单位：%s（%d/%d）" % [str(def.get("display_name", "?")), selected_unit + 1, ids.size()])
	_refresh_hud()


func _remove_last_unit() -> void:
	if units.is_empty():
		return
	var entry: Dictionary = units.pop_back()
	var node: Node3D = entry["unit"]
	node.queue_free()
	if entry.has("cost"):
		_economy_for(int(entry.get("team", TEAM_BLUE))).refund(entry["cost"])
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
	var flyer: RigidBody3D = entry["unit"]
	var controller: UnitController = entry["controller"]
	var enemy_count: int = team_units(TEAM_RED).size()
	var text := "我方 %d 台 ｜ 敌方 %d 台 ｜ %s  高度 %.1f 米  电量 %.0f%%" % [mine.size(), enemy_count, flyer.display_name, flyer.global_position.y - float(world.surface_height(floori(flyer.global_position.x), floori(flyer.global_position.z))), flyer.energy_j / flyer.energy_max * 100.0]
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
	var unit_name := "-"
	var unit_def := _current_unit_def()
	if not unit_def.is_empty():
		unit_name = str(unit_def.get("display_name", "?"))
	hud.set_block_name("手持：%s（%d/%d） ｜ 建筑：%s ｜ 单位：%s ｜ 标记：%d" % [def.display_name if def != null else "?", selected + 1, block_options.size(), building_name, unit_name, orders.size()])
