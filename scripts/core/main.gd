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
var production: Production
var building_db: BuildingDB
## 已有的建筑：{def_id, node, team, kind, timer}
var buildings: Array = []
var selected_building := 0
## 玩家当前选的预设单位（T 键切换）
var selected_unit := 0
const MAX_BUILDINGS := 12
## 单位刚体所在的物理层（1 << 1）
const UNIT_COLLISION_MASK := 2
const DOUBLE_CLICK_MS := 400
## 开局资源（还没做采集经济闭环前的启动资金）
const STARTING_RESOURCES := {"copper": 120, "coal": 60, "iron": 40, "gold": 10}
## 队伍
const TEAM_BLUE := 0
const TEAM_RED := 1
## 红方脚本单位：开局 1 台，跟蓝方 1 台对打
const RED_START := [{"x": 222.0, "z": 128.0}]
## 开局发育时间（秒）：这段时间双方都不能互相攻击，只能挖矿、造建筑、写代码
const PEACE_SECONDS := 60.0
var peace_left := PEACE_SECONDS
## 激光钻头打单位：每秒伤害 / 有效距离
## 鼠标射线能够多远
const AIM_RANGE := 40.0
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
const START_UNITS := [{"id": "feifei", "x": 34.0, "z": 128.0, "code": DefaultCode.FIGHTER_SOURCE}]

## 玩家标记的施工/挖掘指令（虚影）：{x, y, z, action, id}
## action：mine 挖一格 / place 放方块 / build 造建筑 / remove 拆建筑
var orders: Array = []
var orders_root: Node3D
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
	production = Production.new()
	production.setup(economy)
	# 一个示例配方：3 煤 + 1 铜 → 30 秒产 1 块「电池」（M4 先打通链路，具体数值后面调）
	production.add_recipe("battery", {"coal": 3, "copper": 1}, {"battery": 1}, 30.0)

	units_root = Node3D.new()
	units_root.name = "Units"
	add_child(units_root)
	_load_unit_db()
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
		_spawn_unit(red_def, Vector3(float(spec["x"]), 0.0, float(spec["z"])), DefaultCode.FIGHTER_SOURCE, TEAM_RED)


## 按单位表里的 id 造对应的节点：车车是地面车，其余默认飞飞
func _make_unit_node(def: Dictionary) -> RigidBody3D:
	if str(def.get("id", "")) == "rover":
		return Rover.new()
	return Flyer.new()


func _spawn_unit(def: Dictionary, at: Vector3, code: String, team: int = TEAM_BLUE) -> void:
	var unit := _make_unit_node(def)
	unit.name = "%s_%d" % [str(def.get("id", "unit")), units.size() + 1]
	units_root.add_child(unit)
	var ground := world.surface_height(int(at.x), int(at.z))
	unit.global_position = Vector3(at.x, float(ground) + 6.0, at.z)
	unit.setup(world, def)
	unit.team = team
	# 蓝方面朝 +X、红方面朝 -X
	unit.rotation.y = -PI * 0.5 if team == TEAM_BLUE else PI * 0.5
	var controller := UnitController.new()
	unit.gun_fired.connect(_on_gun_fired)
	unit.block_dug.connect(_on_block_dug)
	controller.bind(unit, code, 1)
	units.append({"uid": _next_uid, "unit": unit, "controller": controller, "code": code, "revision": 1, "team": team, "cost": economy.unit_cost(def) if economy != null else {}})
	_next_uid += 1
	unit.name = "%s_%d" % [str(def.get("id", "unit")), int(units[units.size() - 1]["uid"])]


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
		controller.tick(delta)
	# 武器：发育时间里也能挖方块（只对单位断伤）；贴身钻头战斗只在开打后结算
	_process_weapons(delta)
	if not in_peace():
		_process_combat(delta)
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
		hud.set_peace("")


func _tick_peace(delta: float) -> void:
	if peace_left <= 0.0:
		return
	peace_left = maxf(0.0, peace_left - delta)
	if peace_left <= 0.0:
		if hud != null:
			hud.set_peace("")
			hud.show_message("发育时间结束，可以开打了", 4.0)
		return
	# 每秒刷新一次倒计时显示
	var seconds := int(ceil(peace_left))
	if seconds != _peace_label_seconds:
		_peace_label_seconds = seconds
		if hud != null:
			hud.set_peace("发育时间 %d 秒（双方不能互相攻击）" % seconds)


var _peace_label_seconds := -1


## ---------------- 武器：激光（5 格）与炮管（15 格） ----------------

## 命中判定用的单位半径（米）
const WEAPON_UNIT_RADIUS := 0.45

## 方块受击累计伤害：Vector3i -> float（方块血量见 BlockDB.hp_of）
var _block_damage: Dictionary = {}


func _process_weapons(delta: float) -> void:
	# 发育时间内只禁「打单位」，激光挖方块照常（不然发育期没法挖矿攒资源）
	for entry in units:
		var u: RigidBody3D = entry["unit"]
		if not u.alive:
			continue
		_resolve_laser(u, delta)


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
	if not unit_hit.is_empty():
		end = unit_hit["point"]
		var victim: RigidBody3D = unit_hit["unit"]
		victim.take_damage(u.laser_dps_unit * delta)
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
	if not unit_hit.is_empty():
		end = unit_hit["point"]
		var victim: RigidBody3D = unit_hit["unit"]
		victim.take_damage(u.gun_damage_unit)
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
func _refresh_enemy_sensors() -> void:
	for entry in units:
		var self_unit: RigidBody3D = entry["unit"]
		if not self_unit.alive:
			continue
		var enemy_team: int = TEAM_BLUE if int(entry.get("team", TEAM_BLUE)) == TEAM_RED else TEAM_RED
		var found: Array = []
		for other in team_units(enemy_team):
			var o: RigidBody3D = other["unit"]
			if not o.alive:
				continue
			var dist: float = self_unit.global_position.distance_to(o.global_position)
			if dist > self_unit.radar_unit_range:
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
		elif kind == "charger":
			_charge_nearby(node, def, period)


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


## 充电站：给半径内同队伍的单位补电
func _charge_nearby(node, def: Dictionary, period: float) -> void:
	var radius := float(def.get("radius", 14.0))
	var power := float(def.get("power_w", 900.0))
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
		var flyer: RigidBody3D = entry["unit"]
		if int(entry.get("team", TEAM_BLUE)) == team and flyer.alive:
			out.append(entry)
	return out


## 激光钻头打敌方单位：正前方、距离够近、正在钻
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
				victim.take_damage(DRILL_DAMAGE_PER_SEC * delta)


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
	var code: String = DefaultCode.ROVER_SOURCE if str(def.get("id", "")) == "rover" else DefaultCode.FLYER_SOURCE
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
